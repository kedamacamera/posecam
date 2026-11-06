@echo off
rem PoseCam pose editor (needs Python 3)
cd /d "%~dp0"
python server.py
if errorlevel 1 pause
