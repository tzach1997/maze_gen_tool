@echo off
REM Set your Garry's Mod path and addon folder name
set GARRYSMOD_PATH=C:\Program Files (x86)\Steam\steamapps\common\GarrysMod
set ADDON_FOLDER=maze_gen_tool
set ADDON_PATH=%~dp0

REM Path to gmad.exe and gmpublish.exe (edit if needed)
set GMAD_EXE="%GARRYSMOD_PATH%\bin\gmad.exe"
set GMPUBLISH_EXE="%GARRYSMOD_PATH%\bin\gmpublish.exe"
echo Using Garry's Mod path: %ADDON_PATH%
%GMAD_EXE% create -folder %ADDON_PATH%
if %ERRORLEVEL% neq 0 (
    echo Failed to pack addon!
    pause
    exit /b 1
)
echo Addon packed: %OUTPUT_GMA%

pause
echo.
echo To publish as a new Workshop addon, run:
echo %GMPUBLISH_EXE% create -addon "%OUTPUT_GMA%" -icon "becon.jpg"
echo.
echo To update your Workshop addon, run:
echo %GMPUBLISH_EXE% update -addon "%OUTPUT_GMA%" -id 3576970036 -icon "becon.jpg"
echo Replace becon.jpg with your addon icon path if you want to update the icon.
pause
