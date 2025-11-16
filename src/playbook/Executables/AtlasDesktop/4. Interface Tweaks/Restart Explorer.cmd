@echo off
taskkill /f /im explorer.exe >nul 2>&1
if errorlevel 1 (
    echo Warning: Could not stop explorer.exe
)
start "" "%windir%\explorer.exe"
if errorlevel 1 (
    echo Error: Could not restart explorer.exe
    exit /b 1
)
