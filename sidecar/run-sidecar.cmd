@echo off
rem Starts the A-Life Brain sidecar against %USERPROFILE%\Zomboid\Lua. Close the window or press Ctrl+C to stop.
cd /d "%~dp0"
py -3.12 -m alifebrain_sidecar --verbose %*
if errorlevel 1 pause
