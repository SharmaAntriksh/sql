-- Database sizes and file details for all databases on the server
-- Works on: SQL Server 2005+

SELECT
    db.name                                                     AS database_name,
    db.state_desc                                               AS state,
    db.recovery_model_desc                                      AS recovery_model,
    CAST(SUM(mf.size) * 8.0 / 1024 AS DECIMAL(10,2))           AS total_size_mb,
    CAST(SUM(CASE WHEN mf.type = 0 THEN mf.size END) * 8.0 / 1024
         AS DECIMAL(10,2))                                      AS data_size_mb,
    CAST(SUM(CASE WHEN mf.type = 1 THEN mf.size END) * 8.0 / 1024
         AS DECIMAL(10,2))                                      AS log_size_mb,
    db.create_date,
    db.collation_name
FROM sys.databases AS db
JOIN sys.master_files AS mf ON db.database_id = mf.database_id
GROUP BY db.name, db.state_desc, db.recovery_model_desc,
         db.create_date, db.collation_name
ORDER BY SUM(mf.size) DESC;
