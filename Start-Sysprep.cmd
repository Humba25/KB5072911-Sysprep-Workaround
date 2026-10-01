@echo off
:: ------------------------------------------------------------------
:: Start-Sysprep.cmd
:: Doppelklick genuegt - startet sich selbst als Administrator und
:: ruft Prepare-Sysprep.ps1 aus demselben Ordner auf.
::
:: Optionen (aus einer Admin-CMD):
::   Start-Sysprep.cmd -DryRun              nur pruefen, nichts aendern
::   Start-Sysprep.cmd -NoSysprep           vorbereiten ohne Sysprep
::   Start-Sysprep.cmd -KeepLanguages en-US zusaetzliche Sprache behalten
:: ------------------------------------------------------------------

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Starte als Administrator neu ...
    if "%~1"=="" (
        powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    ) else (
        powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
    )
    exit /b
)

"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Prepare-Sysprep.ps1" %*
echo.
pause
