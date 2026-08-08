@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0"

set "FOUND_ROOT="
if defined CPLEX_ROOT if exist "%CPLEX_ROOT%\cplex\include\ilcplex\ilocplex.h" set "FOUND_ROOT=%CPLEX_ROOT%"
if not defined FOUND_ROOT if defined CPLEX_STUDIO_DIR2212 if exist "%CPLEX_STUDIO_DIR2212%\cplex\include\ilcplex\ilocplex.h" set "FOUND_ROOT=%CPLEX_STUDIO_DIR2212%"
if not defined FOUND_ROOT (
  for %%D in (
    "C:\Program Files\IBM\ILOG\CPLEX_Studio2212"
    "C:\IBM\ILOG\CPLEX_Studio2212"
  ) do (
    if not defined FOUND_ROOT if exist "%%~D\cplex\include\ilcplex\ilocplex.h" set "FOUND_ROOT=%%~D"
  )
)
if not defined FOUND_ROOT (
  echo [ERROR] IBM ILOG CPLEX Optimization Studio 22.1.2 was not found.
  echo Set CPLEX_ROOT to the CPLEX_Studio2212 installation directory and run again.
  exit /b 1
)
set "LIBDIR=%FOUND_ROOT%\cplex\lib\x64_windows_msvc14\stat_mda"
if not exist "%LIBDIR%\cplex2212.lib" (
  echo [ERROR] cplex2212.lib was not found in "%LIBDIR%".
  exit /b 1
)
> CPLEX_local.props echo ^<?xml version="1.0" encoding="utf-8"?^>
>> CPLEX_local.props echo ^<Project ToolsVersion="4.0" xmlns="http://schemas.microsoft.com/developer/msbuild/2003"^>
>> CPLEX_local.props echo   ^<PropertyGroup^>
>> CPLEX_local.props echo     ^<CplexRoot^>%FOUND_ROOT%^</CplexRoot^>
>> CPLEX_local.props echo     ^<CplexLibName^>cplex2212.lib^</CplexLibName^>
>> CPLEX_local.props echo   ^</PropertyGroup^>
>> CPLEX_local.props echo ^</Project^>
echo [OK] CPLEX 22.1.2 root: %FOUND_ROOT%
echo [OK] CPLEX_local.props written.
exit /b 0
