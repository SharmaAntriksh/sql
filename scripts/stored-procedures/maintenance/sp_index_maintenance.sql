-- Rebuild or reorganize indexes based on fragmentation level
-- Reorganize at 10-30% fragmentation, rebuild above 30%
-- Works on: SQL Server 2005+
--
-- Usage: EXEC dbo.sp_index_maintenance @database_name = 'YourDB', @execute = 0 (dry run)

CREATE OR ALTER PROCEDURE dbo.sp_index_maintenance
    @database_name NVARCHAR(128) = NULL,
    @frag_threshold_reorg  FLOAT = 10.0,
    @frag_threshold_rebuild FLOAT = 30.0,
    @min_page_count INT = 1000,
    @execute BIT = 0  -- 0 = print only, 1 = execute
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @sql NVARCHAR(MAX);
    DECLARE @db NVARCHAR(128) = ISNULL(@database_name, DB_NAME());

    DECLARE @commands TABLE (
        id INT IDENTITY(1,1),
        table_name NVARCHAR(256),
        index_name NVARCHAR(256),
        frag_pct FLOAT,
        page_count BIGINT,
        command NVARCHAR(MAX)
    );

    INSERT INTO @commands (table_name, index_name, frag_pct, page_count, command)
    SELECT
        OBJECT_SCHEMA_NAME(ips.object_id) + '.' + OBJECT_NAME(ips.object_id),
        i.name,
        ips.avg_fragmentation_in_percent,
        ips.page_count,
        CASE
            WHEN ips.avg_fragmentation_in_percent >= @frag_threshold_rebuild
                THEN 'ALTER INDEX ' + QUOTENAME(i.name) + ' ON '
                     + QUOTENAME(OBJECT_SCHEMA_NAME(ips.object_id)) + '.'
                     + QUOTENAME(OBJECT_NAME(ips.object_id))
                     + ' REBUILD WITH (ONLINE = ON, SORT_IN_TEMPDB = ON);'
            WHEN ips.avg_fragmentation_in_percent >= @frag_threshold_reorg
                THEN 'ALTER INDEX ' + QUOTENAME(i.name) + ' ON '
                     + QUOTENAME(OBJECT_SCHEMA_NAME(ips.object_id)) + '.'
                     + QUOTENAME(OBJECT_NAME(ips.object_id))
                     + ' REORGANIZE;'
        END
    FROM sys.dm_db_index_physical_stats(DB_ID(@db), NULL, NULL, NULL, 'LIMITED') AS ips
    JOIN sys.indexes AS i ON ips.object_id = i.object_id AND ips.index_id = i.index_id
    WHERE ips.avg_fragmentation_in_percent >= @frag_threshold_reorg
        AND ips.page_count >= @min_page_count
        AND i.name IS NOT NULL
    ORDER BY ips.avg_fragmentation_in_percent DESC;

    -- Output the plan
    SELECT table_name, index_name, frag_pct, page_count, command FROM @commands;

    -- Execute if requested
    IF @execute = 1
    BEGIN
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
    END
END;
GO
