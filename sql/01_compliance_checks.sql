/*
  Database-layer compliance checks for RDS for SQL Server.
  AWS Config and Security Hub cover the account and network. They cannot see inside SQL Server,
  and RDS has no operating system to put a CimTrak agent on, so these checks run as T-SQL.
  Same idea as the sql_shr table: every run is logged, history is kept, failures alert.

  Where to run: SSMS connected to the RDS endpoint as the master user (dbadmin).
  Run the whole file once. It creates the Admin database, the results table and the procedure.
*/

IF DB_ID('Admin') IS NULL
    CREATE DATABASE [Admin];
GO

USE [Admin];
GO

IF OBJECT_ID('dbo.ComplianceResults') IS NULL
CREATE TABLE dbo.ComplianceResults (
    ResultID      INT IDENTITY PRIMARY KEY,
    RunID         UNIQUEIDENTIFIER NOT NULL,
    RunTimeUtc    DATETIME2(0)     NOT NULL DEFAULT SYSUTCDATETIME(),
    CheckID       VARCHAR(20)      NOT NULL,
    CheckName     NVARCHAR(200)    NOT NULL,
    DatabaseName  SYSNAME          NULL,
    ObjectName    NVARCHAR(256)    NULL,
    Status        VARCHAR(10)      NOT NULL,   -- PASS or FAIL
    Detail        NVARCHAR(1000)   NULL
);
GO

CREATE OR ALTER PROCEDURE dbo.usp_RunComplianceChecks
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @run UNIQUEIDENTIFIER = NEWID();
    DECLARE @db SYSNAME, @sql NVARCHAR(MAX), @n INT;

    /* RDS internal logins and databases that are not ours to change */
    DECLARE @rdsLogins TABLE (name SYSNAME PRIMARY KEY);
    INSERT @rdsLogins VALUES ('rdsa'), ('NT AUTHORITY\SYSTEM');

    ----------------------------------------------------------------
    -- 1. SQL logins must enforce password policy and expiration (CIS 4.3)
    ----------------------------------------------------------------
    INSERT dbo.ComplianceResults (RunID, CheckID, CheckName, ObjectName, Status, Detail)
    SELECT @run, '4.3', 'SQL login enforces password policy and expiration', l.name, 'FAIL',
           CONCAT('is_policy_checked=', l.is_policy_checked, ', is_expiration_checked=', l.is_expiration_checked)
    FROM sys.sql_logins l
    WHERE l.is_disabled = 0
      AND l.name NOT LIKE '##%'
      AND l.name NOT IN (SELECT name FROM @rdsLogins)
      AND (l.is_policy_checked = 0 OR l.is_expiration_checked = 0);

    IF @@ROWCOUNT = 0
        INSERT dbo.ComplianceResults (RunID, CheckID, CheckName, Status)
        VALUES (@run, '4.3', 'SQL login enforces password policy and expiration', 'PASS');

    ----------------------------------------------------------------
    -- 2. public server role has only Microsoft's default permissions (CIS 3.10)
    --    Defaults: VIEW ANY DATABASE, and CONNECT on the T-SQL endpoints
    ----------------------------------------------------------------
    INSERT dbo.ComplianceResults (RunID, CheckID, CheckName, ObjectName, Status, Detail)
    SELECT @run, '3.10', 'public server role has only default permissions',
           p.permission_name, 'FAIL', CONCAT('class=', p.class_desc, ', state=', p.state_desc)
    FROM sys.server_permissions p
    WHERE p.grantee_principal_id = SUSER_ID('public')
      AND NOT (p.class = 100 AND p.permission_name = 'VIEW ANY DATABASE')
      AND NOT (p.class = 105 AND p.permission_name = 'CONNECT');

    IF @@ROWCOUNT = 0
        INSERT dbo.ComplianceResults (RunID, CheckID, CheckName, Status)
        VALUES (@run, '3.10', 'public server role has only default permissions', 'PASS');

    ----------------------------------------------------------------
    -- 3. Cross-database ownership chaining is off at the server (CIS 2.3)
    ----------------------------------------------------------------
    INSERT dbo.ComplianceResults (RunID, CheckID, CheckName, Status, Detail)
    SELECT @run, '2.3', 'Cross db ownership chaining disabled',
           CASE WHEN CAST(value_in_use AS INT) = 0 THEN 'PASS' ELSE 'FAIL' END,
           CONCAT('value_in_use=', CAST(value_in_use AS INT))
    FROM sys.configurations
    WHERE name = 'cross db ownership chaining';

    ----------------------------------------------------------------
    -- 4. TRUSTWORTHY is off on user databases (CIS 2.9)
    ----------------------------------------------------------------
    INSERT dbo.ComplianceResults (RunID, CheckID, CheckName, DatabaseName, Status)
    SELECT @run, '2.9', 'TRUSTWORTHY is off', d.name, 'FAIL'
    FROM sys.databases d
    WHERE d.database_id > 4
      AND d.name <> 'rdsadmin'
      AND d.is_trustworthy_on = 1;

    IF @@ROWCOUNT = 0
        INSERT dbo.ComplianceResults (RunID, CheckID, CheckName, Status)
        VALUES (@run, '2.9', 'TRUSTWORTHY is off', 'PASS');

    ----------------------------------------------------------------
    -- 5 and 6. Per user database: guest cannot connect (CIS 3.2),
    --          and there are no orphaned users (CIS 3.3)
    ----------------------------------------------------------------
    CREATE TABLE #perDb (CheckID VARCHAR(20), CheckName NVARCHAR(200), DatabaseName SYSNAME, ObjectName NVARCHAR(256));

    DECLARE dbs CURSOR LOCAL FAST_FORWARD FOR
        SELECT name FROM sys.databases
        WHERE database_id > 4 AND name <> 'rdsadmin' AND state = 0;   -- online user databases only

    OPEN dbs;
    FETCH NEXT FROM dbs INTO @db;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @sql = N'
        USE ' + QUOTENAME(@db) + N';

        INSERT #perDb
        SELECT ''3.2'', ''guest user cannot connect'', DB_NAME(), ''guest''
        FROM sys.database_permissions
        WHERE grantee_principal_id = DATABASE_PRINCIPAL_ID(''guest'')
          AND permission_name = ''CONNECT''
          AND state IN (''G'', ''W'');

        INSERT #perDb
        SELECT ''3.3'', ''No orphaned database users'', DB_NAME(), dp.name
        FROM sys.database_principals dp
        LEFT JOIN sys.server_principals sp ON sp.sid = dp.sid
        WHERE dp.type IN (''S'', ''U'', ''G'')
          AND dp.authentication_type IN (1, 3)      -- mapped to a login (SQL or Windows)
          AND dp.name NOT IN (''dbo'', ''guest'', ''INFORMATION_SCHEMA'', ''sys'')
          AND sp.sid IS NULL;';

        EXEC sys.sp_executesql @sql;
        FETCH NEXT FROM dbs INTO @db;
    END;
    CLOSE dbs;
    DEALLOCATE dbs;

    INSERT dbo.ComplianceResults (RunID, CheckID, CheckName, DatabaseName, ObjectName, Status)
    SELECT @run, CheckID, CheckName, DatabaseName, ObjectName, 'FAIL'
    FROM #perDb;

    INSERT dbo.ComplianceResults (RunID, CheckID, CheckName, Status)
    SELECT @run, c.CheckID, c.CheckName, 'PASS'
    FROM (VALUES ('3.2', N'guest user cannot connect'), ('3.3', N'No orphaned database users')) c (CheckID, CheckName)
    WHERE NOT EXISTS (SELECT 1 FROM #perDb p WHERE p.CheckID = c.CheckID);

    ----------------------------------------------------------------
    -- Results for this run, failures first
    ----------------------------------------------------------------
    SELECT CheckID, CheckName, DatabaseName, ObjectName, Status, Detail
    FROM dbo.ComplianceResults
    WHERE RunID = @run
    ORDER BY CASE Status WHEN 'FAIL' THEN 0 ELSE 1 END, CheckID;

    SELECT @n = COUNT(*) FROM dbo.ComplianceResults WHERE RunID = @run AND Status = 'FAIL';

    -- Fail the SQL Agent job when anything fails, so the job failure alert fires
    IF @n > 0
        RAISERROR('Compliance checks found %d failure(s). See Admin.dbo.ComplianceResults.', 16, 1, @n);
END;
GO

/* Run it once by hand to see the current score */
EXEC dbo.usp_RunComplianceChecks;
GO
