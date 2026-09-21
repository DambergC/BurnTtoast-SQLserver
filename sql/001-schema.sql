-- Run in the target database. The script does not create a database or a login.
-- Change the database name in your deployment process before execution.

CREATE TABLE dbo.ToastGroup (
    GroupId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_ToastGroup PRIMARY KEY,
    GroupName nvarchar(128) NOT NULL CONSTRAINT UQ_ToastGroup_GroupName UNIQUE,
    IsActive bit NOT NULL CONSTRAINT DF_ToastGroup_IsActive DEFAULT (1),
    CreatedUtc datetime2(0) NOT NULL CONSTRAINT DF_ToastGroup_CreatedUtc DEFAULT (SYSUTCDATETIME())
);

CREATE TABLE dbo.ToastClient (
    ClientId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_ToastClient PRIMARY KEY,
    ComputerName nvarchar(256) NOT NULL CONSTRAINT UQ_ToastClient_ComputerName UNIQUE,
    IsActive bit NOT NULL CONSTRAINT DF_ToastClient_IsActive DEFAULT (1),
    LastSeenUtc datetime2(0) NULL,
    CreatedUtc datetime2(0) NOT NULL CONSTRAINT DF_ToastClient_CreatedUtc DEFAULT (SYSUTCDATETIME())
);

CREATE TABLE dbo.ToastClientGroup (
    ClientId int NOT NULL,
    GroupId int NOT NULL,
    CONSTRAINT PK_ToastClientGroup PRIMARY KEY (ClientId, GroupId),
    CONSTRAINT FK_ToastClientGroup_Client FOREIGN KEY (ClientId) REFERENCES dbo.ToastClient(ClientId),
    CONSTRAINT FK_ToastClientGroup_Group FOREIGN KEY (GroupId) REFERENCES dbo.ToastGroup(GroupId)
);

CREATE TABLE dbo.ToastMessage (
    MessageId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_ToastMessage PRIMARY KEY,
    GroupId int NOT NULL,
    Title nvarchar(200) NOT NULL,
    Body nvarchar(4000) NOT NULL,
    CreatedUtc datetime2(0) NOT NULL CONSTRAINT DF_ToastMessage_CreatedUtc DEFAULT (SYSUTCDATETIME()),
    ExpiresUtc datetime2(0) NULL,
    IsCancelled bit NOT NULL CONSTRAINT DF_ToastMessage_IsCancelled DEFAULT (0),
    CONSTRAINT FK_ToastMessage_Group FOREIGN KEY (GroupId) REFERENCES dbo.ToastGroup(GroupId)
);

CREATE TABLE dbo.ToastDelivery (
    MessageId bigint NOT NULL,
    ClientId int NOT NULL,
    Status varchar(20) NOT NULL CONSTRAINT DF_ToastDelivery_Status DEFAULT ('Pending'),
    Attempts int NOT NULL CONSTRAINT DF_ToastDelivery_Attempts DEFAULT (0),
    LastAttemptUtc datetime2(0) NULL,
    DeliveredUtc datetime2(0) NULL,
    ErrorMessage nvarchar(2000) NULL,
    CONSTRAINT PK_ToastDelivery PRIMARY KEY (MessageId, ClientId),
    CONSTRAINT FK_ToastDelivery_Message FOREIGN KEY (MessageId) REFERENCES dbo.ToastMessage(MessageId),
    CONSTRAINT FK_ToastDelivery_Client FOREIGN KEY (ClientId) REFERENCES dbo.ToastClient(ClientId),
    CONSTRAINT CK_ToastDelivery_Status CHECK (Status IN ('Pending','Delivered','Failed','Cancelled'))
);

CREATE INDEX IX_ToastDelivery_Client_Status ON dbo.ToastDelivery(ClientId, Status, MessageId);
CREATE INDEX IX_ToastMessage_Group_Created ON dbo.ToastMessage(GroupId, CreatedUtc);

GO
CREATE OR ALTER PROCEDURE dbo.usp_QueueToastMessage
    @GroupName nvarchar(128), @Title nvarchar(200), @Body nvarchar(4000), @ExpiresUtc datetime2(0) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @GroupId int = (SELECT GroupId FROM dbo.ToastGroup WHERE GroupName=@GroupName AND IsActive=1);
    IF @GroupId IS NULL THROW 50001, 'Active toast group was not found.', 1;
    BEGIN TRAN;
    INSERT dbo.ToastMessage(GroupId,Title,Body,ExpiresUtc) VALUES(@GroupId,@Title,@Body,@ExpiresUtc);
    DECLARE @MessageId bigint = SCOPE_IDENTITY();
    INSERT dbo.ToastDelivery(MessageId,ClientId)
      SELECT @MessageId, ClientId FROM dbo.ToastClientGroup WHERE GroupId=@GroupId;
    COMMIT;
    SELECT @MessageId AS MessageId;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetPendingToast
    @ComputerName nvarchar(256)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @ClientId int = (SELECT ClientId FROM dbo.ToastClient WHERE ComputerName=@ComputerName AND IsActive=1);
    UPDATE dbo.ToastClient SET LastSeenUtc=SYSUTCDATETIME() WHERE ClientId=@ClientId;
    SELECT TOP (20) d.MessageId, m.Title, m.Body
    FROM dbo.ToastDelivery d JOIN dbo.ToastMessage m ON m.MessageId=d.MessageId
    WHERE d.ClientId=@ClientId AND d.Status='Pending' AND m.IsCancelled=0
      AND (m.ExpiresUtc IS NULL OR m.ExpiresUtc>SYSUTCDATETIME())
    ORDER BY d.MessageId;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RecordToastDelivery
    @ComputerName nvarchar(256), @MessageId bigint, @Status varchar(20), @ErrorMessage nvarchar(2000)=NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @ClientId int = (SELECT ClientId FROM dbo.ToastClient WHERE ComputerName=@ComputerName);
    UPDATE dbo.ToastDelivery SET Status=@Status, Attempts=Attempts+1, LastAttemptUtc=SYSUTCDATETIME(),
      DeliveredUtc=CASE WHEN @Status='Delivered' THEN SYSUTCDATETIME() ELSE DeliveredUtc END,
      ErrorMessage=@ErrorMessage
    WHERE MessageId=@MessageId AND ClientId=@ClientId;
END;
GO

-- Example data:
INSERT dbo.ToastGroup(GroupName) VALUES ('IT-TEST');
