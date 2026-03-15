-- Identify current blocking chains
-- Shows the head blocker and all sessions waiting on it
-- Works on: SQL Server 2005+

-- Current blocking at a glance
SELECT
    r.session_id            AS blocked_session,
    r.blocking_session_id   AS blocking_session,
    r.wait_type,
    r.wait_time / 1000      AS wait_seconds,
    r.status,
    DB_NAME(r.database_id)  AS database_name,
    blocked_text.text        AS blocked_query,
    blocker_text.text        AS blocker_query,
    r.command,
    r.percent_complete
FROM sys.dm_exec_requests AS r
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) AS blocked_text
LEFT JOIN sys.dm_exec_requests AS br
    ON r.blocking_session_id = br.session_id
OUTER APPLY sys.dm_exec_sql_text(br.sql_handle) AS blocker_text
WHERE r.blocking_session_id > 0
ORDER BY r.wait_time DESC;

-- Head blockers (sessions blocking others but not blocked themselves)
SELECT
    s.session_id,
    s.login_name,
    s.host_name,
    s.program_name,
    s.status,
    t.text AS current_query,
    COUNT(*) OVER (PARTITION BY s.session_id) AS sessions_blocked
FROM sys.dm_exec_sessions AS s
JOIN sys.dm_exec_requests AS r ON s.session_id = r.session_id
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
WHERE s.session_id IN (
    SELECT blocking_session_id
    FROM sys.dm_exec_requests
    WHERE blocking_session_id > 0
)
AND s.session_id NOT IN (
    SELECT session_id
    FROM sys.dm_exec_requests
    WHERE blocking_session_id > 0
);
