@echo off
chcp 65001 >nul
title EMS Sorter v0.5.1
cd /d "%~dp0"

set VERSION=0.5.1

PowerShell -NoProfile -ExecutionPolicy Bypass -File "%~dp0EMS-Sorter.ps1" -expectedVersion %VERSION%

if errorlevel 1 (
    echo.
    echo Ошибка: несовпадение версий. Скачайте актуальную версию программы.
    pause
)