@echo off
rem Sidecar with the fake provider: NPCs answer "(test) You said: ..." without any LLM.
rem Use it to test the in-game dialogue flow before Player2 is set up.
cd /d "%~dp0"
py -3.12 -m alifebrain_sidecar --verbose --provider fake %*
if errorlevel 1 pause
