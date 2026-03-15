USE [master]
GO

SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [dbo].[usp_DropLoginUserAndAccess]
    @DbName                 sysname = NULL,
    @Login                  sysname = N'tabular_user',
    @DropLogin              bit     = 1,
    @OnlyIfUnusedInOtherDbs bit     = 1,  -- safer default
    @ReassignSchemaOwner    bit     = 1,  -- avoids DROP USER failures
    @KillSessions           bit     = 0,  -- requires VIEW SERVER STATE
    @KillAllDatabases       bit     = 0,  -- 0 = only kill sessions in @DbName; 1 = all sessions for the login
    @RolePrefix             nvarchar(64) = N'managed',  -- must match the prefix used in Create proc
    @DryRun                 bit     = 0,  -- 1 = print what would happen without executing
    @LogToTable             bit     = 0,  -- write actions to dbo.provisioning_log

    -- Help
    @Help                   bit     = 0   -- print usage examples and return
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -----------------------------------------------------------------
    -- Help / usage
    -----------------------------------------------------------------
    IF @Help = 1
    BEGIN
        PRINT N'=================================================================';
        PRINT N'  usp_DropLoginUserAndAccess';
        PRINT N'  Drops a DB user, cleans up managed roles, optionally drops';
        PRINT N'  the server login.';
        PRINT N'=================================================================';
        PRINT N'';
        PRINT N'PARAMETERS:';
        PRINT N'  @DbName                sysname        (required) Target database';
        PRINT N'  @Login                 sysname        = N''tabular_user''';
        PRINT N'  @DropLogin             bit            = 1 (also drop server login)';
        PRINT N'  @OnlyIfUnusedInOtherDbs bit           = 1 (skip login drop if mapped elsewhere)';
        PRINT N'  @ReassignSchemaOwner   bit            = 1 (reassign schemas to dbo before drop)';
        PRINT N'  @KillSessions          bit            = 0 (kill active sessions first)';
        PRINT N'  @KillAllDatabases      bit            = 0 (0=target DB only, 1=all DBs)';
        PRINT N'  @RolePrefix            nvarchar(64)   = N''managed'' (must match Create proc)';
        PRINT N'  @DryRun                bit            = 0 (preview without executing)';
        PRINT N'  @LogToTable            bit            = 0 (log to dbo.provisioning_log)';
        PRINT N'';
        PRINT N'EXAMPLES:';
        PRINT N'';
        PRINT N'  -- 1. Drop user + login from MyDB (defaults)';
        PRINT N'  EXEC dbo.usp_DropLoginUserAndAccess';
        PRINT N'      @DbName = N''MyDB'';';
        PRINT N'';
        PRINT N'  -- 2. Drop a specific login';
        PRINT N'  EXEC dbo.usp_DropLoginUserAndAccess';
        PRINT N'      @DbName = N''MyDB'', @Login = N''app_svc'';';
        PRINT N'';
        PRINT N'  -- 3. Dry run — preview what would happen';
        PRINT N'  EXEC dbo.usp_DropLoginUserAndAccess';
        PRINT N'      @DbName = N''MyDB'', @Login = N''app_svc'', @DryRun = 1;';
        PRINT N'';
        PRINT N'  -- 4. Drop user only, keep server login';
        PRINT N'  EXEC dbo.usp_DropLoginUserAndAccess';
        PRINT N'      @DbName = N''MyDB'', @Login = N''app_svc'', @DropLogin = 0;';
        PRINT N'';
        PRINT N'  -- 5. Force drop even if login is mapped in other DBs';
        PRINT N'  EXEC dbo.usp_DropLoginUserAndAccess';
        PRINT N'      @DbName = N''MyDB'', @Login = N''app_svc'',';
        PRINT N'      @OnlyIfUnusedInOtherDbs = 0;';
        PRINT N'';
        PRINT N'  -- 6. Kill sessions before dropping (target DB only)';
        PRINT N'  EXEC dbo.usp_DropLoginUserAndAccess';
        PRINT N'      @DbName = N''MyDB'', @Login = N''app_svc'',';
        PRINT N'      @KillSessions = 1;';
        PRINT N'';
        PRINT N'  -- 7. Kill all sessions across all DBs, log actions';
        PRINT N'  EXEC dbo.usp_DropLoginUserAndAccess';
        PRINT N'      @DbName = N''MyDB'', @Login = N''app_svc'',';
        PRINT N'      @KillSessions = 1, @KillAllDatabases = 1,';
        PRINT N'      @LogToTable = 1;';
        PRINT N'=================================================================';
        RETURN;
    END

    DECLARE @msg nvarchar(2048);

    ---------------------------------------------------------------------------
    -- @DbName is required for all non-help invocations
    ---------------------------------------------------------------------------
    IF @DbName IS NULL
    BEGIN
        PRINT N'[FAIL] @DbName is required. Run with @Help = 1 for usage examples.';
        RETURN;
    END;

    ---------------------------------------------------------------------------
    -- Version guard: requires SQL Server 2017+ (STRING_AGG)
    ---------------------------------------------------------------------------
    IF CAST(SERVERPROPERTY('ProductMajorVersion') AS INT) < 14
    BEGIN
        SET @msg = N'[FAIL] This procedure requires SQL Server 2017 (v14) or later. Current: '
                 + CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128));
        PRINT @msg;
        THROW 51099, @msg, 1;
    END;

    ---------------------------------------------------------------------------
    -- Ensure provisioning log table exists (if logging requested)
    ---------------------------------------------------------------------------
    IF @LogToTable = 1 AND OBJECT_ID('master.dbo.provisioning_log', 'U') IS NULL
    BEGIN
        CREATE TABLE master.dbo.provisioning_log (
            id          INT IDENTITY(1,1) PRIMARY KEY,
            event_time  DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
            proc_name   sysname NOT NULL,
            login_name  sysname NOT NULL,
            db_name     sysname NOT NULL,
            action      nvarchar(256) NOT NULL,
            detail      nvarchar(max) NULL
        );
    END;

    ---------------------------------------------------------------------------
    -- Validate inputs
    ---------------------------------------------------------------------------
    IF DB_ID(@DbName) IS NULL
    BEGIN
        SET @msg = N'[FAIL] Database not found: ' + @DbName;
        PRINT @msg;
        THROW 51000, @msg, 1;
    END;

    DECLARE @DbQ    nvarchar(258) = QUOTENAME(@DbName);
    DECLARE @LoginQ nvarchar(258) = QUOTENAME(@Login);

    IF @DryRun = 1
        PRINT N'[INFO] *** DRY RUN MODE — no changes will be made ***';

    PRINT CONCAT(N'[OK] Cleanup target: DB=', @DbQ, N' | Login=', @LoginQ,
                 N' | DryRun=', CAST(@DryRun AS nvarchar(1)));

    ---------------------------------------------------------------------------
    -- 1) Drop user (in target DB)
    ---------------------------------------------------------------------------
    BEGIN TRY
        DECLARE @sql_drop_user nvarchar(max) =
N'USE ' + @DbQ + N';
SET NOCOUNT ON;

IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = @pLogin)
BEGIN
    -- Reassign schemas owned by the user (common blocker for DROP USER)
    IF @pReassignSchemaOwner = 1
    BEGIN
        DECLARE @schemaList nvarchar(max);
        SELECT @schemaList = STRING_AGG(QUOTENAME(s.name), N'', '')
        FROM sys.schemas s
        JOIN sys.database_principals p ON p.principal_id = s.principal_id
        WHERE p.name = @pLogin;

        IF @schemaList IS NOT NULL
        BEGIN
            IF @pDryRun = 1
                PRINT N''[DRY RUN] Would reassign ownership of schemas: '' + @schemaList + N'' to dbo.'';
            ELSE
            BEGIN
                DECLARE @schemaCmd nvarchar(max) = N'''';
                SELECT @schemaCmd = STRING_AGG(
                    N''ALTER AUTHORIZATION ON SCHEMA::'' + QUOTENAME(s.name) + N'' TO dbo;'',
                    CHAR(10)
                )
                FROM sys.schemas s
                JOIN sys.database_principals p ON p.principal_id = s.principal_id
                WHERE p.name = @pLogin;

                EXEC (@schemaCmd);
                PRINT N''[DONE] Reassigned schema ownership to dbo for: '' + @schemaList;
            END
        END
        ELSE
            PRINT N''[OK] No schemas owned by the user.'';
    END;

    -- Remove from any roles (except public)
    DECLARE @roleList nvarchar(max);
    SELECT @roleList = STRING_AGG(QUOTENAME(r.name), N'', '')
    FROM sys.database_role_members drm
    JOIN sys.database_principals r ON r.principal_id = drm.role_principal_id
    JOIN sys.database_principals m ON m.principal_id = drm.member_principal_id
    WHERE m.name = @pLogin
      AND r.name <> N''public'';

    IF @roleList IS NOT NULL
    BEGIN
        IF @pDryRun = 1
            PRINT N''[DRY RUN] Would remove '' + QUOTENAME(@pLogin) + N'' from roles: '' + @roleList;
        ELSE
        BEGIN
            DECLARE @roleCmd nvarchar(max);
            SELECT @roleCmd = STRING_AGG(
                N''ALTER ROLE '' + QUOTENAME(r.name) + N'' DROP MEMBER '' + QUOTENAME(@pLogin) + N'';'',
                CHAR(10)
            )
            FROM sys.database_role_members drm
            JOIN sys.database_principals r ON r.principal_id = drm.role_principal_id
            JOIN sys.database_principals m ON m.principal_id = drm.member_principal_id
            WHERE m.name = @pLogin
              AND r.name <> N''public'';

            EXEC (@roleCmd);
            PRINT N''[DONE] Removed user from database roles: '' + @roleList;
        END
    END
    ELSE
        PRINT N''[OK] User not a member of any custom roles (besides public).'';

    -- Drop user
    IF @pDryRun = 1
        PRINT N''[DRY RUN] Would drop database user '' + QUOTENAME(@pLogin) + N''.'';
    ELSE
    BEGIN
        EXEC (N''DROP USER '' + QUOTENAME(@pLogin) + N'';'');
        PRINT CONCAT(N''[DONE] Dropped database user '', QUOTENAME(@pLogin), N''.'');
    END
END
ELSE
    PRINT CONCAT(N''[SKIP] Database user does not exist: '', QUOTENAME(@pLogin), N''.'');
';

        EXEC sys.sp_executesql
            @sql_drop_user,
            N'@pLogin sysname, @pReassignSchemaOwner bit, @pDryRun bit',
            @pLogin = @Login,
            @pReassignSchemaOwner = @ReassignSchemaOwner,
            @pDryRun = @DryRun;

        IF @LogToTable = 1 AND @DryRun = 0
            INSERT INTO master.dbo.provisioning_log (proc_name, login_name, db_name, action)
            VALUES (N'usp_DropLoginUserAndAccess', @Login, @DbName, N'Dropped database user');
    END TRY
    BEGIN CATCH
        SET @msg = CONCAT(N'[FAIL] DB user cleanup failed in ', @DbQ, N': ', ERROR_MESSAGE());
        PRINT @msg;
        THROW;
    END CATCH;

    ---------------------------------------------------------------------------
    -- 2) Clean up managed schema roles left behind
    ---------------------------------------------------------------------------
    BEGIN TRY
        IF OBJECT_ID('tempdb..#ManagedRoles') IS NOT NULL DROP TABLE #ManagedRoles;
        CREATE TABLE #ManagedRoles (RoleName sysname COLLATE DATABASE_DEFAULT PRIMARY KEY);

        DECLARE @managedPrefix nvarchar(128) = LEFT(@RolePrefix + N'_' + @Login + N'_schema_access', 128);

        DECLARE @sql_find_managed nvarchar(max) =
            N'USE ' + @DbQ + N';
              INSERT INTO #ManagedRoles(RoleName)
              SELECT name
              FROM sys.database_principals
              WHERE type = N''R''
                AND name LIKE @pPrefix + N''%'';';

        EXEC sys.sp_executesql
            @sql_find_managed,
            N'@pPrefix nvarchar(128)',
            @pPrefix = @managedPrefix;

        DECLARE @managedRole sysname;
        DECLARE @sql_cleanup_role nvarchar(max);

        DECLARE curManaged CURSOR LOCAL FAST_FORWARD FOR
            SELECT RoleName FROM #ManagedRoles;

        OPEN curManaged;
        FETCH NEXT FROM curManaged INTO @managedRole;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            IF @DryRun = 1
                PRINT CONCAT(N'[DRY RUN] Would revoke grants and drop managed role: ', QUOTENAME(@managedRole));
            ELSE
            BEGIN
                -- Revoke schema grants, then drop the role if empty
                SET @sql_cleanup_role =
                    N'USE ' + @DbQ + N';
                      -- Revoke all schema-level grants from the role
                      DECLARE @revoke nvarchar(max);
                      SELECT @revoke = STRING_AGG(
                          N''REVOKE '' + dp.permission_name
                          + N'' ON SCHEMA::'' + QUOTENAME(s.name)
                          + N'' FROM '' + QUOTENAME(@pRole) + N'';'',
                          CHAR(10)
                      )
                      FROM sys.database_permissions dp
                      JOIN sys.database_principals gr ON gr.principal_id = dp.grantee_principal_id
                      JOIN sys.schemas s ON s.schema_id = dp.major_id
                      WHERE gr.name = @pRole
                        AND dp.class_desc = N''SCHEMA''
                        AND dp.state_desc IN (N''GRANT'', N''GRANT_WITH_GRANT_OPTION'');

                      IF @revoke IS NOT NULL
                      BEGIN
                          EXEC (@revoke);
                          PRINT N''[DONE] Revoked schema grants from role '' + QUOTENAME(@pRole);
                      END;

                      -- Drop role if it has no remaining members
                      IF NOT EXISTS (
                          SELECT 1
                          FROM sys.database_role_members drm
                          JOIN sys.database_principals rp ON rp.principal_id = drm.role_principal_id
                          WHERE rp.name = @pRole
                      )
                      BEGIN
                          BEGIN TRY
                              EXEC (N''DROP ROLE '' + QUOTENAME(@pRole) + N'';'');
                              PRINT N''[DONE] Dropped empty managed role '' + QUOTENAME(@pRole);
                          END TRY
                          BEGIN CATCH
                              PRINT N''[WARN] Could not drop role '' + QUOTENAME(@pRole) + N'': '' + ERROR_MESSAGE();
                          END CATCH
                      END
                      ELSE
                          PRINT N''[SKIP] Managed role '' + QUOTENAME(@pRole) + N'' still has members; keeping it.'';';

                EXEC sys.sp_executesql
                    @sql_cleanup_role,
                    N'@pRole sysname',
                    @pRole = @managedRole;
            END;

            FETCH NEXT FROM curManaged INTO @managedRole;
        END

        CLOSE curManaged;
        DEALLOCATE curManaged;
    END TRY
    BEGIN CATCH
        PRINT CONCAT(N'[WARN] Managed role cleanup encountered an error: ', ERROR_MESSAGE());
        -- Non-fatal: continue with login drop
    END CATCH;

    ---------------------------------------------------------------------------
    -- 3) Optionally drop login (server-level)
    ---------------------------------------------------------------------------
    IF @DropLogin = 0
    BEGIN
        PRINT N'[SKIP] @DropLogin=0; leaving server login intact.';
        PRINT N'[OK] Cleanup complete.';
        RETURN;
    END;

    DECLARE @LoginSid varbinary(85);

    SELECT @LoginSid = sp.sid
    FROM sys.server_principals sp
    WHERE sp.name = @Login
      AND sp.type_desc = N'SQL_LOGIN';

    IF @LoginSid IS NULL
    BEGIN
        PRINT CONCAT(N'[SKIP] Server login does not exist: ', @LoginQ, N'.');
        PRINT N'[OK] Cleanup complete.';
        RETURN;
    END;

    -- Warn about non-online databases that might have this user mapped
    DECLARE @nonOnlineList nvarchar(max);
    SELECT @nonOnlineList = STRING_AGG(QUOTENAME(name) + N' (' + state_desc COLLATE DATABASE_DEFAULT + N')', N', ')
    FROM sys.databases
    WHERE state_desc <> N'ONLINE'
      AND database_id > 4;

    IF @nonOnlineList IS NOT NULL
        PRINT CONCAT(N'[WARN] These user databases are not ONLINE and could not be checked for mapped users: ', @nonOnlineList);

    -- Check if login SID is still mapped in any other online user DBs
    IF OBJECT_ID('tempdb..#LoginUsage') IS NOT NULL DROP TABLE #LoginUsage;
    CREATE TABLE #LoginUsage (db_name sysname COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY);

    DECLARE @db sysname;
    DECLARE @sql_usage nvarchar(max);

    DECLARE dbcur CURSOR LOCAL FAST_FORWARD FOR
        SELECT name
        FROM sys.databases
        WHERE state_desc = N'ONLINE'
          AND database_id > 4;

    OPEN dbcur;
    FETCH NEXT FROM dbcur INTO @db;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @sql_usage =
            N'USE ' + QUOTENAME(@db) + N';
              IF EXISTS (
                  SELECT 1
                  FROM sys.database_principals
                  WHERE sid = @pSid
              )
                  INSERT INTO #LoginUsage(db_name) VALUES (@pDbName);';

        EXEC sys.sp_executesql
            @sql_usage,
            N'@pSid varbinary(85), @pDbName sysname',
            @pSid = @LoginSid,
            @pDbName = @db;

        FETCH NEXT FROM dbcur INTO @db;
    END

    CLOSE dbcur;
    DEALLOCATE dbcur;

    IF EXISTS (SELECT 1 FROM #LoginUsage)
    BEGIN
        DECLARE @dbList nvarchar(max);
        SELECT @dbList = STRING_AGG(QUOTENAME(db_name), N', ')
        FROM #LoginUsage;

        PRINT CONCAT(N'[WARN] Login SID is still present as a database principal in: ', @dbList);

        IF @OnlyIfUnusedInOtherDbs = 1
        BEGIN
            PRINT N'[SKIP] @OnlyIfUnusedInOtherDbs=1; not dropping server login.';
            PRINT N'[OK] Cleanup complete.';
            RETURN;
        END;
    END
    ELSE
        PRINT N'[OK] No database principals found for this login in other DBs.';

    -- Optionally kill active sessions for this login
    IF @KillSessions = 1
    BEGIN
        DECLARE @killList nvarchar(max);

        IF @KillAllDatabases = 1
        BEGIN
            SELECT @killList = STRING_AGG(
                N'KILL ' + CAST(s.session_id AS nvarchar(10)) + N';',
                CHAR(10)
            )
            FROM sys.dm_exec_sessions s
            WHERE s.login_name = @Login
              AND s.session_id <> @@SPID;
        END
        ELSE
        BEGIN
            -- Only kill sessions connected to the target database
            SELECT @killList = STRING_AGG(
                N'KILL ' + CAST(s.session_id AS nvarchar(10)) + N';',
                CHAR(10)
            )
            FROM sys.dm_exec_sessions s
            WHERE s.login_name = @Login
              AND s.database_id = DB_ID(@DbName)
              AND s.session_id <> @@SPID;
        END;

        IF @killList IS NOT NULL
        BEGIN
            IF @DryRun = 1
                PRINT CONCAT(N'[DRY RUN] Would kill sessions for ', @LoginQ,
                             CASE WHEN @KillAllDatabases = 1 THEN N' (all databases)' ELSE N' (in ' + @DbQ + N' only)' END);
            ELSE
            BEGIN
                EXEC (@killList);
                PRINT CONCAT(N'[DONE] Killed active sessions for ', @LoginQ,
                             CASE WHEN @KillAllDatabases = 1 THEN N' (all databases).' ELSE N' (in ' + @DbQ + N' only).' END);
            END;
        END
        ELSE
            PRINT N'[OK] No active sessions found for this login.';
    END;

    -- Drop login
    IF @DryRun = 1
    BEGIN
        PRINT CONCAT(N'[DRY RUN] Would drop server login ', @LoginQ, N'.');
        PRINT N'[OK] Dry run complete.';
        RETURN;
    END;

    BEGIN TRY
        EXEC (N'DROP LOGIN ' + @LoginQ + N';');
        PRINT CONCAT(N'[DONE] Dropped server login ', @LoginQ, N'.');

        IF @LogToTable = 1
            INSERT INTO master.dbo.provisioning_log (proc_name, login_name, db_name, action)
            VALUES (N'usp_DropLoginUserAndAccess', @Login, @DbName, N'Dropped server login');

        PRINT N'[OK] Cleanup complete.';
    END TRY
    BEGIN CATCH
        SET @msg = CONCAT(N'[FAIL] DROP LOGIN failed: ', ERROR_MESSAGE());
        PRINT @msg;
        THROW;
    END CATCH
END;
GO
