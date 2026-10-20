@echo off
setlocal
title PBI AI Bridge

rem ---------------------------------------------------------------------------
rem  PBI AI Bridge - the only file you ever double-click.
rem
rem  Every run walks the same checklist and only does what is missing:
rem    already running?  -> just open the dashboard
rem    .NET SDK          -> first time only (offers to install it, or to reinstall a damaged one)
rem    settings file     -> first time only (copied from the template)
rem    libraries         -> first time only (offers to download them)
rem    compile           -> only when the program changed
rem    start             -> the server opens the dashboard once it is ready
rem
rem  NOTE: keep this file ASCII-only with CRLF line endings.
rem  cmd.exe tracks its position in a batch file in BYTES. Multi-byte text or
rem  LF-only line endings make it lose its place, and goto / labels break.
rem
rem  So everything shown on screen lives in tools\launcher-text.txt (UTF-8),
rem  one line per screen line (the key, a bar, the text), and this file only
rem  names the keys:
rem    call :SAY KEY        prints the lines of KEY
rem    call :SAYN KEY       prints a one-line KEY and stays on that line
rem    call :ASK KEY YN     shows a one-line question and waits for Y or N
rem  The window is switched to code page 65001 so cmd reads that file as UTF-8,
rem  and it stays there: switching back makes Windows Terminal clear the whole
rem  screen. The server checks for itself whether it can show emoji.
rem ---------------------------------------------------------------------------

set "ROOT=%~dp0"
set "PROJECT=%ROOT%pbibridge_csharp"
set "CONFIG=%PROJECT%\appsettings.json"
set "TEMPLATE=%PROJECT%\appsettings.template.json"
set "ASSETS=%PROJECT%\obj\project.assets.json"
set "BIN=%PROJECT%\bin\Release\net8.0"
set "DLL=%BIN%\pbibridge_csharp.dll"
set "STAMP=%BIN%\build.stamp"
set "URL=http://localhost:5500/"
set "SDKLIST=%TEMP%\pbi_bridge_sdks.txt"
set "TEXT=%ROOT%tools\launcher-text.txt"
rem dotnet prints a long welcome and telemetry notice the first time after an
rem SDK install. It only hides that notice; it changes no telemetry setting.
set "DOTNET_NOLOGO=1"

rem Without the text file nothing can be said in Chinese, so this one message
rem stays in English here.
if not exist "%TEXT%" goto NO_TEXT

rem Switch to UTF-8 before the first line is printed, and never switch back:
rem in Windows Terminal every code page change clears the screen.
chcp 65001 >nul

call :SAY BANNER


rem === already running? =======================================================
rem Double-clicking again while the server runs is common. Answer with the
rem dashboard instead of a compile error about locked files.
netstat -ano | findstr /r /c:":5500 .*LISTENING" >nul 2>&1
if errorlevel 1 goto STEP_FILES
powershell -NoProfile -Command "try { if ((Invoke-RestMethod -Uri 'http://localhost:5500/ping' -TimeoutSec 3) -eq 'pong') { exit 0 } } catch { }; exit 1" >nul 2>&1
if errorlevel 1 goto PORT_BUSY
call :SAY RUNNING
start "" "%URL%"
timeout /t 5 >nul
exit /b 0


rem === [1/5] files ============================================================
:STEP_FILES
call :SAYN STEP1
if not exist "%PROJECT%\Program.cs" goto INCOMPLETE
if not exist "%TEMPLATE%" goto INCOMPLETE
set "NOTED="
if not exist "%CONFIG%" call :LOCATION_CHECK
if not defined NOTED call :SAY R_OK


rem === [2/5] .NET SDK =========================================================
call :SAYN STEP2
call :FIND_DOTNET
if not defined DOTNET goto NO_SDK
call :SAY R_OK
:SDK_OK


rem === [3/5] settings file ====================================================
call :SAYN STEP3
if not exist "%CONFIG%" goto CONFIG_NEW
call :SAY R_OK
goto STEP_LIBS
:CONFIG_NEW
rem Nothing secret goes into this file. The API Key is not in it: the server
rem creates the key the first time it starts and keeps it in the user profile
rem (LOCALAPPDATA, folder PBI_AI_Bridge). That is outside this folder, so
rem copying or zipping this folder never takes the key along.
rem So a plain copy of the template is all it takes.
copy /y "%TEMPLATE%" "%CONFIG%" >nul
if errorlevel 1 goto CONFIG_FAIL
if not exist "%CONFIG%" goto CONFIG_FAIL
call :SAY R_CREATED
call :SAY CONFIG_CREATED
call :SAY PROTECTION


rem === [4/5] libraries ========================================================
:STEP_LIBS
call :SAYN STEP4
if not exist "%ASSETS%" goto LIBS_NEED
call :SAY R_OK
goto LIBS_OK

:LIBS_NEED
rem A freshly downloaded copy has no obj\, but the libraries may already sit in
rem this computer's NuGet cache (another copy fetched them). Restore is then
rem instant and offline - so do not ask about a download that will not happen.
set "NUGET_ROOT=%USERPROFILE%\.nuget\packages"
if defined NUGET_PACKAGES set "NUGET_ROOT=%NUGET_PACKAGES%"
if exist "%NUGET_ROOT%\microsoft.analysisservices.netcore.retail.amd64" goto LIBS_CACHED

call :SAY R_FIRST
call :SAY LIBS_ABOUT
call :ASK ASK_LIBS YN
if errorlevel 2 goto LIBS_DECLINED
call :SAY LIBS_DOWNLOADING
goto LIBS_RETRY

:LIBS_CACHED
call :SAY R_CACHED

:LIBS_RETRY
"%DOTNET%" restore "%PROJECT%" --nologo -v q
if errorlevel 1 goto RESTORE_FAIL
call :SAY LIBS_DONE
:LIBS_OK


rem === [5/5] compile and start ================================================
call :SAYN STEP5
if not exist "%DLL%" goto DO_BUILD
if not exist "%STAMP%" goto DO_BUILD
rem Compile only when the program changed: faster start, and no freshly written
rem DLL for the antivirus to inspect on every launch.
powershell -NoProfile -Command "$s=(Get-Item -LiteralPath $env:STAMP).LastWriteTimeUtc; foreach ($f in 'Program.cs','pbibridge_csharp.csproj') { if ((Get-Item -LiteralPath (Join-Path $env:PROJECT $f)).LastWriteTimeUtc -gt $s) { exit 1 } }; exit 0"
if errorlevel 1 goto DO_BUILD
call :SAY R_UPTODATE
goto START

:DO_BUILD
call :SAY R_BUILD
"%DOTNET%" build "%PROJECT%" -c Release --nologo -v q
if errorlevel 1 goto BUILD_FAIL
if not exist "%DLL%" goto BUILD_FAIL
type nul > "%STAMP%"
call :SAY BUILD_DONE

:START
rem Always refresh the settings copy the server reads. A plain copy is cheap and
rem also covers a settings file restored from an older backup, which the
rem compiler's newer-than check would skip.
copy /y "%CONFIG%" "%BIN%\appsettings.json" >nul
call :SAY START
"%DOTNET%" "%DLL%"
call :SAY SERVER_EXIT
pause >nul
exit /b 0


rem ===========================================================================
rem  Problems - each one explains what happened and what to do
rem ===========================================================================

:NO_TEXT
echo.
echo [ERROR] This folder is incomplete: tools\launcher-text.txt is missing.
echo         Get the whole folder again, and unzip it first - do not run it
echo         from inside the zip.
echo.
pause
exit /b 1


:INCOMPLETE
call :SAY R_PROBLEM
call :SAY INCOMPLETE
call :SAY PRESS_CLOSE
pause >nul
exit /b 1


:NO_SDK
call :SAY R_MISSING
call :SAY SDK_NEEDED
where winget >nul 2>&1
if errorlevel 1 goto SDK_MANUAL
rem Windows can list the SDK as installed while its files are gone: an
rem automatic update that stopped halfway leaves it like that. winget then
rem treats an install as "already installed" and does nothing, and this
rem window could only ever say "still not found". Reinstall it instead.
winget list --id Microsoft.DotNet.SDK.8 --exact --source winget --accept-source-agreements --disable-interactivity 2>nul | findstr /l /i /c:"Microsoft.DotNet.SDK.8" >nul
if not errorlevel 1 goto SDK_BROKEN
call :SAY SDK_OFFER
call :ASK ASK_SDK_INSTALL YN
if errorlevel 2 goto SDK_MANUAL
echo.
winget install --id Microsoft.DotNet.SDK.8 --exact --source winget --accept-package-agreements --accept-source-agreements
call :FIND_DOTNET
if defined DOTNET goto SDK_READY
call :SAY SDK_INSTALL_FAILED

:SDK_MANUAL
call :SAY SDK_MANUAL
:SDK_WAIT
call :ASK ASK_SDK_MANUAL ORQ
if errorlevel 3 exit /b 1
if errorlevel 2 goto SDK_RECHECK
start "" "https://dotnet.microsoft.com/download/dotnet/8.0"
goto SDK_WAIT
:SDK_RECHECK
call :FIND_DOTNET
if defined DOTNET goto SDK_READY
call :SAY SDK_STILL_MISSING
goto SDK_WAIT

:SDK_BROKEN
call :SAY SDK_BROKEN
call :ASK ASK_SDK_REINSTALL YN
if errorlevel 2 goto SDK_REPAIR_MANUAL
echo.
winget uninstall --id Microsoft.DotNet.SDK.8 --exact --source winget --accept-source-agreements
winget install --id Microsoft.DotNet.SDK.8 --exact --source winget --accept-package-agreements --accept-source-agreements
call :FIND_DOTNET
if defined DOTNET goto SDK_READY
call :SAY SDK_REINSTALL_FAILED

:SDK_REPAIR_MANUAL
call :SAY SDK_REPAIR_MANUAL
:SDK_REPAIR_WAIT
call :ASK ASK_SDK_REPAIR ORQ
if errorlevel 3 exit /b 1
if errorlevel 2 goto SDK_REPAIR_RECHECK
start "" "ms-settings:appsfeatures"
goto SDK_REPAIR_WAIT
:SDK_REPAIR_RECHECK
call :FIND_DOTNET
if defined DOTNET goto SDK_READY
call :SAY SDK_REPAIR_STILL_MISSING
goto SDK_REPAIR_WAIT

:SDK_READY
call :SAY SDK_READY
goto SDK_OK


:CONFIG_FAIL
call :SAY R_PROBLEM
call :SAY CONFIG_FAIL
call :SAY PRESS_CLOSE
pause >nul
exit /b 1


:LIBS_DECLINED
call :SAY LIBS_DECLINED
call :SAY PRESS_CLOSE
pause >nul
exit /b 1


:RESTORE_FAIL
call :SAY RESTORE_FAIL
"%DOTNET%" nuget list source | findstr /i /c:"api.nuget.org" >nul
if not errorlevel 1 goto RESTORE_NETWORK
call :SAY NUGET_SOURCE_MISSING
call :ASK ASK_NUGET_SOURCE YN
if errorlevel 2 goto RESTORE_NETWORK
"%DOTNET%" nuget add source https://api.nuget.org/v3/index.json -n nuget.org
goto LIBS_RETRY

:RESTORE_NETWORK
call :SAY RESTORE_NETWORK
call :ASK ASK_RESTORE_RETRY RQ
if errorlevel 2 exit /b 1
goto LIBS_RETRY


:BUILD_FAIL
call :SAY BUILD_FAIL
call :SAY PRESS_CLOSE
pause >nul
exit /b 1


:PORT_BUSY
call :SAY PORT_BUSY
pause >nul
exit /b 1


rem pause is always silent (pause >nul) and the hint comes from the text file:
rem under code page 65001 pause prints its own prompt in English.


rem ===========================================================================
rem  Subroutines
rem ===========================================================================

rem Screen text, from tools\launcher-text.txt. A FOR variable is expanded after
rem cmd has parsed the line, so ampersands, pipes, angle brackets, percent
rem signs, carets and quotes in the text print as they are. Each call reads the
rem whole file - it is small, and this needs no extra program.
:SAY
for /f "usebackq tokens=1* delims=|" %%A in ("%TEXT%") do if "%%A"=="%~1" echo(%%B
exit /b 0

rem Stays on the line, for "[1/5] ...... " followed by the result. set /p
rem drops leading spaces, so these lines start at column 0.
:SAYN
for /f "usebackq tokens=1* delims=|" %%A in ("%TEXT%") do if "%%A"=="%~1" <nul set /p "=%%B "
exit /b 0

rem Shows a one-line question and waits for one of the keys in %2; the answer
rem comes back as the errorlevel, like choice itself. choice drops leading
rem spaces too, so those lines are indented with full-width spaces.
:ASK
for /f "usebackq tokens=1* delims=|" %%A in ("%TEXT%") do if "%%A"=="%~1" choice /c %~2 /n /m "%%B "
exit /b %errorlevel%

rem Sets DOTNET to the first dotnet that has an SDK of version 8 or newer.
rem Checks the fixed install folders too: right after a fresh install, PATH in
rem this window is still the old one.
:FIND_DOTNET
set "DOTNET="
if exist "%USERPROFILE%\.dotnet\dotnet.exe" call :TRY_DOTNET "%USERPROFILE%\.dotnet\dotnet.exe"
if not defined DOTNET if exist "%ProgramFiles%\dotnet\dotnet.exe" call :TRY_DOTNET "%ProgramFiles%\dotnet\dotnet.exe"
if not defined DOTNET call :TRY_DOTNET dotnet
exit /b 0

:TRY_DOTNET
set "SDK_OK_FLAG="
"%~1" --list-sdks > "%SDKLIST%" 2>nul
for /f "usebackq tokens=1 delims=." %%V in ("%SDKLIST%") do if %%V GEQ 8 set "SDK_OK_FLAG=1"
del "%SDKLIST%" >nul 2>&1
if defined SDK_OK_FLAG set "DOTNET=%~1"
exit /b 0


:LOCATION_CHECK
echo "%ROOT%" | findstr /i "OneDrive" >nul
if errorlevel 1 exit /b 0
set "NOTED=1"
call :SAY R_WARN
call :SAY ONEDRIVE
pause >nul
exit /b 0
