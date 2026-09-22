# BurnTtoast-SQLserver

Gruppbaserade Windows-notiser med [BurntToast](https://github.com/Windos/BurntToast), PowerShell och Microsoft SQL Server.

## Arkitektur

- Administratören köar ett meddelande till en grupp i SQL Server.
- Klienterna pollar SQL Server över **TCP 1433**.
- Varje klient visar BurntToast lokalt i den interaktiva användarsessionen.
- Leverans och kvittens sparas i SQL Server.

Toasten skickas alltså inte via SQL eller WinRM. SQL används som kö och statuslager.

## Förutsättningar

- Windows PowerShell 5.1 eller PowerShell 7.
- SQL Server med en standardinstans lyssnande på TCP 1433.
- Klienterna får ansluta till SQL Server på TCP 1433.
- Windows Integrated Security rekommenderas. SQL-login kan användas om det hanteras säkert.
- BurntToast installerat på klienterna, helst från intern PowerShell-repository i produktion.
- Klientscriptet måste köras i användarens interaktiva session, inte som `SYSTEM`, för att toasten ska visas.

## Installation

1. Kör `sql/001-schema.sql` i den databas som ska användas.
2. Ge ett SQL-login eller Windows-grupp minsta nödvändiga rättigheter enligt kommentarerna i SQL-filen.
3. Kopiera `config/config.example.psd1` till `config/config.psd1` och fyll i server/databas.
   PSD1-filen måste innehålla statiska värden som stöds av `Import-PowerShellDataFile`; lämna `ClientName = $null` om klienten ska använda det lokala datornamnet automatiskt.
4. Registrera klienter och grupper med `src/Client/Start-ToastClient.ps1 -Register`.
5. Köa ett testmeddelande:

```powershell
.\src\Server\Send-ToastMessage.ps1 `
  -ConfigPath .\config\config.psd1 `
  -GroupName 'IT-TEST' `
  -Title 'Test' `
  -Body 'Detta är ett testmeddelande.'
```

6. Kör klienten i användarsessionen:

```powershell
.\src\Client\Start-ToastClient.ps1 -ConfigPath .\config\config.psd1 -Once
```

För kontinuerlig polling används `-PollSeconds 30`. Ett exempel på schemalagd aktivitet finns i `deploy/Register-ToastClientTask.ps1`.

## Säkerhet

- Lägg aldrig lösenord i repo eller konfigurationsfiler.
- Använd `Encrypt=True` och certifikatvalidering i produktion. `TrustServerCertificate=True` i exempelkonfigurationen är endast för labbmiljö.
- Begränsa brandväggen så att endast klientnät får nå SQL Server på TCP 1433.
- Använd separata least-privilege-konton för admin och klient.
- Använd parametriserade SQL-kommandon; ändra inte scriptet till strängkonkatenering.
- BurntToast från PSGallery bör ersättas av en internt signerad eller speglad paketkälla i produktion.

## Felsökning

```powershell
Test-NetConnection sql01.example.test -Port 1433
Get-Module -ListAvailable BurntToast
```

Om SQL-anslutningen fungerar men ingen toast syns: kontrollera att klientscriptet körs som den inloggade användaren och att BurntToast kan importeras i samma session.
