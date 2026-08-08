@echo off
setlocal
cd /d "%~dp0"
set "PROJ=JejuFullCoupled24h.vcxproj"
if not exist "%PROJ%" (
  echo [ERROR] Missing %PROJ%.
  exit /b 1
)
call configure_cplex_paths.bat
if errorlevel 1 exit /b 1
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" (
  echo [ERROR] vswhere.exe not found. Install Visual Studio or Build Tools with the C++ build tools.
  exit /b 1
)
set "MSBUILD="
for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.Component.MSBuild -find MSBuild\**\Bin\MSBuild.exe`) do set "MSBUILD=%%i"
if not defined MSBUILD (
  echo [ERROR] MSBuild not found.
  exit /b 1
)
echo [INFO] MSBuild: %MSBUILD%
if defined REPRO_TOOLSET (
  echo [INFO] Toolset override: %REPRO_TOOLSET%
  "%MSBUILD%" "%PROJ%" /m /p:Configuration=Release /p:Platform=x64 /p:PlatformToolset=%REPRO_TOOLSET%
) else (
  "%MSBUILD%" "%PROJ%" /m /p:Configuration=Release /p:Platform=x64
)
if errorlevel 1 (
  echo [ERROR] Build failed.
  echo If v145 is unavailable but Visual Studio 2022 with v143 is installed, run:
  echo   set REPRO_TOOLSET=v143
  echo   build_release_x64.bat
  exit /b 1
)
if not exist "x64\Release\JejuFullCoupled24h.exe" (
  echo [ERROR] Build reported success but executable was not found.
  exit /b 1
)
echo [OK] Built x64\Release\JejuFullCoupled24h.exe
exit /b 0
