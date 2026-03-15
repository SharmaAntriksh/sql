-- Search for columns by name across all tables and views
-- Replace 'email' with the column name you're looking for
-- Works on: SQL Server 2005+

DECLARE @search NVARCHAR(128) = '%email%';

SELECT
    TABLE_SCHEMA,
    TABLE_NAME,
    COLUMN_NAME,
    DATA_TYPE,
    CHARACTER_MAXIMUM_LENGTH,
    IS_NULLABLE
FROM INFORMATION_SCHEMA.COLUMNS
WHERE COLUMN_NAME LIKE @search
ORDER BY TABLE_SCHEMA, TABLE_NAME, ORDINAL_POSITION;
