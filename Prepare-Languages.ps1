<#
    Prepare-Languages.ps1
    Sprachbereinigung vor Sysprep - unabhaengig von der installierten Sprache.

    Ablauf:
      1. Basissprache (Installationssprache) und aktuelle Anzeigesprache ermitteln
      2. Alle anderen Sprachen entfernen
      3. Alle Appx-Pakete entfernen, die nur pro Benutzer installiert sind
         (Sysprep-Blocker 0x80073cf2, z. B. per Store aktualisierte Language Experience Packs)
      4. Falls dabei das LXP der Zielsprache entfernt wurde: automatische
         Nachinstallation nach dem Deploy einrichten (geplanter Task, laeuft bis Internet da ist)

    Aufruf:
      .\Prepare-Languages.ps1 -DryRun                  # nur anzeigen, nichts aendern
      .\Prepare-Languages.ps1                          # ausfuehren
      .\Prepare-Languages.ps1 -KeepLanguages 'en-US'   # zusaetzliche Sprache behalten
#>
param(
    [string[]]$KeepLanguages = @(),
    [switch]$DryRun
)

function Write-Ok   ($m) { Write-Host "  [OK]    $m" -ForegroundColor Green }
function Write-Warn ($m) { Write-Host "  [WARN]  $m" -ForegroundColor Yellow }
function Write-Info ($m) { Write-Host "  [INFO]  $m" -ForegroundColor Cyan }

# ------------------------------------------------------------------
# 1. Sprachen ermitteln
# ------------------------------------------------------------------
Write-Host "`n=== Sprachen ermitteln ===" -ForegroundColor Cyan

# Installationssprache (Basis, laesst sich nicht deinstallieren)
$lcid     = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\Language').InstallLanguage
$baseLang = [Globalization.CultureInfo]::GetCultureInfo([Convert]::ToInt32($lcid, 16)).Name

# Aktuelle Anzeigesprache des Systems
$uiLang = $null
if (Get-Command Get-SystemPreferredUILanguage -ErrorAction SilentlyContinue) {
    $uiLang = Get-SystemPreferredUILanguage
}
if (-not $uiLang) { $uiLang = (Get-UICulture).Name }

$keep       = @($uiLang, $baseLang) + $KeepLanguages | Where-Object { $_ } | Select-Object -Unique
$targetLang = $uiLang

Write-Info "Basissprache:   $baseLang"
Write-Info "Anzeigesprache: $uiLang"
Write-Info "Behalten:       $($keep -join ', ')"

# ------------------------------------------------------------------
# 2. Nicht benoetigte Sprachen entfernen
# ------------------------------------------------------------------
Write-Host "`n=== Nicht benoetigte Sprachen entfernen ===" -ForegroundColor Cyan

if (Get-Command Get-InstalledLanguage -ErrorAction SilentlyContinue) {
    foreach ($l in Get-InstalledLanguage) {
        if ($keep -contains $l.LanguageId) { Write-Info "Behalte $($l.LanguageId)"; continue }
        if ($DryRun) { Write-Info "[DryRun] wuerde entfernen: $($l.LanguageId)"; continue }
        try {
            Uninstall-Language -Language $l.LanguageId -ErrorAction Stop | Out-Null
            Write-Ok "Entfernt: $($l.LanguageId)"
        } catch {
            Write-Warn "Konnte $($l.LanguageId) nicht entfernen: $($_.Exception.Message)"
        }
    }
} else {
    Write-Warn "LanguagePackManagement-Modul nicht vorhanden - Schritt uebersprungen"
}

# ------------------------------------------------------------------
# 3. Nur pro Benutzer installierte Appx-Pakete entfernen
# ------------------------------------------------------------------
Write-Host "`n=== Nicht bereitgestellte Appx-Pakete entfernen ===" -ForegroundColor Cyan

$provisioned = (Get-AppxProvisionedPackage -Online).DisplayName
$candidates  = Get-AppxPackage -AllUsers | Where-Object {
    -not $_.NonRemovable -and
    $_.SignatureKind -ne 'System' -and
    $provisioned -notcontains $_.Name
}

$reinstall = @()
foreach ($p in $candidates) {
    # Wird das LXP einer behaltenen Sprache entfernt -> spaeter nachinstallieren
    if ($p.Name -match '^Microsoft\.LanguageExperiencePack(.+)$' -and $keep -contains $Matches[1]) {
        $reinstall += $Matches[1]
    }

    if ($DryRun) { Write-Info "[DryRun] wuerde entfernen: $($p.PackageFullName)"; continue }

    try {
        Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction Stop
        Write-Ok "Entfernt: $($p.PackageFullName)"
    } catch {
        try {
            Remove-AppxPackage -Package $p.PackageFullName -ErrorAction Stop
            Write-Ok "Entfernt (aktueller Benutzer): $($p.PackageFullName)"
        } catch {
            Write-Warn "Konnte $($p.PackageFullName) nicht entfernen: $($_.Exception.Message)"
        }
    }
}
if (-not $candidates) { Write-Ok "Keine Pakete gefunden, die Sysprep blockieren" }

# ------------------------------------------------------------------
# 4. Nachinstallation der Anzeigesprache nach dem Deploy
# ------------------------------------------------------------------
$reinstall = $reinstall | Select-Object -Unique
if ($reinstall) {
    Write-Host "`n=== Sprach-Nachinstallation einrichten ===" -ForegroundColor Cyan

    $scriptDir   = 'C:\Windows\Setup\Scripts'
    $restorePath = Join-Path $scriptDir 'Restore-DisplayLanguage.ps1'
    $langList    = ($reinstall | ForEach-Object { "'$_'" }) -join ','

    $restore = @"
# Automatisch erzeugt von Prepare-Languages.ps1
# Installiert die Anzeigesprache nach dem Deploy nach. Ohne Internet: naechster Start.
`$ErrorActionPreference = 'Stop'
try {
    foreach (`$lang in @($langList)) {
        Install-Language -Language `$lang -CopyToSettings | Out-Null
    }
    Set-SystemPreferredUILanguage -Language '$targetLang'
    Unregister-ScheduledTask -TaskName 'Restore-DisplayLanguage' -Confirm:`$false
    Remove-Item -Path `$MyInvocation.MyCommand.Path -Force
} catch { }
"@

    if ($DryRun) {
        Write-Info "[DryRun] wuerde Nachinstallation fuer $($reinstall -join ', ') einrichten"
    } else {
        New-Item -Path $scriptDir -ItemType Directory -Force | Out-Null
        Set-Content -Path $restorePath -Value $restore -Encoding UTF8

        $action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
                        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$restorePath`""
        $trigger   = New-ScheduledTaskTrigger -AtStartup
        $trigger.Delay = 'PT3M'   # Netzwerk abwarten
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest

        Register-ScheduledTask -TaskName 'Restore-DisplayLanguage' -Action $action `
            -Trigger $trigger -Principal $principal -Force | Out-Null

        Write-Ok "Task 'Restore-DisplayLanguage' fuer $($reinstall -join ', ') eingerichtet"
    }
}

# ------------------------------------------------------------------
# Ergebnis fuer unattend.xml
# ------------------------------------------------------------------
Write-Host "`n=== Ergebnis ===" -ForegroundColor Cyan
Write-Info "Sprache fuer unattend.xml (UILanguage / UserLocale / InputLocale): $targetLang"
$global:TargetUILanguage = $targetLang
