-- Generate CREATE TABLE DDL for an existing table
-- Includes columns, data types, nullability, defaults, and primary key
-- Works on: SQL Server 2017+ (uses STRING_AGG)
--
-- Usage: EXEC dbo.sp_script_table_ddl @schema = 'dbo', @table = 'Orders'

CREATE OR ALTER PROCEDURE dbo.sp_script_table_ddl
    @schema NVARCHAR(128) = 'dbo',
    @table  NVARCHAR(128)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @columns NVARCHAR(MAX);
    DECLARE @pk NVARCHAR(MAX);
    DECLARE @ddl NVARCHAR(MAX);

    -- Columns (STRING_AGG guarantees all rows are included)
    SELECT @columns = STRING_AGG(
        CAST(
            '    ' + QUOTENAME(c.COLUMN_NAME) + ' '
            + c.DATA_TYPE
            + CASE
                WHEN c.DATA_TYPE IN ('varchar','nvarchar','char','nchar','varbinary')
                    THEN '(' + CASE WHEN c.CHARACTER_MAXIMUM_LENGTH = -1 THEN 'MAX'
                               ELSE CAST(c.CHARACTER_MAXIMUM_LENGTH AS VARCHAR) END + ')'
                WHEN c.DATA_TYPE IN ('decimal','numeric')
                    THEN '(' + CAST(c.NUMERIC_PRECISION AS VARCHAR) + ','
                         + CAST(c.NUMERIC_SCALE AS VARCHAR) + ')'
                ELSE ''
              END
            + CASE WHEN COLUMNPROPERTY(OBJECT_ID(QUOTENAME(@schema) + '.' + QUOTENAME(@table)),
                        c.COLUMN_NAME, 'IsIdentity') = 1
                   THEN ' IDENTITY(1,1)' ELSE '' END
            + CASE WHEN c.IS_NULLABLE = 'NO' THEN ' NOT NULL' ELSE ' NULL' END
            + CASE WHEN c.COLUMN_DEFAULT IS NOT NULL
                   THEN ' DEFAULT ' + c.COLUMN_DEFAULT ELSE '' END
        AS NVARCHAR(MAX)),
        ',' + CHAR(13) + CHAR(10)
    ) WITHIN GROUP (ORDER BY c.ORDINAL_POSITION)
    FROM INFORMATION_SCHEMA.COLUMNS AS c
    WHERE c.TABLE_SCHEMA = @schema AND c.TABLE_NAME = @table;

    -- Primary key
    SELECT @pk = 'CONSTRAINT ' + QUOTENAME(tc.CONSTRAINT_NAME)
        + ' PRIMARY KEY ('
        + STRING_AGG(QUOTENAME(kcu.COLUMN_NAME), ', ')
            WITHIN GROUP (ORDER BY kcu.ORDINAL_POSITION)
        + ')'
    FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS AS tc
    JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE AS kcu
        ON tc.CONSTRAINT_NAME = kcu.CONSTRAINT_NAME
    WHERE tc.TABLE_SCHEMA = @schema
        AND tc.TABLE_NAME = @table
        AND tc.CONSTRAINT_TYPE = 'PRIMARY KEY'
    GROUP BY tc.CONSTRAINT_NAME;

    -- Assemble DDL
    SET @ddl = 'CREATE TABLE ' + QUOTENAME(@schema) + '.' + QUOTENAME(@table) + ' (' + CHAR(13) + CHAR(10)
             + @columns;

    IF @pk IS NOT NULL
        SET @ddl = @ddl + ',' + CHAR(13) + CHAR(10) + '    ' + @pk;

    SET @ddl = @ddl + CHAR(13) + CHAR(10) + ');';

    PRINT @ddl;
END;
GO
