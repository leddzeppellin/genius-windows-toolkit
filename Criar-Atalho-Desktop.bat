@echo off
title Criar atalho - Genius Windows Toolkit
rem Cria um atalho na Area de Trabalho com o icone da marca, apontando para o app.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\New-DesktopShortcut.ps1"
echo.
pause
