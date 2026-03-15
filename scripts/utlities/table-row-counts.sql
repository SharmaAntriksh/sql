-- Quick row counts for all tables in the database
-- Uses partition stats instead of COUNT(*) so it doesn't scan every table
-- Works on: SQL Server 2005+

SELECT
    OBJECT_SCHEMA_NAME(p.object_id) AS schema_name,
    OBJECT_NAME(p.object_id)        AS table_name,
    SUM(p.rows)                     AS row_count
FROM sys.partitions AS p
JOIN sys.tables AS t ON p.object_id = t.object_id
WHERE p.index_id IN (0, 1)  -- heap or clustered index
GROUP BY p.object_id
ORDER BY SUM(p.rows) DESC;
