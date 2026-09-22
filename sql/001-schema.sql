CREATE TABLE dbo.ToastGroup (
    GroupId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_ToastGroup PRIMARY KEY,
    GroupName nvarchar(128) NOT NULL CONSTRAINT UQ_ToastGroup_GroupName UNIQUE,
    IsActive bit NOT NULL CONSTRAINT DF_ToastGroup_IsActive DEFAULT (1),
    CreatedUtc datetime2(0) NOT NULL CONSTRAINT DF_ToastGroup_CreatedUtc DEFAULT (SYSDATETIME())
);

CREATE TABLE dbo.ToastClient (
    ClientId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_ToastClient PRIMARY KEY,
    ComputerName nvarchar(256) NOT NULL CONSTRAINT UQ_ToastClient_ComputerName UNIQUE,
    IsActive bit NOT NULL CONSTRAINT DF_ToastClient_IsActive DEFAULT (1),
    LastSeenUtc datetime2(0) NULL,
    CreatedUtc datetime2(0) NOT NULL CONSTRAINT DF_ToastClient_CreatedUtc DEFAULT (SYSDATETIME())
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
    CreatedUtc datetime2(0) NOT NULL CONSTRAINT DF_ToastMessage_CreatedUtc DEFAULT (SYSDATETIME()),
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