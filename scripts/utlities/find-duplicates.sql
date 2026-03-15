-- Find duplicate rows based on specified columns
-- Works on: SQL Server / PostgreSQL / MySQL (standard SQL)
--
-- Usage: Replace table_name and the GROUP BY columns

SELECT
    column1,
    column2,
    COUNT(*) AS duplicate_count
FROM dbo.table_name
GROUP BY column1, column2
HAVING COUNT(*) > 1
ORDER BY COUNT(*) DESC;

-- To see the actual duplicate rows with all columns:
WITH dupes AS (
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY column1, column2
            ORDER BY (SELECT NULL)
        ) AS rn
    FROM dbo.table_name
)
SELECT *
FROM dupes
WHERE rn > 1;
