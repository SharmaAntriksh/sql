-- Search for a value across all columns of all tables
-- Useful for tracing where a specific value lives in an unfamiliar database
-- Works on: SQL Server 2005+
--
-- WARNING: Scans every string column in every table — slow on large databases
-- Usage: EXEC dbo.sp_search_all_tables @search_value = 'john@example.com'

CREATE OR ALTER PROCEDURE dbo.sp_search_all_tables
    @search_value NVARCHAR(256)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @results TABLE (
        table_name  NVARCHAR(256),
        column_name NVARCHAR(128),
        match_count INT
    );

    DECLARE @table NVARCHAR(256), @column NVARCHAR(128), @sql NVARCHAR(MAX);
    DECLARE @count INT;

    DECLARE col_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT
            QUOTENAME(TABLE_SCHEMA) + '.' + QUOTENAME(TABLE_NAME),
            QUOTENAME(COLUMN_NAME)
        FROM INFORMATION_SCHEMA.COLUMNS
        WHERE DATA_TYPE IN ('char','varchar','nchar','nvarchar','text','ntext');

    OPEN col_cursor;
    FETCH NEXT FROM col_cursor INTO @table, @column;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @sql = 'SELECT @cnt = COUNT(*) FROM ' + @table
                 + ' WHERE ' + @column + ' LIKE @val';
        BEGIN TRY
            EXEC sp_executesql @sql,
                N'@val NVARCHAR(256), @cnt INT OUTPUT',
                @val = @search_value,
                @cnt = @count OUTPUT;

            IF @count > 0
                INSERT INTO @results VALUES (@table, @column, @count);
        END TRY
        BEGIN CATCH
            -- Skip columns that error (e.g., computed columns)
        END CATCH

        FETCH NEXT FROM col_cursor INTO @table, @column;
    END

    CLOSE col_cursor;
    DEALLOCATE col_cursor;

    SELECT * FROM @results ORDER BY match_count DESC;
END;
GO
