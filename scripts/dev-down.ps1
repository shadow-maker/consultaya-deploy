<#
.SYNOPSIS
  Detiene lo que arrancó dev-up.ps1 (por PID y su árbol de procesos; como respaldo, por puerto).
  Equivale a scripts/dev-down.sh.
.DESCRIPTION
  1. Por PID guardado en .logs\*.pid (taskkill /T /F: el proceso y todos sus hijos).
  2. Como respaldo, lo que escuche en los puertos 8001, 8002, 8003 y 5173, solo si es un proceso
     python/uvicorn/node/uv/npm.
  NUNCA toca procesos en otros puertos ni detiene PostgreSQL.
.PARAMETER Help
  Muestra esta ayuda.
#>
[CmdletBinding()]
param([switch]$Help)

$ErrorActionPreference = 'Stop'
if ($Help) { Get-Help $PSCommandPath -Detailed; return }

. (Join-Path $PSScriptRoot 'lib/entorno.ps1')

$detenidos = 0

# 1) Por PID
foreach ($nombre in @('usuarios', 'lecciones', 'progreso', 'frontend')) {
  $procId = Get-PidGuardado $nombre
  if ($null -ne $procId -and (Test-ProcesoVivo $procId)) {
    Stop-Arbol -Raices @($procId)
    Write-Host "  $nombre detenido (PID $procId)."
    $detenidos++
  }
  Remove-Item -Path (Join-Path $script:Logs "$nombre.pid") -ErrorAction SilentlyContinue
}

Start-Sleep -Seconds 1

# 2) Respaldo por puerto (solo estos puertos y solo procesos de desarrollo)
$permitidos = @('python', 'python3', 'pythonw', 'uvicorn', 'node', 'uv', 'npm')
foreach ($puerto in @(8001, 8002, 8003, 5173)) {
  foreach ($procId in (Get-PidsEnPuerto $puerto)) {
    $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
    $nombre = if ($p) { $p.ProcessName } else { '?' }
    if ($permitidos -contains $nombre.ToLowerInvariant()) {
      Stop-Arbol -Raices @($procId)
      Write-Host "  puerto ${puerto}: proceso $nombre (PID $procId) detenido."
      $detenidos++
    } else {
      [Console]::Error.WriteLine("  puerto ${puerto}: lo usa '$nombre' (PID $procId), no es de ConsultaYa; no se toca.")
    }
  }
}

if ($detenidos -eq 0) { Write-Host 'No había nada que detener.' } else { Write-Host 'Listo.' }
exit 0
