@echo off
rem update.bat: the manager's entry point to the update tool (deploy-init-plan.md
rem D5 7.1). A thin wrapper: bin/radioctl does the work inside the WSL
rem distribution radio-atlantida, as the Linux user radio.
rem
rem   update.bat                         install release.env
rem   update.bat 1.0.3 [1.0.3]           install a given release
rem   update.bat rollback | restore | maintenance | status | cutover | ...
rem
rem Keeps radioctl's exit code; pauses only when started by double-click, so
rem the window stays open to read the result.
setlocal
rem wsl.exe writes UTF-16 for some commands unless this is set.
set "WSL_UTF8=1"
set "DISTRO=radio-atlantida"

wsl.exe -l -q 2>nul | findstr /x /c:"%DISTRO%" >nul
if errorlevel 1 (
  echo The WSL distribution %DISTRO% does not exist for the account %USERNAME%.
  echo Sign in to Windows as the account radio and run update.bat again.
  set "RC=1"
  goto :done
)

wsl.exe -d %DISTRO% -u radio --cd /opt/radio-atlantida/deploy -- bin/radioctl %*
set "RC=%ERRORLEVEL%"

:done
rem Started by double-click: cmd.exe /c "...\update.bat" carries this script's
rem path in its command line; a terminal's cmd.exe does not.
echo %CMDCMDLINE% | find /i "%~0" >nul
if not errorlevel 1 pause
exit /b %RC%
