/*
  Schedules the compliance checks daily with SQL Agent on RDS.
  Where to run: SSMS connected to the RDS endpoint as the master user, after 01_compliance_checks.sql.
  The RDS master user can create and own SQL Agent jobs in msdb.
*/

USE [msdb];
GO

IF EXISTS (SELECT 1 FROM dbo.sysjobs WHERE name = N'DBA - Daily Compliance Checks')
    EXEC dbo.sp_delete_job @job_name = N'DBA - Daily Compliance Checks';
GO

EXEC dbo.sp_add_job
     @job_name    = N'DBA - Daily Compliance Checks',
     @description = N'Runs Admin.dbo.usp_RunComplianceChecks and fails if any check fails.',
     @enabled     = 1;

EXEC dbo.sp_add_jobstep
     @job_name      = N'DBA - Daily Compliance Checks',
     @step_name     = N'Run checks',
     @subsystem     = N'TSQL',
     @database_name = N'Admin',
     @command       = N'EXEC dbo.usp_RunComplianceChecks;';

EXEC dbo.sp_add_schedule
     @schedule_name     = N'Daily 06:00 UTC',
     @freq_type         = 4,        -- daily
     @freq_interval     = 1,
     @active_start_time = 060000;

EXEC dbo.sp_attach_schedule
     @job_name      = N'DBA - Daily Compliance Checks',
     @schedule_name = N'Daily 06:00 UTC';

EXEC dbo.sp_add_jobserver
     @job_name = N'DBA - Daily Compliance Checks';
GO

/* Compliance trend: the last 30 days of failures by check */
SELECT CAST(RunTimeUtc AS DATE) AS RunDate, CheckID, CheckName, COUNT(*) AS Failures
FROM Admin.dbo.ComplianceResults
WHERE Status = 'FAIL'
  AND RunTimeUtc >= DATEADD(DAY, -30, SYSUTCDATETIME())
GROUP BY CAST(RunTimeUtc AS DATE), CheckID, CheckName
ORDER BY RunDate DESC, CheckID;
GO
