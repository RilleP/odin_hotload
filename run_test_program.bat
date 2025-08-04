@echo off

odin build generator -debug
if errorlevel 1 goto generator_build_failed

generator.exe test_program -lib -loader -log-info
if errorlevel 1 goto generating_failed

odin run test_program -ignore-unknown-attributes -debug
if errorlevel 1 goto program_build_failed


goto end

:generator_build_failed
echo Generator Build Failed!
goto end

:generating_failed
echo Generating Failed!
goto end

:program_build_failed
echo Program Build Failed!
goto end


:end