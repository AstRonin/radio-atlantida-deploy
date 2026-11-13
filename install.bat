@echo off
rem install.bat: the host install of Radio Atlantida (deploy-init-plan.md D4
rem 6.2). Sign in to Windows as the local account radio and double-click it.
rem It runs install.ps1, which elevates itself (a UAC prompt), and passes
rem every argument on:
rem
rem   install.bat                    install, or continue / re-check an install
rem   install.bat -DryRun            show every step and its check, change nothing
rem   install.bat -CreateAccount     create the local administrator radio first
rem   install.bat -MediaFolder "D:\RadioAtlantida\media" -InstallRoot D:\RadioAtlantida
rem
rem Keeps install.ps1's exit code; pauses only when started by double-click.
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
set "RC=%ERRORLEVEL%"
echo %CMDCMDLINE% | find /i "%~0" >nul
if not errorlevel 1 pause
exit /b %RC%
