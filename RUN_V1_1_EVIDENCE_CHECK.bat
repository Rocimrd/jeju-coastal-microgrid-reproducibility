@echo off
setlocal
cd /d "%~dp0"
python validation\check_v1_1_evidence.py
if errorlevel 1 (
  echo.
  echo V1.1 evidence check FAILED.
  exit /b 1
)
echo.
echo V1.1 evidence check PASSED.
exit /b 0
