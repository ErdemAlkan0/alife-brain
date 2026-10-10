@echo off
rem Behavior cloning: trains on the decisions the game logged and writes PolicyWeights.lua.
rem First time: py -3.12 -m venv rl\.venv  then  rl\.venv\Scripts\python -m pip install -r rl\requirements.txt
cd /d "%~dp0"
if not exist ".venv\Scripts\python.exe" (
    echo rl\.venv is missing. Run: py -3.12 -m venv rl\.venv  and  rl\.venv\Scripts\python -m pip install -r rl\requirements.txt
    exit /b 1
)
".venv\Scripts\python.exe" -m alifebrain_rl.bc %*
