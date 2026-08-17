@echo off
setlocal
cd /d "%~dp0"
set "AUDIT_SCRIPT=%~dp0runner\run_nearopt_ro_audit.ps1"

echo ============================================================
echo  Energy manuscript near-optimal RO-capacity robustness audit
echo ============================================================
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "try { [void][scriptblock]::Create([IO.File]::ReadAllText($env:AUDIT_SCRIPT)); Write-Host '[OK] PowerShell runner syntax check passed.'; exit 0 } catch { Write-Host ('[ERROR] PowerShell runner syntax check failed: ' + $_.Exception.Message); exit 97 }"
if errorlevel 1 (
  echo.
  echo [STOP] The runner failed its syntax precheck. No scientific run was started.
  pause
  exit /b 97
)

echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%AUDIT_SCRIPT%"
set "RC=%ERRORLEVEL%"

echo.
if "%RC%"=="0" (
  echo [DONE] The audit finished. Upload the newest result ZIP from the results folder.
) else (
  echo [STOP] The audit did not complete cleanly.
  echo        If a result ZIP was created, upload the newest partial result ZIP.
)
echo.
pause
exit /b %RC%
