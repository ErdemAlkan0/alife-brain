@echo off
rem PPO in the squad simulation: trains, compares with baselines, writes rl\out\PolicyWeights.ppo.lua
rem (--install also writes it into the mod for the game's shadow mode).
rem First time: rl\.venv\Scripts\python -m pip install -r rl\requirements-ppo.txt --extra-index-url https://download.pytorch.org/whl/cpu
cd /d "%~dp0"
if not exist ".venv\Scripts\python.exe" (
    echo rl\.venv is missing. Run: py -3.12 -m venv rl\.venv  and install rl\requirements.txt and rl\requirements-ppo.txt
    exit /b 1
)
".venv\Scripts\python.exe" -m alifebrain_rl.ppo %*
