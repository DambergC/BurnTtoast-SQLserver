SET NOCOUNT ON;
SET XACT_ABORT ON;

IF COL_LENGTH('dbo.ToastMessage', 'ButtonText') IS NULL
    ALTER TABLE dbo.ToastMessage ADD ButtonText nvarchar(200) NULL;

IF COL_LENGTH('dbo.ToastMessage', 'ButtonArguments') IS NULL
    ALTER TABLE dbo.ToastMessage ADD ButtonArguments nvarchar(2048) NULL;

IF COL_LENGTH('dbo.ToastMessage', 'ButtonActivationType') IS NULL
    ALTER TABLE dbo.ToastMessage ADD ButtonActivationType varchar(20) NULL;

GO
CREATE OR ALTER PROCEDURE dbo.usp_QueueToastMessage
    @GroupName nvarchar(128),
    @Title nvarchar(200),
    @Body nvarchar(4000),
    @ExpiresUtc datetime2(0) = NULL,
    @AppLogoPath nvarchar(1024) = NULL,
    @HeroImagePath nvarchar(1024) = NULL,
    @Sound varchar(20) = NULL,
    @IsUrgent bit = 0,
    @RepeatIntervalSeconds int = NULL,
    @RepeatCount int = NULL,
    @ButtonText nvarchar(200) = NULL,
    @ButtonArguments nvarchar(2048) = NULL,
    @ButtonActivationType varchar(20) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF (@RepeatIntervalSeconds IS NULL AND @RepeatCount IS NOT NULL) OR (@RepeatIntervalSeconds IS NOT NULL AND @RepeatCount IS NULL)
        THROW 50002, 'RepeatIntervalSeconds and RepeatCount must both be provided for repeating messages.', 1;

    IF @RepeatIntervalSeconds IS NOT NULL AND @RepeatIntervalSeconds < 1
        THROW 50003, 'RepeatIntervalSeconds must be greater than zero.', 1;

    IF @RepeatCount IS NOT NULL AND @RepeatCount < 2
        THROW 50004, 'RepeatCount must be 2 or greater because it includes the first display.', 1;

    SET @ButtonText = NULLIF(LTRIM(RTRIM(@ButtonText)), '');
    SET @ButtonArguments = NULLIF(LTRIM(RTRIM(@ButtonArguments)), '');
    SET @ButtonActivationType = NULLIF(LTRIM(RTRIM(@ButtonActivationType)), '');

    IF @ButtonText IS NULL AND @ButtonArguments IS NOT NULL
        THROW 50008, 'ButtonText must be provided when ButtonArguments is supplied.', 1;

    IF @ButtonText IS NULL AND @ButtonActivationType IS NOT NULL
        THROW 50009, 'ButtonText must be provided when ButtonActivationType is supplied.', 1;

    IF @ButtonText IS NOT NULL AND @ButtonActivationType IS NULL
        SET @ButtonActivationType = 'Protocol';

    IF @ButtonActivationType IS NOT NULL AND @ButtonActivationType NOT IN ('Protocol','Dismiss')
        THROW 50010, 'ButtonActivationType must be Protocol or Dismiss.', 1;

    IF @ButtonText IS NOT NULL AND @ButtonActivationType = 'Protocol' AND @ButtonArguments IS NULL
        THROW 50011, 'ButtonArguments is required when ButtonActivationType is Protocol.', 1;

    DECLARE @ButtonUriSchemeSeparator int = CHARINDEX(':', @ButtonArguments);
    IF @ButtonText IS NOT NULL AND @ButtonActivationType = 'Protocol' AND (
        @ButtonUriSchemeSeparator <= 1
        OR SUBSTRING(@ButtonArguments, 1, 1) NOT LIKE '[A-Za-z]'
        OR PATINDEX('%[^A-Za-z0-9+.-]%', LEFT(@ButtonArguments, @ButtonUriSchemeSeparator - 1)) > 0
    )
        THROW 50012, 'ButtonArguments must look like a valid absolute URI when ButtonActivationType is Protocol.', 1;

    DECLARE @GroupId int = (SELECT GroupId FROM dbo.ToastGroup WHERE GroupName = @GroupName AND IsActive = 1);
    IF @GroupId IS NULL THROW 50001, 'Active toast group was not found.', 1;

    BEGIN TRAN;

    INSERT dbo.ToastMessage(
        GroupId,
        Title,
        Body,
        ExpiresUtc,
        AppLogoPath,
        HeroImagePath,
        Sound,
        IsUrgent,
        RepeatIntervalSeconds,
        RepeatCount,
        ButtonText,
        ButtonArguments,
        ButtonActivationType
    )
    VALUES(
        @GroupId,
        @Title,
        @Body,
        @ExpiresUtc,
        NULLIF(@AppLogoPath, ''),
        NULLIF(@HeroImagePath, ''),
        NULLIF(@Sound, ''),
        ISNULL(@IsUrgent, 0),
        @RepeatIntervalSeconds,
        @RepeatCount,
        @ButtonText,
        @ButtonArguments,
        @ButtonActivationType
    );

    DECLARE @MessageId bigint = SCOPE_IDENTITY();

    INSERT dbo.ToastDelivery(MessageId, ClientId)
        SELECT @MessageId, ClientId
        FROM dbo.ToastClientGroup
        WHERE GroupId = @GroupId;

    COMMIT;

    SELECT @MessageId AS MessageId;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetPendingToast
    @ComputerName nvarchar(256)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ClientId int = (SELECT ClientId FROM dbo.ToastClient WHERE ComputerName = @ComputerName AND IsActive = 1);
    IF @ClientId IS NULL RETURN;

    DECLARE @Now datetime2(0) = SYSUTCDATETIME();
    DECLARE @LeaseSeconds int = 120;

    UPDATE dbo.ToastClient
    SET LastSeenUtc = @Now
    WHERE ClientId = @ClientId;

    ;WITH DueMessages AS (
        SELECT TOP (20) d.ClientId, d.MessageId
        FROM dbo.ToastDelivery d WITH (UPDLOCK, READPAST, ROWLOCK)
        INNER JOIN dbo.ToastMessage m ON m.MessageId = d.MessageId
        WHERE d.ClientId = @ClientId
          AND m.IsCancelled = 0
          AND (m.ExpiresUtc IS NULL OR m.ExpiresUtc > @Now)
          AND d.NextShowUtc <= @Now
          AND (
                d.Status = 'Pending'
                OR (d.Status = 'InProgress' AND d.LeaseExpiresUtc IS NOT NULL AND d.LeaseExpiresUtc <= @Now)
              )
        ORDER BY d.MessageId
    )
    UPDATE d
    SET Status = 'InProgress',
        LeaseId = NEWID(),
        LeaseExpiresUtc = DATEADD(second, @LeaseSeconds, @Now),
        ErrorMessage = NULL
    OUTPUT inserted.MessageId,
           inserted.LeaseId,
           m.Title,
           m.Body,
           m.AppLogoPath,
           m.HeroImagePath,
           m.Sound,
           m.IsUrgent,
           m.ButtonText,
           m.ButtonArguments,
           m.ButtonActivationType,
           m.RepeatIntervalSeconds,
           m.RepeatCount,
           m.ExpiresUtc,
           inserted.ShowCount
    FROM dbo.ToastDelivery d
    INNER JOIN DueMessages x ON x.ClientId = d.ClientId AND x.MessageId = d.MessageId
    INNER JOIN dbo.ToastMessage m ON m.MessageId = d.MessageId
    WHERE d.ClientId = @ClientId;
END;
GO
