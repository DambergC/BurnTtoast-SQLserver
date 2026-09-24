# BurntToast-SQLserver

Gruppbaserade Windows-notiser med PowerShell och Microsoft SQL Server. Projektet kan nu visa meddelanden via tre visningslägen:

- `BurntToast` – native Windows-toast (standard)
- `Wpf` – egen kvittensruta
- `AppDeployToolkit` – PSAppDeployToolkit/PSADT-prompt i användarens interaktiva session

## Quick start

Detta är den rekommenderade snabbstarten för både nya installationer och uppgraderingar.

1. Kör det konsoliderade SQL-skriptet i databasen som ska användas:

```sql
:r sql/Install-BurntToast-SQLserver.sql
```

2. Kopiera konfigurationen:

```powershell
Copy-Item .\config\config.example.psd1 .\config\config.psd1
```

3. Fyll i `config/config.psd1` med SQL Server, databas och klientgrupper.

4. Registrera klienten:

```powershell
.\src\Client\Start-ToastClient.ps1 -ConfigPath .\config\config.psd1 -Register
```

5. Köa ett testmeddelande:

```powershell
.\src\Server\Send-ToastMessage.ps1 `
  -ConfigPath .\config\config.psd1 `
  -GroupName 'IT-TEST' `
  -Title 'Testmeddelande' `
  -Body 'Detta är ett test.'
```

6. Kör klienten i den inloggade användarens session:

```powershell
.\src\Client\Start-ToastClient.ps1 -ConfigPath .\config\config.psd1 -Once
```

7. För kontinuerlig polling används:

```powershell
.\src\Client\Start-ToastClient.ps1 -ConfigPath .\config\config.psd1 -PollSeconds 30
```

`deploy/Register-ToastClientTask.ps1` registrerar ett logon-task som startar PowerShell med `-STA`, vilket krävs för `Wpf` och rekommenderas för `AppDeployToolkit`.

## SQL-skript

### Rekommenderat

- `sql/Install-BurntToast-SQLserver.sql`
  - skapar saknade bastabeller/index
  - applicerar repeat-/lease-logik
  - applicerar knapp-/display-mode-stöd
  - applicerar lokal tidsrapportering
  - är avsett att fungera både för nya installationer och uppgraderingar

### Legacy / avancerad migrering

De individuella skripten finns kvar för bakåtkompatibilitet och kontrollerade stegvisa uppgraderingar:

- `sql/001-schema.sql`
- `sql/002-toast-design-repeat.sql`
- `sql/003-toast-button.sql`
- `sql/004-local-time-reporting.sql`

Om en befintlig installation redan använder den äldre ordningen kan du fortsatt köra skripten separat i samma ordning som ovan.

## Arkitektur

- Administratören köar ett meddelande till en grupp i SQL Server.
- Klienterna pollar SQL Server över TCP 1433.
- Klientscriptet körs i användarens interaktiva session och visar meddelandet lokalt.
- Leveransstatus sparas i SQL Server.

SQL Server används alltså som kö- och statuslager, inte som presentationskanal.

## Förutsättningar

### Server / administrationssida

- Windows PowerShell 5.1 eller PowerShell 7
- SQL Server
- rättigheter att köra SQL-installationsskript och att köa meddelanden
- nätverksåtkomst till SQL Server

### Klientsida

- Windows PowerShell 5.1 eller PowerShell 7
- interaktiv användarsession (inte Session 0 / `SYSTEM`)
- nätverksåtkomst till SQL Server på TCP 1433
- `BurntToast` installerat eller tillgängligt från intern PowerShell-källa **om** klienten ska visa `DisplayMode BurntToast`
- lokalt paketerad och versionslåst `PSAppDeployToolkit`/`AppDeployToolkit` **om** klienten ska visa `DisplayMode AppDeployToolkit`
- `-STA` vid körning för `Wpf`, och rekommenderat även för `AppDeployToolkit`

## Installation

1. Kör `sql/Install-BurntToast-SQLserver.sql`.
2. Ge ett SQL-login eller en Windows-grupp minsta nödvändiga rättigheter.
3. Kopiera `config/config.example.psd1` till `config/config.psd1`.
4. Registrera klienter/grupper med `src/Client/Start-ToastClient.ps1 -Register`.
5. Kör klienten i användarsessionen, manuellt eller via schemalagd uppgift.

## Konfiguration

`config/config.psd1` läses med `Import-PowerShellDataFile`, så filen måste innehålla statiska värden. `ClientName = $null` stöds och betyder att klienten använder lokalt datornamn automatiskt.

Exempel:

```powershell
@{
    SqlServer = 'SQLSERVER.example.test'
    SqlDatabase = 'ToastNotifications'
    SqlPort = 1433
    UseIntegratedSecurity = $true
    SqlCredential = $null
    ClientName = $null
    ClientGroups = @('IT-TEST')
    InternalPowerShellRepository = $null
    AppDeployToolkitModulePath = $null
    Encrypt = $true
    TrustServerCertificate = $false
    ConnectTimeoutSeconds = 15
    CommandTimeoutSeconds = 15
}
```

Viktiga inställningar:

- `InternalPowerShellRepository`
  - valfri intern PowerShell-källa som bara används när klienten faktiskt behöver ladda `BurntToast`
  - gör att `BurntToast` inte längre måste installeras vid klientstart om inga BurntToast-meddelanden visas
- `AppDeployToolkitModulePath`
  - lokal sökväg till en versionslåst PSAppDeployToolkit/AppDeployToolkit-paketering
  - kan peka på manifestfil, bootstrapscript eller en katalog som innehåller exempelvis `PSAppDeployToolkit.psd1` eller `AppDeployToolkitMain.ps1`
  - används bara när klienten faktiskt behöver visa `DisplayMode AppDeployToolkit`

## Projektöversikt

- `src/Server/Send-ToastMessage.ps1` – köar meddelanden till SQL Server
- `src/Client/Start-ToastClient.ps1` – pollar SQL Server och visar meddelanden
- `src/Module/ToastSql.psm1` – SQL-stöd, validering, rendering och display-mode-logik
- `deploy/Register-ToastClientTask.ps1` – registrerar schemalagd klientstart med `-STA`
- `sql/Install-BurntToast-SQLserver.sql` – konsoliderat SQL-installations-/uppgraderingsskript

## `src/Server/Send-ToastMessage.ps1`

Syntax:

```powershell
.\src\Server\Send-ToastMessage.ps1 `
  -ConfigPath <string> `
  -GroupName <string> `
  -Title <string> `
  -Body <string> `
  [-ExpiresUtc <datetime>] `
  [-AppLogoPath <string>] `
  [-HeroImagePath <string>] `
  [-AppLogoFilePath <string>] `
  [-HeroImageFilePath <string>] `
  [-AppLogoBytes <byte[]>] `
  [-HeroImageBytes <byte[]>] `
  [-AppLogoContentType <string>] `
  [-HeroImageContentType <string>] `
  [-Sound <string>] `
  [-Urgent] `
  [-RepeatIntervalSeconds <int>] `
  [-RepeatIntervalMinutes <int>] `
  [-RepeatCount <int>] `
  [-ButtonText <string>] `
  [-ButtonArguments <string>] `
  [-ButtonActivationType <string>] `
  [-Scenario <string>] `
  [-DisplayMode <string>]
```

`-DisplayMode` stöder nu:

- `BurntToast`
- `Wpf`
- `AppDeployToolkit`

## `src/Client/Start-ToastClient.ps1`

Syntax:

```powershell
.\src\Client\Start-ToastClient.ps1 -ConfigPath <string> [-Register] [-Once] [-PollSeconds <int>]
```

Klienten laddar nu beroenden **lazy** per visningsläge:

- `BurntToast` laddas bara när ett `BurntToast`-meddelande ska visas.
- `AppDeployToolkit` laddas bara när ett `AppDeployToolkit`-meddelande ska visas.
- `Wpf` kräver inga externa PowerShell-moduler.

Det gör att AppDeployToolkit-only-klienter inte behöver `BurntToast` installerat för att fungera.

## `deploy/Register-ToastClientTask.ps1`

Exempel:

```powershell
.\deploy\Register-ToastClientTask.ps1 `
  -TaskName 'BurntToast SQL Client' `
  -ScriptPath 'C:\ToastSql\Client\Start-ToastClient.ps1' `
  -ConfigPath 'C:\ToastSql\Client\config.psd1'
```

Tasket startar `powershell.exe` med `-STA`.

## Anpassa toastens innehåll

Exempel med designmetadata:

```powershell
.\src\Server\Send-ToastMessage.ps1 `
  -ConfigPath .\config\config.psd1 `
  -GroupName 'IT-TEST' `
  -Title 'Underhåll i kväll' `
  -Body 'VPN-tjänsten startas om 22:00.' `
  -AppLogoPath '\\fileserver\toast-assets\logo.png' `
  -HeroImagePath '\\fileserver\toast-assets\maintenance.jpg' `
  -Scenario Reminder `
  -Sound Reminder `
  -Urgent
```

Notera:

- `AppLogoPath` och `HeroImagePath` kräver att **klientdatorn** kan läsa sökvägen.
- `AppLogoFilePath` och `HeroImageFilePath` läser bilden på servern och lagrar bytes i SQL Server.
- `AppLogoBytes`/`HeroImageBytes` stöds också direkt.
- Stödda content types för binära bilder är `image/png`, `image/jpeg`, `image/gif` och `image/bmp`.
- Maximal binär bildstorlek är 5 MB per bild.

## Visningslägen

### `BurntToast` (standard)

Native Windows-toast med Notification Center-stöd, ljud, scenarier, bilder, `Urgent` och inbyggda BurntToast-knappar.

```powershell
.\src\Server\Send-ToastMessage.ps1 `
  -ConfigPath .\config\config.psd1 `
  -GroupName 'IT-TEST' `
  -Title 'Påminnelse' `
  -Body 'Detta visas som vanlig Windows-toast.' `
  -DisplayMode BurntToast `
  -Scenario Reminder `
  -ButtonText 'Stäng' `
  -ButtonActivationType Dismiss
```

### `Wpf`

Egen topmost-kvittensruta i användarens session. Ingen Notification Center-integration. Fönstret kan ligga kvar tills användaren bekräftar.

```powershell
.\src\Server\Send-ToastMessage.ps1 `
  -ConfigPath .\config\config.psd1 `
  -GroupName 'IT-TEST' `
  -Title 'Bekräftelse krävs' `
  -Body 'Detta meddelande ligger kvar tills användaren bekräftar det.' `
  -DisplayMode Wpf `
  -ButtonText 'Öppna ärende' `
  -ButtonArguments 'https://status.example.se/ticket/12345' `
  -ButtonActivationType Protocol
```

### `AppDeployToolkit`

Visar en PSAppDeployToolkit-prompt i användarens interaktiva session. Detta är ett bra alternativ när man vill ha en standardiserad dialog istället för en native Windows-toast.

```powershell
.\src\Server\Send-ToastMessage.ps1 `
  -ConfigPath .\config\config.psd1 `
  -GroupName 'IT-TEST' `
  -Title 'Bekräftelse krävs' `
  -Body 'Läs informationen och bekräfta i dialogen.' `
  -DisplayMode AppDeployToolkit
```

Exempel med säker protokollknapp:

```powershell
.\src\Server\Send-ToastMessage.ps1 `
  -ConfigPath .\config\config.psd1 `
  -GroupName 'IT-TEST' `
  -Title 'Ny rutin publicerad' `
  -Body 'Öppna dokumentationen eller bekräfta direkt i prompten.' `
  -DisplayMode AppDeployToolkit `
  -ButtonText 'Öppna dokumentation' `
  -ButtonArguments 'https://intra.example.test/rutiner/toastsql' `
  -ButtonActivationType Protocol
```

Exempel med frivillig dismiss-knapp:

```powershell
.\src\Server\Send-ToastMessage.ps1 `
  -ConfigPath .\config\config.psd1 `
  -GroupName 'IT-TEST' `
  -Title 'Information' `
  -Body 'Du kan stänga prompten via extraknappen eller bekräfta normalt.' `
  -DisplayMode AppDeployToolkit `
  -ButtonText 'Stäng prompt' `
  -ButtonActivationType Dismiss
```

## Skillnader och begränsningar per visningsläge

| Funktion | BurntToast | Wpf | AppDeployToolkit |
|---|---|---|---|
| Windows Notification Center | Ja | Nej | Nej |
| Native Windows-toast | Ja | Nej | Nej |
| Kräver extern modul | BurntToast | Nej | PSAppDeployToolkit/AppDeployToolkit |
| Kräver interaktiv användarsession | Ja | Ja | Ja |
| Kräver `-STA` | Rekommenderat | Ja | Rekommenderat/krävs i praktiken |
| Hero image per meddelande | Ja | Ja | Nej |
| Native toast-scenarier | Ja | Nej | Nej |
| Ljud/Sound | Ja | Nej | Nej |
| `Urgent` | Ja | Nej | Nej |
| Knapp som öppnar säker URI | Ja | Ja (`http`,`https`,`mailto`) | Ja (`http`,`https`,`mailto`) |
| Dismiss-knapp | Ja | Ja | Ja |

AppDeployToolkit-begränsningar som **inte** emuleras tyst:

- ingen Windows Notification Center-integrering
- inga BurntToast-scenarier (`Reminder`, `Alarm`, `IncomingCall` används inte som native-scenarier)
- inget per-meddelande-ljud via `Sound`
- ingen per-meddelande-hero image rendering
- ingen `Urgent`-mappning

Praktiskt betyder det att `Title`, `Body`, kvittens och valfri säker protokoll-/dismiss-knapp stöds i `AppDeployToolkit`, medan mer avancerad BurntToast-specifik toast-funktionalitet kräver `DisplayMode BurntToast`.

## Knapphantering

`ButtonActivationType` stöder fortsatt:

- `Protocol`
- `Dismiss`

För `AppDeployToolkit` och `Wpf` används en säker URI-policy för protokollknappar:

- tillåtet: `http`, `https`, `mailto`
- blockerat: t.ex. `file`, `ftp`, egna otestade scheman och andra osäkra mål

`BurntToast` behåller befintligt beteende och server-/SQL-validering för absoluta URI:er.

## Upprepade meddelanden

Ett meddelande är fortfarande engångsvisning per klient när repeat-parametrar utelämnas.

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

## Lokal tidsrapportering

`sql/004-local-time-reporting.sql` och det konsoliderade skriptet skapar:

- `dbo.vw_ToastMessageLocal`
- `dbo.vw_ToastDeliveryLocal`
- `dbo.ufn_ToastMessageLocal(@TimeZoneName, @ServerTimeZoneName)`
- `dbo.ufn_ToastDeliveryLocal(@TimeZoneName, @ServerTimeZoneName)`

`sql/002-toast-design-repeat.sql` migrerar även äldre UTC-lagrade rader till serverns lokala tid vid uppgradering när det behövs.

## Rekommenderade paketlayouter

### Serverpaket

Exempel:

```text
C:\ToastSql\Server\
├── config\config.psd1
├── sql\Install-BurntToast-SQLserver.sql
├── src\Module\ToastSql.psm1
└── src\Server\Send-ToastMessage.ps1
```

### Klientpaket – BurntToast + Wpf

```text
C:\ToastSql\Client\
├── config\config.psd1
├── deploy\Register-ToastClientTask.ps1
├── src\Client\Start-ToastClient.ps1
└── src\Module\ToastSql.psm1
```

`BurntToast` installeras då antingen i förväg eller via `InternalPowerShellRepository` när klienten faktiskt behöver visa ett BurntToast-meddelande.

### Klientpaket – AppDeployToolkit

```text
C:\ToastSql\Client\
├── config\config.psd1
├── deploy\Register-ToastClientTask.ps1
├── src\Client\Start-ToastClient.ps1
├── src\Module\ToastSql.psm1
└── dependencies\PSAppDeployToolkit\4.1.7\
    ├── PSAppDeployToolkit.psd1
    └── ...övriga toolkitfiler...
```

Exempelkonfiguration:

```powershell
AppDeployToolkitModulePath = 'C:\ToastSql\Client\dependencies\PSAppDeployToolkit\4.1.7'
```

Du kan även peka direkt på manifestfilen:

```powershell
AppDeployToolkitModulePath = 'C:\ToastSql\Client\dependencies\PSAppDeployToolkit\4.1.7\PSAppDeployToolkit.psd1'
```

## Versionslåsning, paketering och compliance

- Paketera PSAppDeployToolkit lokalt tillsammans med klientdistributionen eller leverera det via intern, kontrollerad programvarudistribution.
- Peka `AppDeployToolkitModulePath` till en **versionslåst** kopia.
- Ladda inte ned PSAppDeployToolkit dynamiskt vid användarens logon.
- Commita inte tredjepartsbinärer i detta repository om ni inte redan har en etablerad intern process för det.
- Följ PSAppDeployToolkits egen licens och era interna compliance-/godkännandeprocesser innan ni distribuerar paketet vidare.

## Säkerhet

- Lägg aldrig lösenord i repo eller konfigurationsfiler.
- Använd `Encrypt=True` och korrekt certifikatvalidering i produktion.
- Begränsa brandväggen så att bara klientnät får nå SQL Server.
- Använd least-privilege-konton.
- Behåll parametriserade SQL-anrop.
- Planera för databasstorlek om binära bilder används ofta.

## Felsökning

```powershell
Test-NetConnection sql01.example.test -Port 1433
Get-Module -ListAvailable BurntToast
Get-ChildItem 'C:\ToastSql\Client\dependencies\PSAppDeployToolkit' -Recurse
```

Om SQL-anslutningen fungerar men ingen notis syns:

- kontrollera att klientscriptet körs som den inloggade användaren
- kontrollera att schemalagd uppgift eller manuell start använder `-STA`
- kontrollera att `BurntToast` kan laddas när `DisplayMode BurntToast` används
- kontrollera att `AppDeployToolkitModulePath` pekar på en fungerande lokal PSAppDeployToolkit-paketering när `DisplayMode AppDeployToolkit` används
