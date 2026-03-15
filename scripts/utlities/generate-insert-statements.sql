-- Generate INSERT statements for a table's data
-- Useful for migrating small reference/lookup tables
-- Works on: SQL Server 2005+
--
-- Usage: Replace @schema, @table with your target table

DECLARE @schema NVARCHAR(128) = 'dbo';
DECLARE @table  NVARCHAR(128) = 'YourTableName';

DECLARE @cols NVARCHAR(MAX), @vals NVARCHAR(MAX);

SELECT
    @cols = STRING_AGG(QUOTENAME(COLUMN_NAME), ', ')
            WITHIN GROUP (ORDER BY ORDINAL_POSITION),
    @vals = STRING_AGG(
        'ISNULL(QUOTENAME(' + QUOTENAME(COLUMN_NAME) + ', ''''''''), ''NULL'')',
        ' + '', '' + '
    ) WITHIN GROUP (ORDER BY ORDINAL_POSITION)
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = @schema AND TABLE_NAME = @table;

DECLARE @sql NVARCHAR(MAX) = '
    SELECT ''INSERT INTO ' + QUOTENAME(@schema) + '.' + QUOTENAME(@table)
        + ' (' + @cols + ') VALUES ('' + ' + @vals + ' + '');''
    FROM ' + QUOTENAME(@schema) + '.' + QUOTENAME(@table);

EXEC sp_executesql @sql;
