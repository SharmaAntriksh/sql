-- Index usage statistics — find unused or underused indexes
-- Indexes with zero seeks/scans but high updates are candidates for removal
-- Works on: SQL Server 2005+

SELECT
    OBJECT_SCHEMA_NAME(i.object_id) + '.' + OBJECT_NAME(i.object_id) AS table_name,
    i.name                  AS index_name,
    i.type_desc             AS index_type,
    s.user_seeks,
    s.user_scans,
    s.user_lookups,
    s.user_updates,
    s.last_user_seek,
    s.last_user_scan,
    ps.row_count,
    CAST(ps.reserved_page_count * 8.0 / 1024 AS DECIMAL(10,2)) AS size_mb
FROM sys.indexes AS i
LEFT JOIN sys.dm_db_index_usage_stats AS s
    ON i.object_id = s.object_id
    AND i.index_id = s.index_id
    AND s.database_id = DB_ID()
JOIN sys.dm_db_partition_stats AS ps
    ON i.object_id = ps.object_id
    AND i.index_id = ps.index_id
WHERE OBJECTPROPERTY(i.object_id, 'IsUserTable') = 1
    AND i.index_id > 0  -- exclude heaps
ORDER BY s.user_seeks + s.user_scans + s.user_lookups ASC;
