-- Find missing indexes recommended by SQL Server query optimizer
-- Ranks by estimated improvement impact
-- Works on: SQL Server 2005+

SELECT
    ROUND(s.avg_total_user_cost * s.avg_user_impact * (s.user_seeks + s.user_scans), 0) AS improvement_measure,
    DB_NAME(d.database_id)          AS database_name,
    d.statement                     AS table_name,
    d.equality_columns,
    d.inequality_columns,
    d.included_columns,
    s.user_seeks,
    s.user_scans,
    s.avg_total_user_cost,
    s.avg_user_impact
FROM sys.dm_db_missing_index_details     AS d
JOIN sys.dm_db_missing_index_groups      AS g ON d.index_handle = g.index_handle
JOIN sys.dm_db_missing_index_group_stats AS s ON g.index_group_handle = s.group_handle
WHERE d.database_id = DB_ID()
ORDER BY improvement_measure DESC;
