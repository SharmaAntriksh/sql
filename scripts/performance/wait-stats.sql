-- Server-level wait statistics
-- Shows what SQL Server spends the most time waiting on
-- Works on: SQL Server 2005+

-- Filter out benign/idle waits to focus on actionable ones
WITH waits AS (
    SELECT
        wait_type,
        wait_time_ms / 1000.0                              AS wait_time_s,
        signal_wait_time_ms / 1000.0                       AS signal_wait_time_s,
        (wait_time_ms - signal_wait_time_ms) / 1000.0      AS resource_wait_time_s,
        waiting_tasks_count,
        100.0 * wait_time_ms / SUM(wait_time_ms) OVER ()   AS pct
    FROM sys.dm_os_wait_stats
    WHERE wait_type NOT IN (
        -- Idle / background waits to ignore
        'CLR_SEMAPHORE', 'LAZYWRITER_SLEEP', 'RESOURCE_QUEUE',
        'SLEEP_TASK', 'SLEEP_SYSTEMTASK', 'SQLTRACE_BUFFER_FLUSH',
        'WAITFOR', 'LOGMGR_QUEUE', 'CHECKPOINT_QUEUE',
        'REQUEST_FOR_DEADLOCK_SEARCH', 'XE_TIMER_EVENT',
        'BROKER_TO_FLUSH', 'BROKER_TASK_STOP', 'CLR_MANUAL_EVENT',
        'CLR_AUTO_EVENT', 'DISPATCHER_QUEUE_SEMAPHORE',
        'FT_IFTS_SCHEDULER_IDLE_WAIT', 'XE_DISPATCHER_WAIT',
        'XE_DISPATCHER_JOIN', 'SQLTRACE_INCREMENTAL_FLUSH_SLEEP',
        'ONDEMAND_TASK_QUEUE', 'BROKER_EVENTHANDLER',
        'SLEEP_BPOOL_FLUSH', 'DIRTY_PAGE_POLL',
        'HADR_FILESTREAM_IOMGR_IOCOMPLETION',
        'SP_SERVER_DIAGNOSTICS_SLEEP'
    )
    AND waiting_tasks_count > 0
)
SELECT
    wait_type,
    waiting_tasks_count,
    CAST(wait_time_s AS DECIMAL(14,2))          AS wait_time_s,
    CAST(resource_wait_time_s AS DECIMAL(14,2)) AS resource_wait_s,
    CAST(signal_wait_time_s AS DECIMAL(14,2))   AS signal_wait_s,
    CAST(pct AS DECIMAL(5,2))                   AS pct_of_total
FROM waits
ORDER BY wait_time_s DESC;
