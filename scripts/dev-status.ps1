<#
.SYNOPSIS
  Muestra el /health de cada servicio local de ConsultaYa. Equivale a scripts/dev-status.sh.
.DESCRIPTION
  usuarios  http://localhost:8001/health
  lecciones http://localhost:8002/health
  progreso  http://localhost:8003/health
  frontend  http://localhost:5173/        (Vite)
  gateway   http://localhost:8080/health  (nginx del modo Docker; opcional)
  Código de salida: 0 si los 3 servicios nativos responden, 1 si alguno no.
.PARAMETER Help
  Muestra esta ayuda.
#>
[CmdletBinding()]
param([switch]$Help)

$ErrorActionPreference = 'Stop'
if ($Help) { Get-Help $PSCommandPath -Detailed; return }

. (Join-Path $PSScriptRoot 'lib/entorno.ps1')

$fallos = 0
function Show-Estado([string]$Nombre, [string]$Url, [bool]$Obligatorio) {
  $cuerpo = Get-RespuestaCorta $Url
  if ($null -ne $cuerpo) {
    Write-Host ('  {0,-10} OK       {1}' -f $Nombre, $cuerpo)
  } else {
    Write-Host ('  {0,-10} caído    {1}' -f $Nombre, $Url)
    if ($Obligatorio) { $script:fallos++ }
  }
}

Write-Host 'Modo nativo:'
Show-Estado 'usuarios' 'http://localhost:8001/health' $true
Show-Estado 'lecciones' 'http://localhost:8002/health' $true
Show-Estado 'progreso' 'http://localhost:8003/health' $true
Show-Estado 'frontend' 'http://localhost:5173/' $false
Write-Host 'Modo Docker (opcional):'
Show-Estado 'gateway' 'http://localhost:8080/health' $false

if ($fallos -gt 0) {
  [Console]::Error.WriteLine("$fallos servicio(s) nativo(s) sin respuesta. Usa scripts\dev-up.ps1.")
  exit 1
}
exit 0
