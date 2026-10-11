@echo off
cd /d "%~dp0"
where pyw >nul 2>nul && (start "" pyw "%~dp0yt_gui.py" & exit /b)
where pythonw >nul 2>nul && (start "" pythonw "%~dp0yt_gui.py" & exit /b)
echo Python was not found. Install it from python.org (tick "Add python.exe to PATH"), then run this again.
pause
