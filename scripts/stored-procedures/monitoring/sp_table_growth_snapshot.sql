-- Capture table size snapshots for tracking growth over time
-- Creates a tracking table on first run, then inserts current sizes
-- Works on: SQL Server 2005+
--
-- Usage: EXEC dbo.sp_table_growth_snapshot  (run daily via SQL Agent)
--        SELECT * FROM dbo.table_growth_log ORDER BY snapshot_date DESC

CREATE OR ALTER PROCEDURE dbo.sp_table_growth_snapshot
AS
BEGIN
    SET NOCOUNT ON;

    -- Create tracking table if it doesn't exist
    IF OBJECT_ID('dbo.table_growth_log', 'U') IS NULL
    BEGIN
        CREATE TABLE dbo.table_growth_log (
            id            INT IDENTITY(1,1) PRIMARY KEY,
            snapshot_date DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
            schema_name   NVARCHAR(128),
            table_name    NVARCHAR(128),
            row_count     BIGINT,
            total_mb      DECIMAL(12,2),
            used_mb       DECIMAL(12,2)
        );
        CREATE INDEX IX_table_growth_log_date ON dbo.table_growth_log (snapshot_date);
    END

    INSERT INTO dbo.table_growth_log (schema_name, table_name, row_count, total_mb, used_mb)
    SELECT
        s.name,
        t.name,
        p.rows,
        CAST(SUM(a.total_pages) * 8.0 / 1024 AS DECIMAL(12,2)),
        CAST(SUM(a.used_pages) * 8.0 / 1024 AS DECIMAL(12,2))
    FROM sys.tables AS t
    JOIN sys.schemas AS s ON t.schema_id = s.schema_id
    JOIN sys.indexes AS i ON t.object_id = i.object_id
    JOIN sys.partitions AS p ON i.object_id = p.object_id AND i.index_id = p.index_id
    JOIN sys.allocation_units AS a ON p.partition_id = a.container_id
    WHERE t.is_ms_shipped = 0
        AND i.index_id IN (0, 1)
    GROUP BY s.name, t.name, p.rows;

    PRINT 'Snapshot captured: ' + CONVERT(VARCHAR, SYSUTCDATETIME(), 121);
END;
GO
