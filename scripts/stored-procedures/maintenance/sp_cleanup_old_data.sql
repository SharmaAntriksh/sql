-- Delete old rows in batches to avoid log bloat and blocking
-- Works on: SQL Server 2005+
--
-- Usage: EXEC dbo.sp_cleanup_old_data
--          @table_name = 'dbo.AuditLog',
--          @date_column = 'created_at',
--          @days_to_keep = 90,
--          @batch_size = 5000,
--          @execute = 0

CREATE OR ALTER PROCEDURE dbo.sp_cleanup_old_data
    @table_name   NVARCHAR(256),
    @date_column  NVARCHAR(128),
    @days_to_keep INT = 90,
    @batch_size   INT = 5000,
    @execute      BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @cutoff_date DATETIME = DATEADD(DAY, -@days_to_keep, GETDATE());
    DECLARE @rows_deleted INT = 1;
    DECLARE @total_deleted INT = 0;
    DECLARE @sql NVARCHAR(MAX);

    -- Preview what would be deleted
    SET @sql = 'SELECT COUNT(*) AS rows_to_delete FROM ' + @table_name
             + ' WHERE ' + QUOTENAME(@date_column) + ' < @cutoff';
    EXEC sp_executesql @sql, N'@cutoff DATETIME', @cutoff = @cutoff_date;

    IF @execute = 0
    BEGIN
        PRINT 'Dry run — set @execute = 1 to delete rows.';
        PRINT 'Cutoff date: ' + CONVERT(VARCHAR, @cutoff_date, 121);
        RETURN;
    END

    -- Delete in batches
    WHILE @rows_deleted > 0
    BEGIN
        SET @sql = 'DELETE TOP (' + CAST(@batch_size AS VARCHAR) + ') FROM ' + @table_name
                 + ' WHERE ' + QUOTENAME(@date_column) + ' < @cutoff';

        EXEC sp_executesql @sql, N'@cutoff DATETIME', @cutoff = @cutoff_date;
        SET @rows_deleted = @@ROWCOUNT;
        SET @total_deleted += @rows_deleted;

        IF @rows_deleted > 0
        BEGIN
            -- Brief pause to let other transactions through
            WAITFOR DELAY '00:00:01';
            PRINT 'Deleted batch: ' + CAST(@rows_deleted AS VARCHAR)
                + ' | Total: ' + CAST(@total_deleted AS VARCHAR);
        END
    END

    PRINT 'Cleanup complete. Total rows deleted: ' + CAST(@total_deleted AS VARCHAR);
END;
GO
