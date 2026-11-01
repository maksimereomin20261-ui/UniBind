@echo off
setlocal
cd /d "%~dp0"
echo Building custom UniBind Setup...
python -m pip install --upgrade pyinstaller
if errorlevel 1 goto error
python -m PyInstaller --noconfirm --clean --onefile --windowed --name UniBind_Setup --icon "UniBind.ico" launcher.py
if errorlevel 1 goto error
echo.
echo SUCCESS: dist\UniBind_Setup.exe
pause
exit /b 0
:error
echo.
echo BUILD FAILED. Check Python and PyInstaller.
pause
exit /b 1
