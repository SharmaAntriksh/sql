-- Snapshot of all currently executing queries with resource usage
-- A lightweight alternative to sp_whoisactive
-- Works on: SQL Server 2005+
--
-- Usage: EXEC dbo.sp_who_is_running @min_elapsed_ms = 0

CREATE OR ALTER PROCEDURE dbo.sp_who_is_running
    @min_elapsed_ms INT = 0,
    @database_name  NVARCHAR(128) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        r.session_id,
        r.blocking_session_id,
        DB_NAME(r.database_id)          AS database_name,
        s.login_name,
        s.host_name,
        r.status,
        r.command,
        r.wait_type,
        r.wait_time                     AS wait_time_ms,
        r.total_elapsed_time            AS elapsed_ms,
        r.cpu_time                      AS cpu_ms,
        r.reads                         AS logical_reads,
        r.writes,
        r.granted_query_memory * 8      AS granted_memory_kb,
        r.percent_complete,
        SUBSTRING(
            t.text,
            (r.statement_start_offset / 2) + 1,
            (CASE r.statement_end_offset
                WHEN -1 THEN DATALENGTH(t.text)
                ELSE r.statement_end_offset
            END - r.statement_start_offset) / 2 + 1
        )                               AS current_statement,
        t.text                          AS full_query,
        qp.query_plan
    FROM sys.dm_exec_requests AS r
    JOIN sys.dm_exec_sessions AS s ON r.session_id = s.session_id
    CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
    OUTER APPLY sys.dm_exec_query_plan(r.plan_handle) AS qp
    WHERE s.is_user_process = 1
        AND r.session_id <> @@SPID
        AND r.total_elapsed_time >= @min_elapsed_ms
        AND (@database_name IS NULL OR DB_NAME(r.database_id) = @database_name)
    ORDER BY r.total_elapsed_time DESC;
END;
GO
