@echo off
rem Builds sidecar\dist\ALifeBrainSidecar.exe: the whole sidecar in one file, so players need no Python.
rem It takes the same arguments as run-sidecar.cmd (e.g. --provider fake, --verbose).
rem The first run creates sidecar\.venv-build and installs PyInstaller there (from PyPI).
rem The window waits for a key at the end; pass nopause to skip that (scripts).
cd /d "%~dp0"
set "PAUSE_AT_END=1"
if /i "%~1"=="nopause" set "PAUSE_AT_END=0"
if not exist ".venv-build\Scripts\python.exe" (
    echo Creating the build environment, first run only...
    py -3.12 -m venv .venv-build || goto failed
    ".venv-build\Scripts\python.exe" -m pip install --upgrade "pyinstaller>=6.10" || goto failed
)
".venv-build\Scripts\python.exe" -m PyInstaller --noconfirm --clean --onefile --console ^
    --name ALifeBrainSidecar --paths . --distpath dist --workpath build\pyinstaller --specpath build ^
    packaging\launcher.py || goto failed
echo.
echo Built: %~dp0dist\ALifeBrainSidecar.exe
echo Start that file instead of run-sidecar.cmd: it needs no Python. This script only builds it.
if "%PAUSE_AT_END%"=="1" pause
exit /b 0

:failed
echo.
echo The build failed: see the messages above. If the exe is running, close it and build again.
if "%PAUSE_AT_END%"=="1" pause
exit /b 1
