@echo off
cd /d "%~dp0"
if "%~1"=="" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy\deploy.ps1" deploy
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy\deploy.ps1" %*
)
set EXITCODE=%ERRORLEVEL%
echo.
if %EXITCODE% neq 0 (
    echo Deploy failed. See errors above.
) else (
    echo Done.
)
pause
exit /b %EXITCODE%
