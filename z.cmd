@echo off
rem Обёртка для zig: берёт zig из PATH, иначе — тулчейн, вложенный в проект.
setlocal
set "ZIG=zig"
where zig >nul 2>nul || set "ZIG=%~dp0tools\zig-0.15.2\zig.exe"
if not exist "%ZIG%" (
    echo Zig не найден: нет в PATH и отсутствует tools\zig-0.15.2\zig.exe
    echo Установите Zig 0.15.x ^(https://ziglang.org/download/^) или вложите тулчейн в tools\
    exit /b 1
)
"%ZIG%" %*
