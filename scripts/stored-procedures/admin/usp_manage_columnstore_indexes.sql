USE [master]
GO

SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [dbo].[usp_ManageColumnstoreIndexes]
    @DbName     sysname         = NULL,
    @Action     varchar(10)     = 'CREATE',     -- 'CREATE' | 'DROP'
    @Mode       varchar(20)     = 'ALL',         -- 'ALL' | 'SALES_ONLY'

    -- Help
    @Help       bit             = 0
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
        PRINT N'  usp_ManageColumnstoreIndexes';
        PRINT N'  Apply or drop CLUSTERED COLUMNSTORE indexes across user tables.';
        PRINT N'  Schema-agnostic (works even if tables are not in dbo).';
        PRINT N'=================================================================';
        PRINT N'';
        PRINT N'PARAMETERS:';
        PRINT N'  @DbName    sysname      (required) Target database';
        PRINT N'  @Action    varchar(10)  = ''CREATE'' (CREATE | DROP)';
        PRINT N'  @Mode      varchar(20)  = ''ALL''    (ALL | SALES_ONLY)';
        PRINT N'';
        PRINT N'EXAMPLES:';
        PRINT N'';
        PRINT N'  -- 1. Create CCI on all user tables in MyDB';
        PRINT N'  EXEC dbo.usp_ManageColumnstoreIndexes';
        PRINT N'      @DbName = N''MyDB'';';
        PRINT N'';
        PRINT N'  -- 2. Create CCI on Sales table only';
        PRINT N'  EXEC dbo.usp_ManageColumnstoreIndexes';
        PRINT N'      @DbName = N''MyDB'', @Mode = ''SALES_ONLY'';';
        PRINT N'';
        PRINT N'  -- 3. Drop all CCIs from MyDB';
        PRINT N'  EXEC dbo.usp_ManageColumnstoreIndexes';
        PRINT N'      @DbName = N''MyDB'', @Action = ''DROP'';';
        PRINT N'';
        PRINT N'  -- 4. Drop CCI from Sales table only';
        PRINT N'  EXEC dbo.usp_ManageColumnstoreIndexes';
        PRINT N'      @DbName = N''MyDB'', @Action = ''DROP'', @Mode = ''SALES_ONLY'';';
        PRINT N'=================================================================';
        RETURN;
    END

    -----------------------------------------------------------------
    -- @DbName is required for all non-help invocations
    -----------------------------------------------------------------
    IF @DbName IS NULL
    BEGIN
        PRINT N'[FAIL] @DbName is required. Run with @Help = 1 for usage examples.';
        RETURN;
    END;

    IF @Action NOT IN ('CREATE', 'DROP')
    BEGIN
        THROW 51000, 'Invalid @Action. Use CREATE or DROP.', 1;
    END;

    IF @Mode NOT IN ('ALL', 'SALES_ONLY')
    BEGIN
        THROW 51001, 'Invalid @Mode. Use ALL or SALES_ONLY.', 1;
    END;

    IF DB_ID(@DbName) IS NULL
    BEGIN
        DECLARE @db_msg nvarchar(2048) = N'[FAIL] Database not found: ' + @DbName;
        PRINT @db_msg;
        THROW 51002, @db_msg, 1;
    END;

    DECLARE @DbQ nvarchar(258) = QUOTENAME(@DbName);

    PRINT CONCAT(N'[OK] Target: DB=', @DbQ,
                 N' | Action=', @Action,
                 N' | Mode=', @Mode);

    -----------------------------------------------------------------
    -- Resolve target tables via dynamic SQL into a temp table
    -----------------------------------------------------------------
    IF OBJECT_ID('tempdb..#Targets') IS NOT NULL DROP TABLE #Targets;
    CREATE TABLE #Targets (
        schema_name sysname COLLATE DATABASE_DEFAULT NOT NULL,
        table_name  sysname COLLATE DATABASE_DEFAULT NOT NULL,
        object_id   int     NOT NULL
    );

    DECLARE @sql_targets nvarchar(max) =
        N'USE ' + @DbQ + N';
          INSERT INTO #Targets(schema_name, table_name, object_id)
          SELECT s.name, t.name, t.object_id
          FROM sys.tables t
          JOIN sys.schemas s ON s.schema_id = t.schema_id
          WHERE t.is_ms_shipped = 0
            AND s.name NOT IN (N''sys'', N''INFORMATION_SCHEMA'')
            AND (@pMode = ''ALL'' OR t.name = N''Sales'');';

    EXEC sys.sp_executesql
        @sql_targets,
        N'@pMode varchar(20)',
        @pMode = @Mode;

    IF NOT EXISTS (SELECT 1 FROM #Targets)
    BEGIN
        THROW 51003, 'No target tables resolved for CCI operation.', 1;
    END;

    DECLARE @target_count int = (SELECT COUNT(*) FROM #Targets);
    PRINT CONCAT(N'[OK] Resolved ', @target_count, N' target table(s).');

    -----------------------------------------------------------------
    -- Block CREATE if any target has a clustered rowstore index
    -----------------------------------------------------------------
    IF @Action = 'CREATE'
    BEGIN
        DECLARE @blocked nvarchar(max);

        DECLARE @sql_check_blocked nvarchar(max) =
            N'USE ' + @DbQ + N';
              SELECT @pBlocked = STRING_AGG(
                  QUOTENAME(tt.schema_name) + N''.'' + QUOTENAME(tt.table_name), N'', ''
              )
              FROM #Targets tt
              JOIN sys.indexes i ON i.object_id = tt.object_id
              WHERE i.type = 1;';

        EXEC sys.sp_executesql
            @sql_check_blocked,
            N'@pBlocked nvarchar(max) OUTPUT',
            @pBlocked = @blocked OUTPUT;

        IF @blocked IS NOT NULL
        BEGIN
            DECLARE @block_msg nvarchar(2048) =
                N'Blocked: clustered rowstore index exists on: ' + @blocked +
                N'. Convert PKs to NONCLUSTERED or drop clustered indexes before applying CCI.';
            PRINT CONCAT(N'[FAIL] ', @block_msg);
            THROW 51004, @block_msg, 1;
        END;
    END;

    -----------------------------------------------------------------
    -- Apply / drop CCIs
    -----------------------------------------------------------------
    DECLARE @schema sysname, @table sysname, @obj nvarchar(517),
            @sql nvarchar(max), @ix sysname;

    DECLARE cur CURSOR LOCAL FAST_FORWARD READ_ONLY FOR
        SELECT schema_name, table_name
        FROM #Targets
        ORDER BY schema_name, table_name;

    OPEN cur;
    FETCH NEXT FROM cur INTO @schema, @table;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @obj = QUOTENAME(@schema) + N'.' + QUOTENAME(@table);

        IF @Action = 'CREATE'
        BEGIN
            DECLARE @sql_check_cci nvarchar(max);
            DECLARE @has_cci bit = 0;

            SET @sql_check_cci =
                N'USE ' + @DbQ + N';
                  IF EXISTS (
                      SELECT 1 FROM sys.indexes
                      WHERE object_id = OBJECT_ID(@pObj) AND type = 5
                  )
                      SET @pHasCci = 1;';

            EXEC sys.sp_executesql
                @sql_check_cci,
                N'@pObj nvarchar(517), @pHasCci bit OUTPUT',
                @pObj = @obj,
                @pHasCci = @has_cci OUTPUT;

            IF @has_cci = 0
            BEGIN
                SET @sql = N'USE ' + @DbQ + N'; CREATE CLUSTERED COLUMNSTORE INDEX [CCI] ON ' + @obj + N';';
                EXEC sys.sp_executesql @sql;
                PRINT CONCAT(N'[DONE] Created CCI on ', @obj);
            END
            ELSE
                PRINT CONCAT(N'[SKIP] CCI already exists on ', @obj);
        END
        ELSE -- DROP
        BEGIN
            SET @ix = NULL;

            SET @sql = N'USE ' + @DbQ + N';
                         SELECT TOP (1) @pIx = name
                         FROM sys.indexes
                         WHERE object_id = OBJECT_ID(@pObj) AND type = 5;';

            EXEC sys.sp_executesql
                @sql,
                N'@pObj nvarchar(517), @pIx sysname OUTPUT',
                @pObj = @obj,
                @pIx = @ix OUTPUT;

            IF @ix IS NOT NULL
            BEGIN
                SET @sql = N'USE ' + @DbQ + N'; DROP INDEX ' + QUOTENAME(@ix) + N' ON ' + @obj + N';';
                EXEC sys.sp_executesql @sql;
                PRINT CONCAT(N'[DONE] Dropped CCI ', QUOTENAME(@ix), N' on ', @obj);
            END
            ELSE
                PRINT CONCAT(N'[SKIP] No CCI found on ', @obj);
        END

        FETCH NEXT FROM cur INTO @schema, @table;
    END

    CLOSE cur;
    DEALLOCATE cur;

    -----------------------------------------------------------------
    -- Verification
    -----------------------------------------------------------------
    DECLARE @cci_count int;

    SET @sql = N'USE ' + @DbQ + N';
                 SELECT @pCount = COUNT(*)
                 FROM sys.indexes i
                 WHERE i.type = 5
                   AND i.object_id IN (SELECT object_id FROM #Targets);';

    EXEC sys.sp_executesql
        @sql,
        N'@pCount int OUTPUT',
        @pCount = @cci_count OUTPUT;

    IF @Action = 'CREATE' AND @cci_count = 0
    BEGIN
        DECLARE @warn_msg nvarchar(256) =
            N'CCI apply completed but 0 of ' + CAST(@target_count AS nvarchar(10)) + N' target tables have CCIs.';
        THROW 51005, @warn_msg, 1;
    END;

    PRINT CONCAT(N'[OK] Complete. ', @cci_count, N' of ', @target_count, N' target table(s) now have CCIs.');
END;
GO
