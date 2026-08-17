@echo off
setlocal
cd /d "%~dp0"
set "HS_SCRIPT=%~dp0runner\run_hard_service_check.ps1"

echo ============================================================
echo  Energy manuscript hard-service feasibility check
echo ============================================================
echo.

rem Parse the full PowerShell runner before executing any scientific step.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "try { [void][scriptblock]::Create([IO.File]::ReadAllText($env:HS_SCRIPT)); Write-Host '[OK] PowerShell runner syntax check passed.'; exit 0 } catch { Write-Host ('[ERROR] PowerShell runner syntax check failed: ' + $_.Exception.Message); exit 97 }"
if errorlevel 1 (
  echo.
  echo [STOP] The runner failed its syntax precheck. No scientific run was started.
  pause
  exit /b 97
)

echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%HS_SCRIPT%"
set "RC=%ERRORLEVEL%"

echo.
if "%RC%"=="0" (
  echo [DONE] The diagnostic finished. See the results folder.
) else (
  echo [STOP] The diagnostic did not complete cleanly.
  if exist "%~dp0results\UPLOAD_HARD_SERVICE_RESULT_*.zip" (
    echo        Upload the newest UPLOAD_HARD_SERVICE_RESULT_*.zip from the results folder.
  ) else (
    echo        No result ZIP was created. Send the console error message instead.
  )
)
echo.
pause
exit /b %RC%
