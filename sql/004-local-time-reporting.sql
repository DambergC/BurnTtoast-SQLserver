SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @Sql1 nvarchar(max) = N'
CREATE OR ALTER FUNCTION dbo.ufn_ToastMessageLocal
(
    @TimeZoneName sysname = NULL
)
RETURNS TABLE
AS
RETURN
(
    -- @TimeZoneName is intentionally ignored for backward compatibility.
    SELECT
        m.MessageId,
        m.GroupId,
        m.Title,
        m.Body,
        m.CreatedUtc,
        m.ExpiresUtc,
        m.CreatedUtc AS CreatedLocalTime,
        m.ExpiresUtc AS ExpiresLocalTime
    FROM dbo.ToastMessage m
);';

DECLARE @Sql2 nvarchar(max) = N'
CREATE OR ALTER FUNCTION dbo.ufn_ToastDeliveryLocal
(
    @TimeZoneName sysname = NULL
)
RETURNS TABLE
AS
RETURN
(
    -- @TimeZoneName is intentionally ignored for backward compatibility.
    SELECT
        d.MessageId,
        d.ClientId,
        d.Status,
        d.Attempts,
        d.LastAttemptUtc,
        d.DeliveredUtc,
        c.LastSeenUtc,
        d.LastAttemptUtc AS LastAttemptLocalTime,
        d.DeliveredUtc AS DeliveredLocalTime,
        c.LastSeenUtc AS LastSeenLocalTime
    FROM dbo.ToastDelivery d
    INNER JOIN dbo.ToastClient c ON c.ClientId = d.ClientId
);';

DECLARE @Sql3 nvarchar(max) = N'
CREATE OR ALTER VIEW dbo.vw_ToastMessageLocal
AS
SELECT
    m.MessageId,
    m.GroupId,
    m.Title,
    m.Body,
    m.CreatedUtc,
    m.ExpiresUtc,
    m.CreatedUtc AS CreatedLocalTime,
    m.ExpiresUtc AS ExpiresLocalTime
FROM dbo.ToastMessage m;';

DECLARE @Sql4 nvarchar(max) = N'
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
    d.LastAttemptUtc AS LastAttemptLocalTime,
    d.DeliveredUtc AS DeliveredLocalTime,
    c.LastSeenUtc AS LastSeenLocalTime
FROM dbo.ToastDelivery d
INNER JOIN dbo.ToastClient c ON c.ClientId = d.ClientId;';

EXEC sp_executesql @Sql1;
EXEC sp_executesql @Sql2;
EXEC sp_executesql @Sql3;
EXEC sp_executesql @Sql4;
