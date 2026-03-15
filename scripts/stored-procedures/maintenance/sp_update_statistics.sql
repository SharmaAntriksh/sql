-- Update statistics for tables where stats are stale
-- Targets tables with significant row modifications since last stats update
-- Works on: SQL Server 2008+
--
-- Usage: EXEC dbo.sp_update_statistics @threshold_pct = 10, @execute = 0

CREATE OR ALTER PROCEDURE dbo.sp_update_statistics
    @threshold_pct FLOAT = 10.0,  -- % of rows modified to trigger update
    @execute BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @commands TABLE (
        id INT IDENTITY(1,1),
        table_name NVARCHAR(256),
        stat_name NVARCHAR(256),
        rows_total BIGINT,
        rows_modified BIGINT,
        modified_pct FLOAT,
        command NVARCHAR(MAX)
    );

    INSERT INTO @commands (table_name, stat_name, rows_total, rows_modified, modified_pct, command)
    SELECT
        OBJECT_SCHEMA_NAME(s.object_id) + '.' + OBJECT_NAME(s.object_id),
        s.name,
        sp.rows,
        sp.modification_counter,
        CASE WHEN sp.rows > 0
             THEN (sp.modification_counter * 100.0) / sp.rows
             ELSE 0
        END,
        'UPDATE STATISTICS ' + QUOTENAME(OBJECT_SCHEMA_NAME(s.object_id))
            + '.' + QUOTENAME(OBJECT_NAME(s.object_id))
            + ' ' + QUOTENAME(s.name) + ' WITH FULLSCAN;'
    FROM sys.stats AS s
    CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) AS sp
    WHERE OBJECTPROPERTY(s.object_id, 'IsUserTable') = 1
        AND sp.rows > 0
        AND (sp.modification_counter * 100.0) / sp.rows >= @threshold_pct
    ORDER BY sp.modification_counter DESC;

    -- Show the plan
    SELECT * FROM @commands;

    IF @execute = 0
    BEGIN
        PRINT 'Dry run — set @execute = 1 to update statistics.';
        RETURN;
    END

    DECLARE @cmd NVARCHAR(MAX);
    DECLARE @id INT = 1, @max INT = (SELECT MAX(id) FROM @commands);

    WHILE @id <= @max
    BEGIN
        SELECT @cmd = command FROM @commands WHERE id = @id;
        BEGIN TRY
            EXEC sp_executesql @cmd;
            PRINT 'OK: ' + @cmd;
        END TRY
        BEGIN CATCH
            PRINT 'FAILED: ' + @cmd + ' | ' + ERROR_MESSAGE();
        END CATCH
        SET @id += 1;
    END

    PRINT 'Statistics update complete.';
END;
GO
