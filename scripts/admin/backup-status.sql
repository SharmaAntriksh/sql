-- Last backup status for all databases
-- Quickly spot databases with stale or missing backups
-- Works on: SQL Server 2005+

SELECT
    d.name                          AS database_name,
    d.recovery_model_desc           AS recovery_model,
    MAX(CASE WHEN b.type = 'D' THEN b.backup_finish_date END) AS last_full_backup,
    MAX(CASE WHEN b.type = 'I' THEN b.backup_finish_date END) AS last_diff_backup,
    MAX(CASE WHEN b.type = 'L' THEN b.backup_finish_date END) AS last_log_backup,
    DATEDIFF(HOUR,
        MAX(CASE WHEN b.type = 'D' THEN b.backup_finish_date END),
        GETDATE()
    )                               AS hours_since_full_backup
FROM sys.databases AS d
LEFT JOIN msdb.dbo.backupset AS b ON d.name = b.database_name
WHERE d.database_id > 4  -- exclude system databases
    AND d.state_desc = 'ONLINE'
GROUP BY d.name, d.recovery_model_desc
ORDER BY last_full_backup ASC;
