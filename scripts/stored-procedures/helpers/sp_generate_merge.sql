-- Generate a MERGE statement template for a given table
-- Useful for building upsert logic quickly
-- Works on: SQL Server 2008+
--
-- Usage: EXEC dbo.sp_generate_merge @schema = 'dbo', @table = 'Products'

CREATE OR ALTER PROCEDURE dbo.sp_generate_merge
    @schema NVARCHAR(128) = 'dbo',
    @table  NVARCHAR(128)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @pk_cols NVARCHAR(MAX) = '';
    DECLARE @all_cols NVARCHAR(MAX) = '';
    DECLARE @update_cols NVARCHAR(MAX) = '';
    DECLARE @insert_cols NVARCHAR(MAX) = '';
    DECLARE @values_cols NVARCHAR(MAX) = '';

    -- Get primary key columns
    SELECT @pk_cols = STRING_AGG(
        'target.' + QUOTENAME(c.COLUMN_NAME) + ' = source.' + QUOTENAME(c.COLUMN_NAME),
        ' AND '
    )
    FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE AS c
    JOIN INFORMATION_SCHEMA.TABLE_CONSTRAINTS AS tc
        ON c.CONSTRAINT_NAME = tc.CONSTRAINT_NAME
    WHERE tc.CONSTRAINT_TYPE = 'PRIMARY KEY'
        AND c.TABLE_SCHEMA = @schema
        AND c.TABLE_NAME = @table;

    -- Get all columns
    SELECT
        @all_cols = STRING_AGG(QUOTENAME(COLUMN_NAME), ', ')
            WITHIN GROUP (ORDER BY ORDINAL_POSITION),
        @insert_cols = STRING_AGG(QUOTENAME(COLUMN_NAME), ', ')
            WITHIN GROUP (ORDER BY ORDINAL_POSITION),
        @values_cols = STRING_AGG('source.' + QUOTENAME(COLUMN_NAME), ', ')
            WITHIN GROUP (ORDER BY ORDINAL_POSITION)
    FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = @schema AND TABLE_NAME = @table;

    -- Non-PK columns for UPDATE set
    SELECT @update_cols = STRING_AGG(
        QUOTENAME(c.COLUMN_NAME) + ' = source.' + QUOTENAME(c.COLUMN_NAME),
        ',
        '
    )
    FROM INFORMATION_SCHEMA.COLUMNS AS c
    WHERE c.TABLE_SCHEMA = @schema
        AND c.TABLE_NAME = @table
        AND c.COLUMN_NAME NOT IN (
            SELECT kcu.COLUMN_NAME
            FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE AS kcu
            JOIN INFORMATION_SCHEMA.TABLE_CONSTRAINTS AS tc
                ON kcu.CONSTRAINT_NAME = tc.CONSTRAINT_NAME
            WHERE tc.CONSTRAINT_TYPE = 'PRIMARY KEY'
                AND kcu.TABLE_SCHEMA = @schema
                AND kcu.TABLE_NAME = @table
        );

    -- Print the MERGE template
    PRINT 'MERGE ' + QUOTENAME(@schema) + '.' + QUOTENAME(@table) + ' AS target';
    PRINT 'USING (';
    PRINT '    -- Replace with your source query or table';
    PRINT '    SELECT ' + @all_cols;
    PRINT '    FROM your_source_table';
    PRINT ') AS source';
    PRINT 'ON ' + ISNULL(@pk_cols, '/* No PK found — add join condition */');
    PRINT '';
    PRINT 'WHEN MATCHED THEN UPDATE SET';
    PRINT '    ' + ISNULL(@update_cols, '/* columns */');
    PRINT '';
    PRINT 'WHEN NOT MATCHED BY TARGET THEN';
    PRINT '    INSERT (' + @insert_cols + ')';
    PRINT '    VALUES (' + @values_cols + ')';
    PRINT '';
    PRINT '-- WHEN NOT MATCHED BY SOURCE THEN DELETE  -- uncomment for full sync';
    PRINT ';';
END;
GO
