@echo off
..\..\generator.exe . -loader

if errorlevel 1 goto failed

odin run . -ignore-unknown-attributes

if errorlevel 1 goto failed

goto end

:failed
echo Failed

:end