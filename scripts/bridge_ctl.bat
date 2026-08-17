@echo off
title XeMonitor - Bridge Controller
setlocal enabledelayedexpansion

:: ============================================================
:: bridge_ctl.bat - controla o servico do bridge no WSL (Alpine/OpenRC).
:: O instalador baixa o Alpine e o define como distribuicao padrao; se o
:: Alpine nao estiver presente, pede para rodar o instalador.
::
:: Uso:  bridge_ctl.bat <acao>
:: Acoes: status | start | stop | restart | enable | dev | ch341
:: Env:   XEMONITOR_WSL_DISTRO=Alpine  (override)
:: ============================================================

set "ACTION=%~1"
if "%ACTION%"=="" (
    echo [bridge_ctl] uso: bridge_ctl.bat status^|start^|stop^|restart^|enable^|dev
    exit /b 2
)

:: ---- Detecta distro WSL (Alpine OBRIGATORIA) ----
set "DISTRO=%XEMONITOR_WSL_DISTRO%"
if not defined DISTRO (
    wsl -d Alpine echo ok >nul 2>&1
    if !errorlevel! equ 0 set "DISTRO=Alpine"
)
if not defined DISTRO (
    echo [bridge_ctl] ERRO: Alpine WSL nao encontrado. Rode o instalador
    echo                setup.exe para baixar o Alpine e defini-lo como padrao.
    wsl -l -v
    exit /b 1
)

echo [bridge_ctl] distro=%DISTRO% acao=%ACTION%

set "RUN=wsl -d Alpine -u root"
:: WSL/container: OpenRC nao e o init real; softlevel libera o rc-service.
%RUN% sh -c "mkdir -p /run/openrc && touch /run/openrc/softlevel" >nul 2>&1
if /i "%ACTION%"=="status"  goto :rc_status
if /i "%ACTION%"=="start"   goto :rc_start
if /i "%ACTION%"=="stop"    goto :rc_stop
if /i "%ACTION%"=="restart" goto :rc_restart
if /i "%ACTION%"=="enable"  goto :rc_enable
if /i "%ACTION%"=="dev"     goto :rc_dev
if /i "%ACTION%"=="ch341"   goto :rc_ch341
echo [bridge_ctl] acao invalida: %ACTION%
exit /b 2

:rc_status
%RUN% rc-service xemonitor-bridge status
exit /b !errorlevel!

:rc_start
%RUN% rc-service xemonitor-bridge start
if !errorlevel! neq 0 exit /b !errorlevel!
:: Validacao real: porta 9000 ouvindo (rc-service start pode reportar OK
:: mas o daemon morre logo em seguida - bug visto no install do usuario).
%RUN% sh -c "sleep 1 && ss -tln 2>/dev/null | grep -q ':9000'"
if !errorlevel! neq 0 (
    echo [bridge_ctl] ERRO: rc-service start OK mas porta 9000 nao ouvindo.
    echo                Verifique: wsl -d Alpine -u root -- rc-service xemonitor-bridge status
    echo                Log do bridge: wsl -d Alpine -- cat /var/log/xemonitor-bridge.log 2^>/dev/null
)
exit /b !errorlevel!

:rc_stop
%RUN% rc-service xemonitor-bridge stop
exit /b !errorlevel!

:rc_restart
%RUN% rc-service xemonitor-bridge restart
if !errorlevel! neq 0 exit /b !errorlevel!
:: Mesma validacao do :rc_start
%RUN% sh -c "sleep 1 && ss -tln 2>/dev/null | grep -q ':9000'"
if !errorlevel! neq 0 (
    echo [bridge_ctl] ERRO: rc-service restart OK mas porta 9000 nao ouvindo.
)
exit /b !errorlevel!

:rc_enable
%RUN% rc-update add xemonitor-bridge default
exit /b !errorlevel!

:rc_dev
:: Verifica se o scanner USB-Serial (CH340) esta presente no WSL
%RUN% sh -c "test -c /dev/ttyUSB0"
exit /b !errorlevel!

:rc_ch341
:: Garante o driver ch341 carregado (senao /dev/ttyUSB0 nao aparece apos o
:: attach via usbipd) e confirma o device. Modprobe e idempotente.
%RUN% sh -c "modprobe ch341 && test -c /dev/ttyUSB0"
exit /b !errorlevel!
