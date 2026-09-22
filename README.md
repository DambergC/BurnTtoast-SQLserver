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
- Windows Integrated Security rekommenderas. SQL-login kan användas om `SqlCredential` tillförs säkert vid körning eller som en statisk `@{ UserName='...'; Password='...' }`-hashtable utanför versionshantering.
- BurntToast installerat på klienterna, helst från intern PowerShell-repository i produktion.
- Klientscriptet måste köras i användarens interaktiva session, inte som `SYSTEM`, för att toasten ska visas.

## Installation

1. Kör `sql/001-schema.sql`, `sql/002-toast-design-repeat.sql`, `sql/003-toast-button.sql` och `sql/004-local-time-reporting.sql` i den databas som ska användas.
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

## Anpassa toastens utseende

Server-scriptet kan nu lagra valfri designmetadata i kön och klienten skickar bara vidare de BurntToast-argument som faktiskt stöds lokalt:

```powershell
.\src\Server\Send-ToastMessage.ps1 `
  -ConfigPath .\config\config.psd1 `
  -GroupName 'IT-TEST' `
  -Title 'Underhåll i kväll' `
  -Body 'VPN-tjänsten startas om 22:00.' `
  -AppLogoPath '\\fileserver\toast-assets\logo.png' `
  -HeroImagePath '\\fileserver\toast-assets\maintenance.jpg' `
  -Sound Reminder `
  -Urgent
```

- `AppLogoPath` och `HeroImagePath` måste vara sökvägar som **klientdatorn** kan läsa när toasten visas, till exempel en lokal fil eller UNC-sökväg. Server-lokala sökvägar fungerar bara om exakt samma sökväg finns och är åtkomlig på klienten.
- `Sound` valideras mot BurntToast-värdena `Default`, `IM`, `Mail`, `Reminder`, `SMS`, `Alarm`, `Alarm2`-`Alarm10` och `Call`, `Call2`-`Call10`.
- Repositoriet använder den dokumenterade BurntToast-parametern `-Urgent` för förhöjda/noterbara toastar. Om en installerad BurntToast-version saknar något optionalt argument visas toasten ändå med titel/brödtext och klienten loggar en tydlig varning.

## Upprepade meddelanden

Ett meddelande är fortfarande engångsvisning per klient när repeat-parametrar utelämnas. För upprepning anger du intervall och totalt antal visningar per klient:

```powershell
.\src\Server\Send-ToastMessage.ps1 `
  -ConfigPath .\config\config.psd1 `
  -GroupName 'IT-TEST' `
  -Title 'Standup om 10 minuter' `
  -Body 'Teams-rummet öppnas nu.' `
  -RepeatIntervalMinutes 5 `
  -RepeatCount 3 `
  -ExpiresUtc (Get-Date).AddMinutes(20)
```

Semantik för repeat:

- `RepeatCount` är **totalt** antal schemalagda toast-tillfällen per klient, inklusive första försöket. `RepeatCount 3` betyder alltså första tillfället + två senare tillfällen. Misslyckade repeat-försök förbrukar också ett tillfälle.
- Ange antingen `-RepeatIntervalSeconds` eller `-RepeatIntervalMinutes` tillsammans med `-RepeatCount`.
- Om nästa planerade visning skulle inträffa på eller efter `ExpiresUtc` stoppas återstående upprepningar för den klienten.
- Om en klient misslyckas med att visa en repeat-toast sparas felmeddelandet och klienten försöker igen vid nästa repeat-intervall så länge det finns återstående visningar och meddelandet inte har gått ut.
- Klienten leasar varje toast-occurrence innan den visas så att samtidiga poll-cykler inte visar samma occurrence mer än en gång. Om klienten kraschar efter visning men före kvittens kan samma occurrence visas igen när leasingen löper ut.

## Toast-knapp (valfri)

Server-scriptet stöder en valfri knapp per meddelande. Om knappdata utelämnas visas toasten precis som tidigare.

Öppna URL/protokoll:

```powershell
.\src\Server\Send-ToastMessage.ps1 `
  -ConfigPath .\config\config.psd1 `
  -GroupName 'IT-TEST' `
  -Title 'Läs driftinfo' `
  -Body 'Klicka för detaljer i ärendesystemet.' `
  -ButtonText 'Öppna' `
  -ButtonArguments 'https://status.example.se/ticket/12345' `
  -ButtonActivationType Protocol
```

Dismiss-knapp:

```powershell
.\src\Server\Send-ToastMessage.ps1 `
  -ConfigPath .\config\config.psd1 `
  -GroupName 'IT-TEST' `
  -Title 'Påminnelse' `
  -Body 'Bekräfta att du sett meddelandet.' `
  -ButtonText 'Stäng' `
  -ButtonActivationType Dismiss
```

- `ButtonActivationType` tillåter bara `Protocol` eller `Dismiss`.
- `ButtonText` krävs för att knappen ska skapas.
- `ButtonArguments` måste vara en absolut URI när `ButtonActivationType` är `Protocol`.

## Lokal tidsrapportering

Ny schemaläggning och procedurernas lease-/leveransstatus använder serverns lokala tid (`NextShowUtc`, `LeaseExpiresUtc`, `DeliveredUtc`, `LastAttemptUtc`, `LastSeenUtc`).
Obs: `Utc`-suffixen i kolumnnamnen är kvar av bakåtkompatibilitetsskäl och betyder inte längre att nya värden alltid är UTC.

`sql/004-local-time-reporting.sql` skapar:
- `dbo.vw_ToastMessageLocal`
- `dbo.vw_ToastDeliveryLocal`
- `dbo.ufn_ToastMessageLocal(@TimeZoneName)` (`@TimeZoneName` ignoreras för bakåtkompatibilitet)
- `dbo.ufn_ToastDeliveryLocal(@TimeZoneName)` (`@TimeZoneName` ignoreras för bakåtkompatibilitet)

Objekten behåller samma namn men gör inte längre någon tidszonskonvertering; `*Local*`-kolumnerna returnerar samma lokala tid som lagras i tabellerna.
För tydlighet finns även alias-kolumner med `*ServerLocalTime` i vyer/funktioner.
`sql/002-toast-design-repeat.sql` flyttar även befintliga schematider (`NextShowUtc`/`LeaseExpiresUtc`) från tidigare UTC-baserad lagring till serverns lokala tid vid uppgradering.
Vid uppgradering från äldre UTC-lagring: sätt `@ServerLocalTimeZone` högst upp i `sql/002-toast-design-repeat.sql` till serverns Windows-tidszon (t.ex. `W. Europe Standard Time`) före körning så att konverteringen använder rätt DST-regler.

Exempel på direktfråga:

```sql
SELECT CreatedUtc AS CreatedLocalTime
FROM dbo.ToastMessage;
```

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
