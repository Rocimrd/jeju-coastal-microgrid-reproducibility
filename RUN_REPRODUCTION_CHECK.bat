@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0validation\run_reproduction_check.ps1"
set "RC=%ERRORLEVEL%"
echo.
if "%RC%"=="0" (
  echo REPRODUCTION CHECK: PASS
) else (
  echo REPRODUCTION CHECK: FAIL ^(exit code %RC%^)
)
pause
exit /b %RC%
