@echo off
REM Prepare the build folder
set NAME=world
if not exist build mkdir build
if "%NAME%"=="world" (
    echo Hello %NAME%
) else (
    goto :end
)
:end
exit /b 0
