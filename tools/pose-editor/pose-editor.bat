@echo off
rem PoseCam pose editor (needs Python 3). Keep this window open while editing.
cd /d "%~dp0"
where py >nul 2>nul
if %errorlevel%==0 (py -3 server.py) else (python server.py)
echo.
echo The pose editor has stopped. Press any key to close this window.
pause >nul
