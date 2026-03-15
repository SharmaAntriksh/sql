-- Compare two tables to find rows that differ
-- Uses EXCEPT to find mismatches in both directions
-- Works on: SQL Server 2005+
--
-- Usage: Replace TableA / TableB with your table names

-- Rows in TableA but not in TableB
SELECT 'Only in TableA' AS source, *
FROM (
    SELECT * FROM dbo.TableA
    EXCEPT
    SELECT * FROM dbo.TableB
) AS diff_a;

-- Rows in TableB but not in TableA
SELECT 'Only in TableB' AS source, *
FROM (
    SELECT * FROM dbo.TableB
    EXCEPT
    SELECT * FROM dbo.TableA
) AS diff_b;
