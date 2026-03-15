-- Audit user permissions across the current database
-- Shows server logins, database users, role memberships, and explicit grants
-- Works on: SQL Server 2005+

-- Database role memberships
SELECT
    dp.name         AS user_name,
    dp.type_desc    AS user_type,
    r.name          AS role_name
FROM sys.database_principals AS dp
JOIN sys.database_role_members AS drm ON dp.principal_id = drm.member_principal_id
JOIN sys.database_principals AS r ON drm.role_principal_id = r.principal_id
WHERE dp.type IN ('S', 'U', 'G')  -- SQL user, Windows user, Windows group
ORDER BY dp.name, r.name;

-- Explicit object-level permissions
SELECT
    pr.name                         AS principal_name,
    pr.type_desc                    AS principal_type,
    pe.state_desc                   AS permission_state,
    pe.permission_name,
    OBJECT_SCHEMA_NAME(pe.major_id) + '.' + OBJECT_NAME(pe.major_id) AS object_name,
    pe.class_desc
FROM sys.database_permissions AS pe
JOIN sys.database_principals AS pr ON pe.grantee_principal_id = pr.principal_id
WHERE pe.major_id > 0
    AND pr.name NOT IN ('public', 'guest')
ORDER BY pr.name, OBJECT_NAME(pe.major_id);
