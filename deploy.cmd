@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ci\deploy.ps1" %*
