-- Top 20 most expensive queries by total CPU time
-- Useful for identifying optimization targets
-- Works on: SQL Server 2005+

SELECT TOP 20
    qs.total_worker_time / 1000                       AS total_cpu_ms,
    qs.execution_count,
    qs.total_worker_time / qs.execution_count / 1000  AS avg_cpu_ms,
    qs.total_elapsed_time / 1000                      AS total_elapsed_ms,
    qs.total_logical_reads,
    qs.total_logical_reads / qs.execution_count       AS avg_logical_reads,
    SUBSTRING(
        st.text,
        (qs.statement_start_offset / 2) + 1,
        (CASE qs.statement_end_offset
            WHEN -1 THEN DATALENGTH(st.text)
            ELSE qs.statement_end_offset
        END - qs.statement_start_offset) / 2 + 1
    )                                                 AS query_text,
    qp.query_plan,
    qs.creation_time,
    qs.last_execution_time
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
ORDER BY qs.total_worker_time DESC;
