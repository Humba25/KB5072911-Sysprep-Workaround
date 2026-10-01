<#
    Prepare-Sysprep.ps1
    Bereitet das Referenzgeraet fuer den FOG-Capture vor und startet Sysprep.
    Start ueber Start-Sysprep.cmd (startet automatisch als Administrator).

    Ablauf:
      1. Grundpruefungen (ausstehender Neustart, BitLocker, Netzwerk)
      2. Windows Update stoppen, reservierten Speicher deaktivieren
      3. Ruhezustand / Schnellstart aus
      4. Sprachen bereinigen + Appx-Pakete entfernen, die Sysprep blockieren
      5. XAML-Workaround fuer KB5072911 per Active Setup (Black Screen Fix)
      6. unattend.xml erzeugen (Sprache + Zeitzone automatisch)
      7. Sysprep /generalize /oobe /shutdown starten und Ergebnis auswerten

    Parameter:
      -DryRun          nur pruefen und anzeigen, nichts aendern, kein Sysprep
      -NoSysprep       alles vorbereiten, Sysprep aber nicht starten
      -KeepLanguages   zusaetzliche Sprachen behalten, z. B. 'en-US'
#>
param(
    [string[]]$KeepLanguages = @(),
    [switch]$DryRun,
    [switch]$NoSysprep
)

$ScriptDir = $PSScriptRoot
$SetupDir  = 'C:\Windows\Setup\Scripts'
$LogDir    = Join-Path $SetupDir 'Logs'
$Unattend  = 'C:\Windows\Setup\unattend.xml'
$ErrLog    = 'C:\Windows\System32\Sysprep\Panther\setuperr.log'

New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
$LogFile = Join-Path $LogDir ("Prepare-Sysprep_{0:yyyy-MM-dd_HH-mm-ss}.log" -f (Get-Date))
Start-Transcript -Path $LogFile | Out-Null

function Write-Step ($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Write-Ok   ($m) { Write-Host "  [OK]    $m" -ForegroundColor Green }
function Write-Warn ($m) { Write-Host "  [WARN]  $m" -ForegroundColor Yellow }
function Write-Info ($m) { Write-Host "  [INFO]  $m" -ForegroundColor Cyan }
function Write-Err  ($m) { Write-Host "  [FEHLER] $m" -ForegroundColor Red }
function Stop-Script ($m) {
    Write-Err $m
    Stop-Transcript | Out-Null
    exit 1
}
# j/n-Abfrage, ein Tastendruck reicht (ohne Enter)
function Confirm-Continue ($q) {
    Write-Host "  $q (j/n): " -NoNewline
    while ($true) {
        try   { $c = [string]$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown').Character }
        catch { $c = [string](Read-Host) }
        if ($c -match '^\s*[jJyY]') { Write-Host 'j'; return $true }
        if ($c -match '^\s*[nN]')   { Write-Host 'n'; return $false }
    }
}

# ------------------------------------------------------------------
# 0. Adminrechte
# ------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Stop-Script "Bitte als Administrator starten (Start-Sysprep.cmd verwenden)." }
if ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18') {
    Stop-Script "Skript laeuft als SYSTEM. Sysprep als SYSTEM wird nicht unterstuetzt (fuehrt zum XAML Black Screen). Als angemeldeter Admin starten."
}
if ($DryRun) { Write-Warn "DRYRUN - es wird nichts veraendert und kein Sysprep gestartet" }

# ------------------------------------------------------------------
# 1. Grundpruefungen
# ------------------------------------------------------------------
Write-Step "1. Grundpruefungen"

$rebootPending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
                 (Test-Path 'C:\Windows\WinSxS\pending.xml')
if ($rebootPending) {
    Stop-Script "Ein Neustart steht aus (Updates). Erst neu starten, dann Skript erneut ausfuehren."
}
Write-Ok "Kein ausstehender Neustart"

# Reste eines abgebrochenen Sysprep-Laufs
$genState   = (Get-ItemProperty 'HKLM:\SYSTEM\Setup\Status\SysprepStatus' -ErrorAction SilentlyContinue).GeneralizationState
$imageState = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' -ErrorAction SilentlyContinue).ImageState
if ($null -ne $genState -and $genState -ne 7) {
    Stop-Script "GeneralizationState ist $genState statt 7. Ein frueherer Sysprep-Lauf wurde abgebrochen. Backup des Referenz-Image zurueckspielen."
}
if ($imageState -and $imageState -ne 'IMAGE_STATE_COMPLETE') {
    Stop-Script "ImageState ist '$imageState' statt IMAGE_STATE_COMPLETE. System ist nicht im Ausgangszustand."
}
Write-Ok "Sysprep-Status sauber (GeneralizationState 7, IMAGE_STATE_COMPLETE)"

try {
    $bl = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop
    if ($bl.VolumeStatus -ne 'FullyDecrypted') {
        Stop-Script "BitLocker auf C: ist aktiv ($($bl.VolumeStatus)). Erst 'manage-bde -off C:' ausfuehren und Entschluesselung abwarten."
    }
    Write-Ok "BitLocker ist aus"
} catch {
    Write-Warn "BitLocker-Status nicht lesbar - bitte manuell mit 'manage-bde -status' pruefen"
}

$up = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up'
if ($up) {
    Write-Warn "Aktive Netzwerkverbindung: $($up.Name -join ', ')"
    Write-Warn "Windows Update / Store koennen waehrend der Vorbereitung Pakete nachladen und Sysprep blockieren."
    if (-not $DryRun) {
        if (-not (Confirm-Continue "Bitte WLAN/Kabel jetzt trennen. Fortfahren?")) { Stop-Script "Abgebrochen." }
        $up = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up'
        if ($up) { Write-Warn "Netzwerk ist weiterhin aktiv - weiter auf eigenes Risiko" } else { Write-Ok "Netzwerk getrennt" }
    }
} else {
    Write-Ok "Kein aktives Netzwerk"
}

# ------------------------------------------------------------------
# 2. Windows Update stoppen + reservierter Speicher
# ------------------------------------------------------------------
Write-Step "2. Windows Update / Reservierter Speicher"

foreach ($svc in 'wuauserv', 'UsoSvc', 'BITS') {
    if ($DryRun) { Write-Info "[DryRun] wuerde Dienst stoppen: $svc"; continue }
    Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
    Write-Ok "Dienst gestoppt: $svc"
}

$rmKey  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager'
$rsFlag = Join-Path $SetupDir 'ReservedStorageFix.flag'
$state  = (& dism.exe /Online /Get-ReservedStorageState) -join "`n"

if ($state -match 'deaktiviert|disabled') {
    Write-Ok "Reservierter Speicher ist deaktiviert"
} elseif ($DryRun) {
    Write-Warn "[DryRun] Reservierter Speicher ist aktiv - wuerde deaktiviert werden"
} else {
    Write-Warn "Reservierter Speicher ist aktiv - wird deaktiviert"
    & dism.exe /Online /Set-ReservedStorageState /State:Disabled | Out-Null
    $state = (& dism.exe /Online /Get-ReservedStorageState) -join "`n"

    if ($state -match 'deaktiviert|disabled') {
        Write-Ok "Reservierter Speicher deaktiviert"
    } elseif (Test-Path $rsFlag) {
        # Reparatur wurde schon eingetragen und neu gestartet, trotzdem wieder belegt
        Remove-Item $rsFlag -Force
        $scen = (Get-ItemProperty $rmKey -ErrorAction SilentlyContinue).ActiveScenario
        Stop-Script ("Reservierter Speicher ist nach dem Neustart wieder belegt (ActiveScenario = $scen). " +
                     "Windows Update hat beim Start erneut etwas angefasst. Update-Verlauf pruefen, ausstehende " +
                     "Updates mit Netzwerk komplett installieren, neu starten und Skript erneut ausfuehren.")
    } else {
        # Speicher ist durch ein haengendes Update-Szenario belegt
        Set-ItemProperty -Path $rmKey -Name ActiveScenario      -Value 0 -Type DWord
        Set-ItemProperty -Path $rmKey -Name ShippedWithReserves -Value 0 -Type DWord
        Set-Content -Path $rsFlag -Value (Get-Date -Format 'yyyy-MM-dd HH:mm') -Encoding ASCII
        Write-Warn "Reservierter Speicher war belegt - ActiveScenario zurueckgesetzt"
        Stop-Script "Bitte jetzt NEU STARTEN (ohne Netzwerk) und Start-Sysprep.cmd danach erneut ausfuehren."
    }
}
if (-not $DryRun -and ($state -match 'deaktiviert|disabled') -and (Test-Path $rsFlag)) { Remove-Item $rsFlag -Force }

# ------------------------------------------------------------------
# 3. Ruhezustand / Schnellstart
# ------------------------------------------------------------------
Write-Step "3. Ruhezustand / Schnellstart"
if ($DryRun) {
    Write-Info "[DryRun] wuerde 'powercfg /h off' ausfuehren"
} else {
    & powercfg.exe /h off
    Write-Ok "Ruhezustand und Schnellstart deaktiviert (sonst scheitert der FOG-Capture an NTFS)"
}

# ------------------------------------------------------------------
# 4. Sprachen + Appx-Pakete
# ------------------------------------------------------------------
Write-Step "4. Sprachen und Appx-Pakete"
$langScript = Join-Path $ScriptDir 'Prepare-Languages.ps1'
if (-not (Test-Path $langScript)) { Stop-Script "Prepare-Languages.ps1 nicht gefunden in $ScriptDir" }

. $langScript -KeepLanguages $KeepLanguages -DryRun:$DryRun
$Lang = $global:TargetUILanguage
if (-not $Lang) { Stop-Script "Zielsprache konnte nicht ermittelt werden." }

# ------------------------------------------------------------------
# 5. XAML-Workaround (KB5072911)
#    Seit den Updates ab Juli 2025 registrieren sich unter 24H2/25H2 drei
#    XAML-Pakete nicht rechtzeitig -> schwarzer Bildschirm nach der Anmeldung.
#    Active Setup registriert sie beim ersten Logon jedes Benutzers, bevor der
#    Explorer startet. Das temporaere OOBE-Konto defaultuser0 wird uebersprungen.
#    Entfernen, sobald Microsoft KB5072911 offiziell behebt:
#      reg delete "HKLM\SOFTWARE\Microsoft\Active Setup\Installed Components\{A1B2C3D4-E5F6-47A8-9B0C-1D2E3F4A5B6C}" /f
# ------------------------------------------------------------------
Write-Step "5. XAML-Workaround (KB5072911)"

$XamlScriptPath  = Join-Path $SetupDir 'RegisterXamlPackages.cmd'
$ActiveSetupGuid = '{A1B2C3D4-E5F6-47A8-9B0C-1D2E3F4A5B6C}'
$ActiveSetupKey  = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\$ActiveSetupGuid"
$manifests = @(
    'C:\Windows\SystemApps\MicrosoftWindows.Client.CBS_cw5n1h2txyewy\appxmanifest.xml',
    'C:\Windows\SystemApps\Microsoft.UI.Xaml.CBS_8wekyb3d8bbwe\appxmanifest.xml',
    'C:\Windows\SystemApps\MicrosoftWindows.Client.Core_cw5n1h2txyewy\appxmanifest.xml'
)
foreach ($m in $manifests) {
    if (-not (Test-Path $m)) { Write-Warn "Manifest fehlt: $m" }
}

if ($DryRun) {
    Write-Info "[DryRun] wuerde $XamlScriptPath schreiben und Active Setup $ActiveSetupGuid eintragen"
} else {
    $lines = @('@echo off',
               'REM KB5072911 Workaround: XAML-Pakete pro Benutzer registrieren',
               'REM Nicht unter dem temporaeren OOBE-Konto ausfuehren',
               'if /i "%USERNAME%"=="defaultuser0" exit /b 0')
    foreach ($m in $manifests) {
        $lines += "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command ""Add-AppxPackage -Register -Path '$m' -DisableDevelopmentMode"""
    }
    $lines += 'exit /b 0'
    Set-Content -Path $XamlScriptPath -Value $lines -Encoding ASCII -Force
    Write-Ok "Skript geschrieben: $XamlScriptPath"

    # Vorhandene Version beibehalten, damit bereits versorgte Benutzer nicht erneut laufen
    $version = 1
    if (Test-Path $ActiveSetupKey) {
        $old = (Get-ItemProperty $ActiveSetupKey -ErrorAction SilentlyContinue).Version
        if ($old -match '^\d+$') { $version = [int]$old }
    }
    New-Item -Path $ActiveSetupKey -Force | Out-Null
    Set-ItemProperty -Path $ActiveSetupKey -Name '(default)'   -Value 'Register XAML packages (KB5072911 Workaround)'
    New-ItemProperty -Path $ActiveSetupKey -Name 'StubPath'    -PropertyType String -Value "cmd.exe /c `"$XamlScriptPath`"" -Force | Out-Null
    New-ItemProperty -Path $ActiveSetupKey -Name 'Version'     -PropertyType String -Value "$version" -Force | Out-Null
    New-ItemProperty -Path $ActiveSetupKey -Name 'IsInstalled' -PropertyType DWord  -Value 1 -Force | Out-Null
    Write-Ok "Active Setup eingetragen ($ActiveSetupGuid, Version $version)"
}

# ------------------------------------------------------------------
# 6. unattend.xml erzeugen
# ------------------------------------------------------------------
Write-Step "6. unattend.xml erzeugen"
$TimeZone = (Get-TimeZone).Id

$xml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="generalize">
    <component name="Microsoft-Windows-PnpSysprep" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <PersistAllDeviceInstalls>true</PersistAllDeviceInstalls>
    </component>
    <component name="Microsoft-Windows-Security-SPP" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <SkipRearm>1</SkipRearm>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>$Lang</InputLocale>
      <SystemLocale>$Lang</SystemLocale>
      <UILanguage>$Lang</UILanguage>
      <UserLocale>$Lang</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <TimeZone>$TimeZone</TimeZone>
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
      </OOBE>
    </component>
  </settings>
</unattend>
"@

try { [void][xml]$xml } catch { Stop-Script "Erzeugte unattend.xml ist ungueltig: $($_.Exception.Message)" }

if ($DryRun) {
    Write-Info "[DryRun] wuerde $Unattend schreiben (Sprache $Lang, Zeitzone $TimeZone)"
} else {
    Set-Content -Path $Unattend -Value $xml -Encoding UTF8
    Write-Ok "unattend.xml geschrieben: $Unattend"
    Write-Info "Sprache: $Lang | Zeitzone: $TimeZone | Treiber erhalten | SkipRearm | OOBE interaktiv"
}

# ------------------------------------------------------------------
# 7. Sysprep
# ------------------------------------------------------------------
Write-Step "7. Sysprep"

if ($DryRun -or $NoSysprep) {
    Write-Ok "Vorbereitung abgeschlossen - Sysprep wird nicht gestartet ($(if ($DryRun) {'DryRun'} else {'NoSysprep'}))"
    Stop-Transcript | Out-Null
    exit 0
}

Write-Host ""
Write-Host "  Sysprep wird mit /generalize /oobe /shutdown gestartet." -ForegroundColor Yellow
Write-Host "  Danach faehrt der Laptop herunter. NICHT normal einschalten," -ForegroundColor Yellow
Write-Host "  sondern direkt per PXE (F12) in den FOG Capture Task booten." -ForegroundColor Yellow
Write-Host ""
if (-not (Confirm-Continue "Sysprep jetzt starten?")) { Stop-Script "Abgebrochen." }

Get-Process -Name sysprep -ErrorAction SilentlyContinue | Stop-Process -Force
$linesBefore = if (Test-Path $ErrLog) { (Get-Content $ErrLog).Count } else { 0 }

Write-Info "Log dieses Laufs: $LogFile"
Stop-Transcript | Out-Null

Start-Process -FilePath "$env:WINDIR\System32\Sysprep\sysprep.exe" `
    -ArgumentList "/generalize /oobe /shutdown /unattend:$Unattend" -Wait

# Bei Erfolg faehrt der Rechner jetzt herunter. Neue Fehler = Sysprep ist gescheitert.
$newErrors = if (Test-Path $ErrLog) { Get-Content $ErrLog | Select-Object -Skip $linesBefore } else { @() }
if ($newErrors) {
    Write-Host ""
    Write-Err "Sysprep ist fehlgeschlagen. Neue Eintraege in setuperr.log:"
    $newErrors | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
    Write-Host ""
    Write-Info "Haeufige Ursachen:"
    Write-Info " - 'reserved storage is in use'  -> neu starten (ohne Netzwerk) und Skript erneut ausfuehren"
    Write-Info " - 'was installed for a user'    -> Skript erneut ausfuehren (entfernt das Paket)"
    exit 1
} else {
    Write-Ok "Sysprep erfolgreich - der Rechner faehrt herunter."
}
