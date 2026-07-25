@echo off
title Genius Windows Toolkit (Administrador)
rem Launcher que sobe como Administrador automaticamente (pede o UAC).
rem Necessario para as abas Rede, Recursos, Windows Update e Criar ISO.
net session >nul 2>&1
if not "%errorlevel%"=="0" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0GeniusToolkit.ps1" %*
if errorlevel 1 (
    echo.
    echo Ocorreu um erro ao iniciar. Pressione uma tecla para fechar.
    pause >nul
)
