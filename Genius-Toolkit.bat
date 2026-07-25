@echo off
title Genius Windows Toolkit
rem Launcher de duplo-clique: roda o toolkit local sem precisar mexer no PowerShell.
rem Funciona 100%% offline (a partir do pendrive/pasta onde este .bat esta).
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0GeniusToolkit.ps1" %*
if errorlevel 1 (
    echo.
    echo Ocorreu um erro ao iniciar. Pressione uma tecla para fechar.
    pause >nul
)
