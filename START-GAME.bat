@echo off
rem Double-click this to play. It starts a small local web server and opens
rem the game in your browser. Nothing gets installed.
setlocal
title SuperTuxKart
cd /d "%~dp0"

if not exist "%~dp0serve.ps1" (
  echo Could not find serve.ps1 next to this file.
  echo Make sure you extracted the whole folder, not just this one file.
  echo.
  pause
  exit /b 1
)

if not exist "%~dp0game\supertuxkart.wasm" (
  echo.
  echo The game files are missing from the "game" folder.
  echo.
  echo If you downloaded this as a ZIP from GitHub, the large files may not
  echo have come with it. Use "git clone" instead, or see README.md.
  echo.
  pause
  exit /b 1
)

rem PowerShell 7 if it happens to be installed, otherwise the Windows PowerShell
rem that ships with every Windows machine.
set "PSEXE=powershell"
where pwsh >nul 2>nul && set "PSEXE=pwsh"

where %PSEXE% >nul 2>nul
if errorlevel 1 (
  echo PowerShell was not found on this machine, which is unusual.
  echo See README.md for another way to start the server.
  echo.
  pause
  exit /b 1
)

rem -ExecutionPolicy Bypass matters: Windows blocks unsigned .ps1 files by
rem default, and this overrides that for this one process only.
%PSEXE% -NoProfile -ExecutionPolicy Bypass -File "%~dp0serve.ps1" %*

echo.
echo The server has stopped.
pause
