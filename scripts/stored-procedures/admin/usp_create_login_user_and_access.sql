USE [master]
GO

SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [dbo].[usp_CreateLoginUserAndAccess]
    @DbName         sysname = NULL,
    @Login          sysname = N'tabular_user',
    @Password       nvarchar(128) = NULL,          -- required when creating a new login or resetting
    @ResetPassword  bit = 0,

    -- Access control
    @AccessMode     nvarchar(30) = N'DB_OWNER',    -- DB_OWNER | READ_ALL | READWRITE_ALL | DDL_ADMIN | READ_SCHEMA | READWRITE_SCHEMA | NONE
    @SchemaList     nvarchar(max) = NULL,           -- NULL/empty => all non-system schemas. Otherwise: 'dbo,sales'
    @CustomRole     sysname = NULL,                 -- used only for *_SCHEMA modes; NULL => auto role name
    @RolePrefix     nvarchar(64) = N'managed',      -- prefix for auto-generated schema role names
    @IncludeExecute bit = 0,                        -- grant EXECUTE on schemas (for procs/functions) in *_SCHEMA modes

    -- Switching behavior
    @ReplaceAccess  bit = 0,                        -- remove managed grants/memberships first
    @KeepSchemaRole bit = 1,                        -- when ReplaceAccess=1: revoke old schema grants but keep role object

    -- Observability
    @LogToTable     bit = 0,                        -- write actions to dbo.provisioning_log

    -- Help
    @Help           bit = 0                         -- print usage examples and return
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
        PRINT N'  usp_CreateLoginUserAndAccess';
        PRINT N'  Creates a SQL login, maps it to a DB user, grants access.';
        PRINT N'=================================================================';
        PRINT N'';
        PRINT N'PARAMETERS:';
        PRINT N'  @DbName          sysname        (required) Target database';
        PRINT N'  @Login           sysname        = N''tabular_user''';
        PRINT N'  @Password        nvarchar(128)  = NULL (required for new login/reset)';
        PRINT N'  @ResetPassword   bit            = 0';
        PRINT N'  @AccessMode      nvarchar(30)   = N''DB_OWNER''';
        PRINT N'      Options: DB_OWNER | READ_ALL | READWRITE_ALL | DDL_ADMIN';
        PRINT N'               READ_SCHEMA | READWRITE_SCHEMA | NONE';
        PRINT N'  @SchemaList      nvarchar(max)  = NULL (all non-system schemas)';
        PRINT N'  @CustomRole      sysname        = NULL (auto-generated role name)';
        PRINT N'  @RolePrefix      nvarchar(64)   = N''managed''';
        PRINT N'  @IncludeExecute  bit            = 0 (EXECUTE on schemas)';
        PRINT N'  @ReplaceAccess   bit            = 0 (revoke existing first)';
        PRINT N'  @KeepSchemaRole  bit            = 1 (keep role object on replace)';
        PRINT N'  @LogToTable      bit            = 0 (log to dbo.provisioning_log)';
        PRINT N'';
        PRINT N'EXAMPLES:';
        PRINT N'';
        PRINT N'  -- 1. Grant db_owner (defaults)';
        PRINT N'  EXEC dbo.usp_CreateLoginUserAndAccess';
        PRINT N'      @DbName = N''MyDB'', @Password = N''Strong!Pass1'';';
        PRINT N'';
        PRINT N'  -- 2. Read-only on specific schemas';
        PRINT N'  EXEC dbo.usp_CreateLoginUserAndAccess';
        PRINT N'      @DbName = N''MyDB'', @Login = N''report_user'',';
        PRINT N'      @Password = N''Strong!Pass1'',';
        PRINT N'      @AccessMode = N''READ_SCHEMA'', @SchemaList = N''dbo,sales'';';
        PRINT N'';
        PRINT N'  -- 3. Read-write on all schemas + EXECUTE';
        PRINT N'  EXEC dbo.usp_CreateLoginUserAndAccess';
        PRINT N'      @DbName = N''MyDB'', @Login = N''app_svc'',';
        PRINT N'      @Password = N''Strong!Pass1'',';
        PRINT N'      @AccessMode = N''READWRITE_SCHEMA'', @IncludeExecute = 1;';
        PRINT N'';
        PRINT N'  -- 4. Replace access, keep roles, log actions';
        PRINT N'  EXEC dbo.usp_CreateLoginUserAndAccess';
        PRINT N'      @DbName = N''MyDB'', @Login = N''app_svc'',';
        PRINT N'      @AccessMode = N''READWRITE_SCHEMA'',';
        PRINT N'      @SchemaList = N''dbo,inventory'',';
        PRINT N'      @ReplaceAccess = 1, @KeepSchemaRole = 1, @LogToTable = 1;';
        PRINT N'';
        PRINT N'  -- 5. Reset password only';
        PRINT N'  EXEC dbo.usp_CreateLoginUserAndAccess';
        PRINT N'      @DbName = N''MyDB'', @Login = N''app_svc'',';
        PRINT N'      @Password = N''NewStr0ng!Pass'',';
        PRINT N'      @ResetPassword = 1, @AccessMode = N''NONE'';';
        PRINT N'';
        PRINT N'  -- 6. DDL admin';
        PRINT N'  EXEC dbo.usp_CreateLoginUserAndAccess';
        PRINT N'      @DbName = N''MyDB'', @Login = N''migration_svc'',';
        PRINT N'      @Password = N''Strong!Pass1'', @AccessMode = N''DDL_ADMIN'';';
        PRINT N'';
        PRINT N'  -- 7. Custom role name';
        PRINT N'  EXEC dbo.usp_CreateLoginUserAndAccess';
        PRINT N'      @DbName = N''MyDB'', @Login = N''etl_user'',';
        PRINT N'      @Password = N''Strong!Pass1'',';
        PRINT N'      @AccessMode = N''READWRITE_SCHEMA'',';
        PRINT N'      @SchemaList = N''staging,raw'',';
        PRINT N'      @CustomRole = N''etl_data_access'';';
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
    -- Version guard: requires SQL Server 2017+ (STRING_AGG, STRING_SPLIT)
    ---------------------------------------------------------------------------
    IF CAST(SERVERPROPERTY('ProductMajorVersion') AS INT) < 14
    BEGIN
        SET @msg = N'[FAIL] This procedure requires SQL Server 2017 (v14) or later. Current: '
                 + CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128));
        PRINT @msg;
        THROW 50099, @msg, 1;
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
        THROW 50000, @msg, 1;
    END;

    SET @AccessMode = UPPER(LTRIM(RTRIM(@AccessMode)));

    IF @AccessMode NOT IN (N'DB_OWNER', N'READ_ALL', N'READWRITE_ALL', N'DDL_ADMIN', N'READ_SCHEMA', N'READWRITE_SCHEMA', N'NONE')
    BEGIN
        SET @msg = N'[FAIL] Invalid @AccessMode: ' + COALESCE(@AccessMode, N'(NULL)') +
                   N'. Allowed: DB_OWNER, READ_ALL, READWRITE_ALL, DDL_ADMIN, READ_SCHEMA, READWRITE_SCHEMA, NONE.';
        PRINT @msg;
        THROW 50010, @msg, 1;
    END;

    DECLARE @DbQ    nvarchar(258) = QUOTENAME(@DbName);
    DECLARE @LoginQ nvarchar(258) = QUOTENAME(@Login);

    PRINT CONCAT(
        N'[OK] Target DB=', @DbQ,
        N' | Login=', @LoginQ,
        N' | AccessMode=', @AccessMode,
        N' | ReplaceAccess=', CAST(@ReplaceAccess AS nvarchar(1)),
        N' | KeepSchemaRole=', CAST(@KeepSchemaRole AS nvarchar(1)),
        N' | Schemas=', COALESCE(NULLIF(LTRIM(RTRIM(@SchemaList)), N''), N'(all)')
    );

    ---------------------------------------------------------------------------
    -- Ensure SQL Login (server-level)
    ---------------------------------------------------------------------------
    DECLARE @loginExists BIT = 0;
    DECLARE @loginDisabled BIT = 0;

    SELECT @loginExists = 1,
           @loginDisabled = CASE WHEN is_disabled = 1 THEN 1 ELSE 0 END
    FROM sys.server_principals
    WHERE name = @Login
      AND type_desc = N'SQL_LOGIN';

    IF @loginExists = 0
    BEGIN
        IF @Password IS NULL OR LTRIM(RTRIM(@Password)) = N''
        BEGIN
            SET @msg = N'[FAIL] @Password is required to create a new login: ' + @Login;
            PRINT @msg;
            THROW 50001, @msg, 1;
        END;

        -- NOTE: CREATE LOGIN does not support parameterized passwords.
        -- The password will briefly appear in the plan cache. We clear the
        -- specific plan handle immediately after execution to minimize exposure.
        DECLARE @sql_login nvarchar(max) =
            N'CREATE LOGIN ' + @LoginQ + N'
              WITH PASSWORD = ' + QUOTENAME(@Password, '''') + N',
                   CHECK_POLICY = ON,
                   CHECK_EXPIRATION = OFF,
                   DEFAULT_DATABASE = ' + @DbQ + N';';

        EXEC sys.sp_executesql @sql_login;

        -- Purge plan containing the cleartext password from cache
        DECLARE @plan_handle_login varbinary(64);
        SELECT TOP 1 @plan_handle_login = qs.plan_handle
        FROM sys.dm_exec_query_stats qs
        CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
        WHERE st.text LIKE N'%CREATE LOGIN%' + @Login + N'%WITH PASSWORD%'
          AND qs.creation_time >= DATEADD(SECOND, -5, GETDATE());

        IF @plan_handle_login IS NOT NULL
            DBCC FREEPROCCACHE(@plan_handle_login) WITH NO_INFOMSGS;

        PRINT CONCAT(N'[DONE] Created SQL login ', @LoginQ, N' (DEFAULT_DATABASE=', @DbQ, N').');

        IF @LogToTable = 1
            INSERT INTO master.dbo.provisioning_log (proc_name, login_name, db_name, action)
            VALUES (N'usp_CreateLoginUserAndAccess', @Login, @DbName, N'Created SQL login');
    END
    ELSE
    BEGIN
        PRINT CONCAT(N'[OK] SQL login already exists: ', @LoginQ, N'.');

        -- Warn if login is disabled
        IF @loginDisabled = 1
            PRINT CONCAT(N'[WARN] Login ', @LoginQ, N' exists but is DISABLED. The user will not be able to connect until it is enabled.');

        IF @ResetPassword = 1
        BEGIN
            IF @Password IS NULL OR LTRIM(RTRIM(@Password)) = N''
            BEGIN
                SET @msg = N'[FAIL] @Password is required when @ResetPassword = 1 for login: ' + @Login;
                PRINT @msg;
                THROW 50002, @msg, 1;
            END;

            DECLARE @sql_reset nvarchar(max) =
                N'ALTER LOGIN ' + @LoginQ + N'
                  WITH PASSWORD = ' + QUOTENAME(@Password, '''') + N',
                       CHECK_POLICY = ON,
                       CHECK_EXPIRATION = OFF;';

            EXEC sys.sp_executesql @sql_reset;

            -- Purge plan containing the cleartext password from cache
            DECLARE @plan_handle_reset varbinary(64);
            SELECT TOP 1 @plan_handle_reset = qs.plan_handle
            FROM sys.dm_exec_query_stats qs
            CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
            WHERE st.text LIKE N'%ALTER LOGIN%' + @Login + N'%WITH PASSWORD%'
              AND qs.creation_time >= DATEADD(SECOND, -5, GETDATE());

            IF @plan_handle_reset IS NOT NULL
                DBCC FREEPROCCACHE(@plan_handle_reset) WITH NO_INFOMSGS;

            PRINT CONCAT(N'[DONE] Reset password for SQL login ', @LoginQ, N'.');

            IF @LogToTable = 1
                INSERT INTO master.dbo.provisioning_log (proc_name, login_name, db_name, action)
                VALUES (N'usp_CreateLoginUserAndAccess', @Login, @DbName, N'Reset login password');
        END
        ELSE
            PRINT N'[SKIP] Password reset not requested (@ResetPassword=0).';
    END;

    ---------------------------------------------------------------------------
    -- Ensure database user (inside explicit transaction for atomicity)
    ---------------------------------------------------------------------------
    BEGIN TRY
        DECLARE @sql_ensure_user nvarchar(max) =
            N'USE ' + @DbQ + N';
              IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = @pLogin)
              BEGIN
                  BEGIN TRAN;
                  CREATE USER ' + @LoginQ + N' FOR LOGIN ' + @LoginQ + N';
                  COMMIT;
                  PRINT N''[DONE] Created database user ' + REPLACE(@LoginQ, '''', '''''') + N'.'';
              END
              ELSE
                  PRINT N''[OK] Database user already exists: ' + REPLACE(@LoginQ, '''', '''''') + N'.'';';

        EXEC sys.sp_executesql @sql_ensure_user, N'@pLogin sysname', @pLogin = @Login;

        IF @LogToTable = 1
            INSERT INTO master.dbo.provisioning_log (proc_name, login_name, db_name, action)
            VALUES (N'usp_CreateLoginUserAndAccess', @Login, @DbName, N'Ensured database user');
    END TRY
    BEGIN CATCH
        SET @msg = CONCAT(N'[FAIL] Ensure user failed: ', ERROR_MESSAGE());
        PRINT @msg;
        THROW;
    END CATCH;

    ---------------------------------------------------------------------------
    -- ReplaceAccess cleanup
    ---------------------------------------------------------------------------
    IF @ReplaceAccess = 1
    BEGIN
        PRINT N'[INFO] ReplaceAccess=1: removing managed memberships and cleaning managed schema grants.';

        -----------------------------------------------------------------
        -- Remove from built-in roles
        -----------------------------------------------------------------
        DECLARE @BuiltIn TABLE(RoleName sysname PRIMARY KEY);
        INSERT INTO @BuiltIn(RoleName) VALUES (N'db_owner'),(N'db_datareader'),(N'db_datawriter'),(N'db_ddladmin');

        DECLARE @r sysname;
        DECLARE @sql_drop_builtin nvarchar(max);

        DECLARE curBuilt CURSOR LOCAL FAST_FORWARD FOR SELECT RoleName FROM @BuiltIn;
        OPEN curBuilt;
        FETCH NEXT FROM curBuilt INTO @r;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @sql_drop_builtin =
                N'USE ' + @DbQ + N';
                  IF EXISTS (
                      SELECT 1
                      FROM sys.database_role_members drm
                      JOIN sys.database_principals rp ON rp.principal_id = drm.role_principal_id
                      JOIN sys.database_principals mp ON mp.principal_id = drm.member_principal_id
                      WHERE rp.name = @pRole AND mp.name = @pLogin
                  )
                  BEGIN
                      EXEC (N''ALTER ROLE '' + QUOTENAME(@pRole) + N'' DROP MEMBER ' + @LoginQ + N';'');
                      PRINT N''[DONE] Removed ' + REPLACE(@LoginQ, '''', '''''') + N' from role '' + QUOTENAME(@pRole) + N''.'';
                  END;';

            EXEC sys.sp_executesql
                @sql_drop_builtin,
                N'@pRole sysname, @pLogin sysname',
                @pRole = @r,
                @pLogin = @Login;

            FETCH NEXT FROM curBuilt INTO @r;
        END

        CLOSE curBuilt;
        DEALLOCATE curBuilt;

        -----------------------------------------------------------------
        -- Clean managed schema roles (prefix + optional @CustomRole)
        -----------------------------------------------------------------
        IF OBJECT_ID('tempdb..#RolesToClean') IS NOT NULL DROP TABLE #RolesToClean;
        CREATE TABLE #RolesToClean (RoleName sysname COLLATE DATABASE_DEFAULT PRIMARY KEY);

        DECLARE @rolePrefixFull nvarchar(128) = LEFT(@RolePrefix + N'_' + @Login + N'_schema_access', 128);

        DECLARE @sql_find_roles nvarchar(max) =
            N'USE ' + @DbQ + N';
              INSERT INTO #RolesToClean(RoleName)
              SELECT name
              FROM sys.database_principals
              WHERE type = N''R''
                AND name LIKE @pPrefix + N''%'';';

        EXEC sys.sp_executesql
            @sql_find_roles,
            N'@pPrefix nvarchar(128)',
            @pPrefix = @rolePrefixFull;

        IF @CustomRole IS NOT NULL AND LTRIM(RTRIM(@CustomRole)) <> N''
        BEGIN
            DECLARE @sql_add_custom nvarchar(max) =
                N'USE ' + @DbQ + N';
                  IF EXISTS (SELECT 1 FROM sys.database_principals WHERE type = N''R'' AND name = @pCustom)
                     AND NOT EXISTS (SELECT 1 FROM #RolesToClean WHERE RoleName = @pCustom)
                  INSERT INTO #RolesToClean(RoleName) VALUES (@pCustom);';

            EXEC sys.sp_executesql
                @sql_add_custom,
                N'@pCustom sysname',
                @pCustom = @CustomRole;
        END;

        DECLARE @sql_drop_member nvarchar(max);
        DECLARE @sql_revoke nvarchar(max);
        DECLARE @sql_drop_role nvarchar(max);

        DECLARE curRole CURSOR LOCAL FAST_FORWARD FOR
            SELECT RoleName FROM #RolesToClean;

        OPEN curRole;
        FETCH NEXT FROM curRole INTO @r;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @sql_drop_member =
                N'USE ' + @DbQ + N';
                  IF EXISTS (
                      SELECT 1
                      FROM sys.database_role_members drm
                      JOIN sys.database_principals rp ON rp.principal_id = drm.role_principal_id
                      JOIN sys.database_principals mp ON mp.principal_id = drm.member_principal_id
                      WHERE rp.name = @pRole AND mp.name = @pLogin
                  )
                  BEGIN
                      EXEC (N''ALTER ROLE '' + QUOTENAME(@pRole) + N'' DROP MEMBER ' + @LoginQ + N';'');
                      PRINT N''[DONE] Removed ' + REPLACE(@LoginQ, '''', '''''') + N' from role '' + QUOTENAME(@pRole) + N''.'';
                  END;';

            EXEC sys.sp_executesql
                @sql_drop_member,
                N'@pRole sysname, @pLogin sysname',
                @pRole = @r,
                @pLogin = @Login;

            IF @KeepSchemaRole = 1
            BEGIN
                SET @sql_revoke =
                    N'USE ' + @DbQ + N';
                      DECLARE @revoke nvarchar(max) = N'''';
                      SELECT @revoke = @revoke
                          + N''REVOKE '' + dp.permission_name
                          + N'' ON SCHEMA::'' + QUOTENAME(s.name)
                          + N'' FROM '' + QUOTENAME(@pRole) + N'';'' + CHAR(10)
                      FROM sys.database_permissions dp
                      JOIN sys.database_principals gr ON gr.principal_id = dp.grantee_principal_id
                      JOIN sys.schemas s ON s.schema_id = dp.major_id
                      WHERE gr.name = @pRole
                        AND dp.class_desc = N''SCHEMA''
                        AND dp.state_desc IN (N''GRANT'', N''GRANT_WITH_GRANT_OPTION'')
                        AND dp.permission_name IN (N''SELECT'', N''INSERT'', N''UPDATE'', N''DELETE'', N''EXECUTE'')
                        AND s.name NOT IN (N''sys'', N''INFORMATION_SCHEMA'');

                      IF @revoke <> N''''
                      BEGIN
                          EXEC (@revoke);
                          PRINT N''[DONE] Revoked existing schema grants from role '' + QUOTENAME(@pRole) + N'' (kept role).'';
                      END
                      ELSE
                          PRINT N''[OK] No schema grants found to revoke for role '' + QUOTENAME(@pRole) + N''.'';';

                EXEC sys.sp_executesql
                    @sql_revoke,
                    N'@pRole sysname',
                    @pRole = @r;
            END
            ELSE
            BEGIN
                SET @sql_drop_role =
                    N'USE ' + @DbQ + N';
                      IF NOT EXISTS (
                          SELECT 1
                          FROM sys.database_role_members drm
                          JOIN sys.database_principals rp ON rp.principal_id = drm.role_principal_id
                          WHERE rp.name = @pRole
                      )
                      BEGIN
                          BEGIN TRY
                              EXEC (N''DROP ROLE '' + QUOTENAME(@pRole) + N'';'');
                              PRINT N''[DONE] Dropped empty role '' + QUOTENAME(@pRole) + N''.'';
                          END TRY
                          BEGIN CATCH
                              PRINT N''[WARN] Could not drop role '' + QUOTENAME(@pRole) + N'': '' + ERROR_MESSAGE();
                          END CATCH
                      END;';

                EXEC sys.sp_executesql
                    @sql_drop_role,
                    N'@pRole sysname',
                    @pRole = @r;
            END;

            FETCH NEXT FROM curRole INTO @r;
        END

        CLOSE curRole;
        DEALLOCATE curRole;

        IF @LogToTable = 1
            INSERT INTO master.dbo.provisioning_log (proc_name, login_name, db_name, action)
            VALUES (N'usp_CreateLoginUserAndAccess', @Login, @DbName, N'ReplaceAccess cleanup completed');
    END;

    ---------------------------------------------------------------------------
    -- Apply requested access mode
    ---------------------------------------------------------------------------
    IF @AccessMode = N'NONE'
    BEGIN
        PRINT N'[SKIP] @AccessMode=NONE (no access granted).';
        PRINT CONCAT(N'[OK] Provisioning complete for ', @LoginQ, N' on ', @DbQ, N'.');
        RETURN;
    END;

    IF @AccessMode IN (N'DB_OWNER', N'READ_ALL', N'READWRITE_ALL', N'DDL_ADMIN')
    BEGIN
        DECLARE @sql_apply_builtin nvarchar(max) = N'USE ' + @DbQ + N';' + CHAR(10);

        IF @AccessMode = N'DB_OWNER'
            SET @sql_apply_builtin +=
                N'IF NOT EXISTS (
                      SELECT 1
                      FROM sys.database_role_members drm
                      JOIN sys.database_principals r ON r.principal_id = drm.role_principal_id
                      JOIN sys.database_principals m ON m.principal_id = drm.member_principal_id
                      WHERE r.name = N''db_owner'' AND m.name = @pLogin
                  )
                  BEGIN
                      ALTER ROLE [db_owner] ADD MEMBER ' + @LoginQ + N';
                      PRINT N''[DONE] Granted DB_OWNER via [db_owner].'';
                  END
                  ELSE PRINT N''[OK] Already member of [db_owner].'';';

        IF @AccessMode = N'READ_ALL'
            SET @sql_apply_builtin +=
                N'IF NOT EXISTS (
                      SELECT 1
                      FROM sys.database_role_members drm
                      JOIN sys.database_principals r ON r.principal_id = drm.role_principal_id
                      JOIN sys.database_principals m ON m.principal_id = drm.member_principal_id
                      WHERE r.name = N''db_datareader'' AND m.name = @pLogin
                  )
                  BEGIN
                      ALTER ROLE [db_datareader] ADD MEMBER ' + @LoginQ + N';
                      PRINT N''[DONE] Granted READ_ALL via [db_datareader].'';
                  END
                  ELSE PRINT N''[OK] Already member of [db_datareader].'';';

        IF @AccessMode = N'READWRITE_ALL'
            SET @sql_apply_builtin +=
                N'DECLARE @added_reader BIT = 0, @added_writer BIT = 0;

                  IF NOT EXISTS (
                      SELECT 1
                      FROM sys.database_role_members drm
                      JOIN sys.database_principals r ON r.principal_id = drm.role_principal_id
                      JOIN sys.database_principals m ON m.principal_id = drm.member_principal_id
                      WHERE r.name = N''db_datareader'' AND m.name = @pLogin
                  )
                  BEGIN
                      ALTER ROLE [db_datareader] ADD MEMBER ' + @LoginQ + N';
                      SET @added_reader = 1;
                  END;

                  IF NOT EXISTS (
                      SELECT 1
                      FROM sys.database_role_members drm
                      JOIN sys.database_principals r ON r.principal_id = drm.role_principal_id
                      JOIN sys.database_principals m ON m.principal_id = drm.member_principal_id
                      WHERE r.name = N''db_datawriter'' AND m.name = @pLogin
                  )
                  BEGIN
                      ALTER ROLE [db_datawriter] ADD MEMBER ' + @LoginQ + N';
                      SET @added_writer = 1;
                  END;

                  IF @added_reader = 1 OR @added_writer = 1
                      PRINT N''[DONE] Granted READWRITE_ALL via [db_datareader]+[db_datawriter].''
                  ELSE
                      PRINT N''[OK] Already member of [db_datareader]+[db_datawriter].'';';

        IF @AccessMode = N'DDL_ADMIN'
            SET @sql_apply_builtin +=
                N'IF NOT EXISTS (
                      SELECT 1
                      FROM sys.database_role_members drm
                      JOIN sys.database_principals r ON r.principal_id = drm.role_principal_id
                      JOIN sys.database_principals m ON m.principal_id = drm.member_principal_id
                      WHERE r.name = N''db_ddladmin'' AND m.name = @pLogin
                  )
                  BEGIN
                      ALTER ROLE [db_ddladmin] ADD MEMBER ' + @LoginQ + N';
                      PRINT N''[DONE] Granted DDL_ADMIN via [db_ddladmin].'';
                  END
                  ELSE PRINT N''[OK] Already member of [db_ddladmin].'';';

        EXEC sys.sp_executesql @sql_apply_builtin, N'@pLogin sysname', @pLogin = @Login;

        IF @LogToTable = 1
            INSERT INTO master.dbo.provisioning_log (proc_name, login_name, db_name, action, detail)
            VALUES (N'usp_CreateLoginUserAndAccess', @Login, @DbName, N'Applied access mode', @AccessMode);

        PRINT CONCAT(N'[OK] Provisioning complete for ', @LoginQ, N' on ', @DbQ, N'.');
        RETURN;
    END;

    ---------------------------------------------------------------------------
    -- Schema-scoped modes: READ_SCHEMA / READWRITE_SCHEMA
    ---------------------------------------------------------------------------
    IF @AccessMode IN (N'READ_SCHEMA', N'READWRITE_SCHEMA')
    BEGIN
        DECLARE @roleName sysname =
            COALESCE(NULLIF(LTRIM(RTRIM(@CustomRole)), N''), LEFT(@RolePrefix + N'_' + @Login + N'_schema_access', 128));
        DECLARE @RoleQ nvarchar(258) = QUOTENAME(@roleName);

        -- Ensure role exists in target DB
        DECLARE @sql_ensure_role nvarchar(max) =
            N'USE ' + @DbQ + N';
              IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE type = N''R'' AND name = @pRole)
              BEGIN
                  CREATE ROLE ' + @RoleQ + N';
                  PRINT N''[DONE] Created schema role ' + REPLACE(@RoleQ, '''', '''''') + N'.'';
              END
              ELSE
                  PRINT N''[OK] Schema role exists: ' + REPLACE(@RoleQ, '''', '''''') + N'.'';';

        EXEC sys.sp_executesql @sql_ensure_role, N'@pRole sysname', @pRole = @roleName;

        -- Build schema list into temp table
        IF OBJECT_ID('tempdb..#Schemas') IS NOT NULL DROP TABLE #Schemas;
        CREATE TABLE #Schemas (SchemaName sysname COLLATE DATABASE_DEFAULT PRIMARY KEY);

        DECLARE @sl nvarchar(max) = NULLIF(LTRIM(RTRIM(@SchemaList)), N'');
        IF @sl IS NULL
        BEGIN
            -- Exclude system schemas and built-in role schemas
            DECLARE @sql_all_schemas nvarchar(max) =
                N'USE ' + @DbQ + N';
                  INSERT INTO #Schemas(SchemaName)
                  SELECT s.name
                  FROM sys.schemas s
                  LEFT JOIN sys.database_principals dp ON dp.principal_id = s.principal_id
                  WHERE s.name NOT IN (
                      N''sys'', N''INFORMATION_SCHEMA'', N''guest'',
                      N''db_owner'', N''db_accessadmin'', N''db_securityadmin'',
                      N''db_ddladmin'', N''db_backupoperator'',
                      N''db_datareader'', N''db_datawriter'',
                      N''db_denydatareader'', N''db_denydatawriter''
                  );';

            EXEC (@sql_all_schemas);
            PRINT N'[OK] Schema scope: all non-system schemas.';
        END
        ELSE
        BEGIN
            SET @sl = REPLACE(@sl, N';', N',');

            DECLARE @sql_split_schemas nvarchar(max) =
                N'USE ' + @DbQ + N';
                  INSERT INTO #Schemas(SchemaName)
                  SELECT DISTINCT REPLACE(REPLACE(LTRIM(RTRIM(value)), N''['', N''''), N'']'', N'''')
                  FROM string_split(@pSchemaList, N'','')
                  WHERE LTRIM(RTRIM(value)) <> N'''';';

            EXEC sys.sp_executesql @sql_split_schemas, N'@pSchemaList nvarchar(max)', @pSchemaList = @sl;
            PRINT CONCAT(N'[OK] Schema scope: ', @sl);
        END;

        -- Warn on non-existent schemas (print which ones are missing)
        DECLARE @sql_warn_missing nvarchar(max) =
            N'USE ' + @DbQ + N';
              DECLARE @missing nvarchar(max);
              SELECT @missing = STRING_AGG(x.SchemaName, N'', '')
              FROM #Schemas x
              LEFT JOIN sys.schemas s ON s.name = x.SchemaName
              WHERE s.name IS NULL;

              IF @missing IS NOT NULL
                  PRINT N''[WARN] Schemas not found (will be skipped): '' + @missing;';

        EXEC (@sql_warn_missing);

        -- Build permission list
        DECLARE @perm nvarchar(100) =
            CASE WHEN @AccessMode = N'READ_SCHEMA' THEN N'SELECT'
                 ELSE N'SELECT, INSERT, UPDATE, DELETE' END;

        IF @IncludeExecute = 1
            SET @perm = @perm + N', EXECUTE';

        -- Grant per schema
        DECLARE @schema sysname;
        DECLARE @sql_grant nvarchar(max);

        DECLARE curSch CURSOR LOCAL FAST_FORWARD FOR
            SELECT SchemaName FROM #Schemas ORDER BY SchemaName;

        OPEN curSch;
        FETCH NEXT FROM curSch INTO @schema;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @sql_grant =
                N'USE ' + @DbQ + N';
                  IF EXISTS (SELECT 1 FROM sys.schemas WHERE name = @pSchema AND name NOT IN (N''sys'', N''INFORMATION_SCHEMA''))
                  BEGIN
                      EXEC (N''GRANT ' + @perm + N' ON SCHEMA::'' + QUOTENAME(@pSchema) + N'' TO ' + @RoleQ + N';'');
                      PRINT N''[DONE] Granted ' + @AccessMode + N' on schema '' + QUOTENAME(@pSchema) + N'' to ' + REPLACE(@RoleQ, '''', '''''') + N'.'';
                  END;';

            EXEC sys.sp_executesql @sql_grant, N'@pSchema sysname', @pSchema = @schema;

            FETCH NEXT FROM curSch INTO @schema;
        END

        CLOSE curSch;
        DEALLOCATE curSch;

        -- Add user to schema role (idempotent)
        DECLARE @sql_add_member nvarchar(max) =
            N'USE ' + @DbQ + N';
              IF NOT EXISTS (
                  SELECT 1
                  FROM sys.database_role_members drm
                  JOIN sys.database_principals r ON r.principal_id = drm.role_principal_id
                  JOIN sys.database_principals m ON m.principal_id = drm.member_principal_id
                  WHERE r.name = @pRole AND m.name = @pLogin
              )
              BEGIN
                  ALTER ROLE ' + @RoleQ + N' ADD MEMBER ' + @LoginQ + N';
                  PRINT N''[DONE] Added ' + REPLACE(@LoginQ, '''', '''''') + N' to ' + REPLACE(@RoleQ, '''', '''''') + N'.'';
              END
              ELSE
                  PRINT N''[OK] User already member of ' + REPLACE(@RoleQ, '''', '''''') + N'.'';';

        EXEC sys.sp_executesql
            @sql_add_member,
            N'@pRole sysname, @pLogin sysname',
            @pRole = @roleName,
            @pLogin = @Login;

        IF @LogToTable = 1
            INSERT INTO master.dbo.provisioning_log (proc_name, login_name, db_name, action, detail)
            VALUES (N'usp_CreateLoginUserAndAccess', @Login, @DbName, N'Applied schema access',
                    @AccessMode + N' | Role=' + @roleName + N' | Schemas=' + COALESCE(@sl, N'(all)'));

        PRINT CONCAT(N'[OK] Provisioning complete for ', @LoginQ, N' on ', @DbQ, N'.');
        RETURN;
    END;

    -- Should never reach here due to validation
    SET @msg = N'[FAIL] Unhandled @AccessMode: ' + COALESCE(@AccessMode, N'(NULL)');
    PRINT @msg;
    THROW 50100, @msg, 1;
END;
GO
