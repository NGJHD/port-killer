@echo off
setlocal
title Claude Port Cleanup

set "PS1=%~dp0claude-ports.ps1"
if not exist "%PS1%" (
  echo Could not find "%PS1%"
  pause
  exit /b 1
)

rem Windows PowerShell ships with Windows; fall back to PowerShell 7 if it is gone.
set "PWSH=powershell.exe"
where /Q powershell.exe || set "PWSH=pwsh.exe"

"%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  echo.
  echo Script exited with code %RC%.
  pause
)
endlocal
