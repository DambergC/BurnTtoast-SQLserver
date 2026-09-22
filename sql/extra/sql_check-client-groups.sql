SELECT
    c.ComputerName,
    g.GroupName,
    c.IsActive AS ClientIsActive,
    g.IsActive AS GroupIsActive
FROM dbo.ToastClient AS c
INNER JOIN dbo.ToastClientGroup AS cg
    ON cg.ClientId = c.ClientId
INNER JOIN dbo.ToastGroup AS g
    ON g.GroupId = cg.GroupId
WHERE c.ComputerName = N'DIN-KLIENT'
ORDER BY g.GroupName;