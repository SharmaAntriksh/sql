-- Table sizes — row counts, data size, index size, and total
-- Works on: SQL Server 2005+

SELECT
    s.name + '.' + t.name                                       AS table_name,
    p.rows                                                      AS row_count,
    CAST(SUM(a.total_pages) * 8.0 / 1024 AS DECIMAL(10,2))     AS total_mb,
    CAST(SUM(a.used_pages) * 8.0 / 1024 AS DECIMAL(10,2))      AS used_mb,
    CAST((SUM(a.total_pages) - SUM(a.used_pages)) * 8.0 / 1024
         AS DECIMAL(10,2))                                      AS unused_mb
FROM sys.tables AS t
JOIN sys.schemas AS s ON t.schema_id = s.schema_id
JOIN sys.indexes AS i ON t.object_id = i.object_id
JOIN sys.partitions AS p ON i.object_id = p.object_id AND i.index_id = p.index_id
JOIN sys.allocation_units AS a ON p.partition_id = a.container_id
WHERE t.is_ms_shipped = 0
    AND i.object_id > 255
GROUP BY s.name, t.name, p.rows
ORDER BY SUM(a.total_pages) DESC;
