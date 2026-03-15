-- SQL Agent job run history — last run status for all jobs
-- Quickly spot failed or long-running jobs
-- Works on: SQL Server 2005+

SELECT
    j.name                          AS job_name,
    j.enabled                       AS is_enabled,
    CASE h.run_status
        WHEN 0 THEN 'Failed'
        WHEN 1 THEN 'Succeeded'
        WHEN 2 THEN 'Retry'
        WHEN 3 THEN 'Canceled'
        WHEN 4 THEN 'In Progress'
    END                             AS last_run_status,
    msdb.dbo.agent_datetime(h.run_date, h.run_time)  AS last_run_datetime,
    STUFF(STUFF(
        RIGHT('000000' + CAST(h.run_duration AS VARCHAR), 6),
        3, 0, ':'), 6, 0, ':')     AS duration_hhmmss,
    h.message                       AS status_message
FROM msdb.dbo.sysjobs AS j
LEFT JOIN (
    SELECT job_id, run_status, run_date, run_time, run_duration, message,
           ROW_NUMBER() OVER (PARTITION BY job_id ORDER BY run_date DESC, run_time DESC) AS rn
    FROM msdb.dbo.sysjobhistory
    WHERE step_id = 0  -- job outcome row
) AS h ON j.job_id = h.job_id AND h.rn = 1
ORDER BY h.run_status ASC, j.name;
