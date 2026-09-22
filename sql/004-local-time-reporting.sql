SET NOCOUNT ON;
SET XACT_ABORT ON;

-- Change this value and re-run the script to set another default reporting timezone.
DECLARE @DefaultLocalTimeZone sysname = N'W. Europe Standard Time';

GO
CREATE OR ALTER FUNCTION dbo.ufn_ToastMessageLocal
(
    @TimeZoneName sysname = N'W. Europe Standard Time'
)
RETURNS TABLE
AS
RETURN
(
    SELECT
        m.MessageId,
        m.GroupId,
        m.Title,
        m.Body,
        m.CreatedUtc,
        m.ExpiresUtc,
        m.CreatedUtc AT TIME ZONE 'UTC' AT TIME ZONE @TimeZoneName AS CreatedLocalTime,
        m.ExpiresUtc AT TIME ZONE 'UTC' AT TIME ZONE @TimeZoneName AS ExpiresLocalTime
    FROM dbo.ToastMessage m
);
GO

CREATE OR ALTER FUNCTION dbo.ufn_ToastDeliveryLocal
(
    @TimeZoneName sysname = N'W. Europe Standard Time'
)
RETURNS TABLE
AS
RETURN
(
    SELECT
        d.MessageId,
        d.ClientId,
        d.Status,
        d.Attempts,
        d.LastAttemptUtc,
        d.DeliveredUtc,
        c.LastSeenUtc,
        d.LastAttemptUtc AT TIME ZONE 'UTC' AT TIME ZONE @TimeZoneName AS LastAttemptLocalTime,
        d.DeliveredUtc AT TIME ZONE 'UTC' AT TIME ZONE @TimeZoneName AS DeliveredLocalTime,
        c.LastSeenUtc AT TIME ZONE 'UTC' AT TIME ZONE @TimeZoneName AS LastSeenLocalTime
    FROM dbo.ToastDelivery d
    INNER JOIN dbo.ToastClient c ON c.ClientId = d.ClientId
);
GO

DECLARE @DefaultLocalTimeZone sysname = N'W. Europe Standard Time';
DECLARE @CreateMessageViewSql nvarchar(max) = N'
CREATE OR ALTER VIEW dbo.vw_ToastMessageLocal
AS
SELECT
    m.MessageId,
    m.GroupId,
    m.Title,
    m.Body,
    m.CreatedUtc,
    m.ExpiresUtc,
    m.CreatedUtc AT TIME ZONE ''UTC'' AT TIME ZONE ''' + REPLACE(@DefaultLocalTimeZone, '''', '''''') + N''' AS CreatedLocalTime,
    m.ExpiresUtc AT TIME ZONE ''UTC'' AT TIME ZONE ''' + REPLACE(@DefaultLocalTimeZone, '''', '''''') + N''' AS ExpiresLocalTime
FROM dbo.ToastMessage m;';
EXEC sp_executesql @CreateMessageViewSql;

DECLARE @CreateDeliveryViewSql nvarchar(max) = N'
CREATE OR ALTER VIEW dbo.vw_ToastDeliveryLocal
AS
SELECT
    d.MessageId,
    d.ClientId,
    d.Status,
    d.Attempts,
    d.LastAttemptUtc,
    d.DeliveredUtc,
    c.LastSeenUtc,
    d.LastAttemptUtc AT TIME ZONE ''UTC'' AT TIME ZONE ''' + REPLACE(@DefaultLocalTimeZone, '''', '''''') + N''' AS LastAttemptLocalTime,
    d.DeliveredUtc AT TIME ZONE ''UTC'' AT TIME ZONE ''' + REPLACE(@DefaultLocalTimeZone, '''', '''''') + N''' AS DeliveredLocalTime,
    c.LastSeenUtc AT TIME ZONE ''UTC'' AT TIME ZONE ''' + REPLACE(@DefaultLocalTimeZone, '''', '''''') + N''' AS LastSeenLocalTime
FROM dbo.ToastDelivery d
INNER JOIN dbo.ToastClient c ON c.ClientId = d.ClientId;';
EXEC sp_executesql @CreateDeliveryViewSql;
