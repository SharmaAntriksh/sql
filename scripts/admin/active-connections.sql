-- Active connections and what they're doing
-- Works on: SQL Server 2005+

SELECT
    s.session_id,
    s.login_name,
    s.host_name,
    s.program_name,
    DB_NAME(s.database_id)  AS database_name,
    s.status,
    s.cpu_time,
    s.memory_usage * 8      AS memory_kb,
    s.reads,
    s.writes,
    s.login_time,
    s.last_request_start_time,
    t.text                  AS current_query
FROM sys.dm_exec_sessions AS s
LEFT JOIN sys.dm_exec_requests AS r ON s.session_id = r.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
WHERE s.is_user_process = 1
ORDER BY s.cpu_time DESC;
