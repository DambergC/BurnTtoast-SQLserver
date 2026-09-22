DECLARE @ComputerName nvarchar(256) = N'DIN-KLIENT';

DELETE cg
FROM dbo.ToastClientGroup AS cg
INNER JOIN dbo.ToastClient AS c
    ON c.ClientId = cg.ClientId
WHERE c.ComputerName = @ComputerName;

INSERT dbo.ToastClientGroup (ClientId, GroupId)
SELECT c.ClientId, g.GroupId
FROM dbo.ToastClient AS c
CROSS JOIN dbo.ToastGroup AS g
WHERE c.ComputerName = @ComputerName
  AND g.GroupName IN (N'IT', N'Stockholm', N'Servers')
  AND g.IsActive = 1;