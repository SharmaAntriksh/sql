-- Extract recent deadlock events from the system health extended event session
-- No setup required — uses the always-on system_health session
-- Works on: SQL Server 2012+
--
-- Usage: EXEC dbo.sp_deadlock_history @hours_back = 24

CREATE OR ALTER PROCEDURE dbo.sp_deadlock_history
    @hours_back INT = 24
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH deadlocks AS (
        SELECT
            xdr.value('@timestamp', 'DATETIME2') AS deadlock_time,
            xdr.query('.')                        AS deadlock_xml
        FROM (
            SELECT CAST(target_data AS XML) AS target_xml
            FROM sys.dm_xe_session_targets AS st
            JOIN sys.dm_xe_sessions AS s ON st.event_session_address = s.address
            WHERE s.name = 'system_health'
                AND st.target_name = 'ring_buffer'
        ) AS data
        CROSS APPLY target_xml.nodes('RingBufferTarget/event[@name="xml_deadlock_report"]') AS xev(xdr)
    )
    SELECT
        deadlock_time,
        deadlock_xml
    FROM deadlocks
    WHERE deadlock_time >= DATEADD(HOUR, -@hours_back, GETDATE())
    ORDER BY deadlock_time DESC;
END;
GO
