DELETE cg
FROM dbo.ToastClientGroup AS cg
INNER JOIN dbo.ToastClient AS c
    ON c.ClientId = cg.ClientId
INNER JOIN dbo.ToastGroup AS g
    ON g.GroupId = cg.GroupId
WHERE c.ComputerName = N'DIN-KLIENT'
  AND g.GroupName = N'OldGroup';