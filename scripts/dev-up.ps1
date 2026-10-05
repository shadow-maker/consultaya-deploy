<#
.SYNOPSIS
  Levanta ConsultaYa en modo nativo (Windows PowerShell 5.1 / PowerShell 7): bases, migraciones,
  seeds, 3 servicios y Vite. Equivale a scripts/dev-up.sh.
.DESCRIPTION
  0. Exige consultaya-deploy\.env (copia .env.example a .env y ajusta tu usuario y contraseña de
     PostgreSQL); si falta, aborta con instrucciones.
  1. db-local-init.ps1 (crea las bases consultaya_* que falten).
  2. Por servicio: si no tiene .env lo genera desde su .env.example con los datos de deploy\.env
     (si ya existe, NO se toca); uv sync + alembic upgrade head
     (usuarios 8001, lecciones 8002, progreso 8003).
  3. Seeds: lecciones (seed.py), usuarios y progreso (seed_demo.py).
  4. uvicorn de cada servicio (por defecto en segundo plano; logs y PIDs en .logs\).
  5. Espera a que cada /health responda.
  6. Vite en 5173 (VITE_BACKEND=native), salvo con -NoFront.
  7. Imprime las URLs.
  Con -Foreground los 3 uvicorn (con --reload) y Vite quedan atados a la terminal: su salida se ve
  en vivo con un prefijo por servicio ([usuarios], [lecciones]...) y se sigue escribiendo en
  .logs\<servicio>.log. Ctrl+C detiene los 4 procesos y todos sus hijos (taskkill /T /F) y borra los
  .pid. Si un servicio muere solo, se avisa con su nombre y código de salida y se detienen los demás.
  Si los puertos 8001/8002/8003/5173 ya están ocupados, aborta y sugiere scripts\dev-down.ps1.
  Detener (segundo plano): scripts\dev-down.ps1   Estado: scripts\dev-status.ps1
.PARAMETER Foreground
  Procesos atados a la terminal (Ctrl+C los detiene).
.PARAMETER NoSeed
  No corre los seeds.
.PARAMETER NoFront
  No arranca el frontend.
.PARAMETER Help
  Muestra esta ayuda.
#>
[CmdletBinding()]
param(
  [switch]$Foreground,
  [switch]$NoSeed,
  [switch]$NoFront,
  [switch]$Help
)

$ErrorActionPreference = 'Stop'
if ($Help) { Get-Help $PSCommandPath -Detailed; return }

. (Join-Path $PSScriptRoot 'lib/entorno.ps1')

$Servicios = @(
  @{ Nombre = 'usuarios'; Puerto = 8001 },
  @{ Nombre = 'lecciones'; Puerto = 8002 },
  @{ Nombre = 'progreso'; Puerto = 8003 }
)
$Colores = @{ usuarios = 'Cyan'; lecciones = 'Magenta'; progreso = 'Yellow'; frontend = 'Green' }
$FrontDir = Join-Path $script:Workspace 'consultaya-frontend'

# Procesos arrancados por este script (para -Foreground).
$Procs = New-Object System.Collections.ArrayList   # @{ Nombre; Proc; Log; Pos; Resto; Puerto }
$Hijos = New-Object System.Collections.Generic.List[int]
$global:CY_FG_PIDS = @()
$global:CY_FG_HIJOS = @()

function Test-RepoListo([string]$Svc) { Test-Path (Join-Path $script:Workspace "consultaya-$Svc/pyproject.toml") }

function Invoke-EnDir([string]$Dir, [string[]]$Argumentos) {
  Push-Location $Dir
  try {
    & $script:Uv @Argumentos
    if ($LASTEXITCODE -ne 0) { throw "Falló: uv $($Argumentos -join ' ') (en $Dir)" }
  } finally { Pop-Location }
}

function Register-Hijos {
  foreach ($e in $Procs) {
    foreach ($d in (Get-Descendientes $e.Proc.Id)) { if (-not $Hijos.Contains($d)) { $Hijos.Add($d) } }
  }
  $global:CY_FG_HIJOS = $Hijos.ToArray()
}

function Show-LogNuevo($e) {
  if (-not (Test-Path $e.Log)) { return }
  $fs = [System.IO.File]::Open($e.Log, 'Open', 'Read', 'ReadWrite')
  try {
    if ($fs.Length -lt $e.Pos) { $e.Pos = 0 }
    [void]$fs.Seek($e.Pos, 'Begin')
    $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
    $texto = $sr.ReadToEnd()
    $e.Pos = $fs.Position
  } finally { $fs.Dispose() }
  $partes = ($e.Resto + $texto) -split "`r?`n"
  $e.Resto = $partes[$partes.Count - 1]
  for ($i = 0; $i -lt $partes.Count - 1; $i++) {
    Write-Host "[$($e.Nombre)] " -ForegroundColor $Colores[$e.Nombre] -NoNewline
    Write-Host $partes[$i]
  }
}

# Muestra lo nuevo de los logs y falla si algún proceso murió solo.
function Test-Procesos {
  if (-not $Foreground) { return }
  Register-Hijos
  foreach ($e in $Procs) {
    Show-LogNuevo $e
    if ($e.Proc.HasExited) {
      Start-Sleep -Milliseconds 300
      Show-LogNuevo $e
      throw "$($e.Nombre) terminó por su cuenta (código de salida $($e.Proc.ExitCode)). Deteniendo los demás. Revisa $($e.Log)"
    }
  }
}

function Wait-Url([string]$Url, [string]$Etiqueta, [int]$Segundos = 60) {
  for ($i = 0; $i -lt $Segundos; $i++) {
    if (Test-Health $Url) { Write-Linea "  $Etiqueta listo."; return }
    Test-Procesos
    Start-Sleep -Seconds 1
  }
  throw "$Etiqueta no respondió en ${Segundos}s. Revisa los logs en $($script:Logs)"
}

function Start-Servicio([string]$Nombre, [int]$Puerto, [string]$Dir, [string]$Url, [string]$Linea) {
  if (-not $Foreground -and (Test-Health $Url)) {
    Write-Linea "  $Nombre ya responde en el puerto $Puerto; no se vuelve a arrancar."
    return
  }
  if (Test-PuertoEnUso $Puerto) {
    throw "El puerto $Puerto está ocupado por otro proceso y $Nombre no responde. Libéralo o usa scripts\dev-down.ps1."
  }
  $log = Join-Path $script:Logs "$Nombre.log"
  $proc = Start-Desacoplado $Dir $Linea $log
  $null = $proc.Handle   # en Windows PowerShell 5.1 permite leer ExitCode después
  Save-Pid $Nombre $proc.Id
  $null = $Procs.Add(@{ Nombre = $Nombre; Proc = $proc; Log = $log; Pos = 0; Resto = ''; Puerto = $Puerto })
  $global:CY_FG_PIDS = @($Procs | ForEach-Object { $_.Proc.Id })
  Write-Linea "  $Nombre arrancando (PID $($proc.Id), puerto $Puerto)."
}

function Stop-Todo {
  if (-not $Foreground -or $Procs.Count -eq 0) { return }
  Write-Host ''
  Write-Host '==> Deteniendo servicios (y sus procesos hijos)...'
  Register-Hijos
  Stop-Arbol -Raices @($Procs | ForEach-Object { $_.Proc.Id }) -Extra $Hijos.ToArray()
  foreach ($e in $Procs) {
    Remove-Item -Path (Join-Path $script:Logs "$($e.Nombre).pid") -ErrorAction SilentlyContinue
    if (Test-PuertoEnUso $e.Puerto) { Write-Aviso "el puerto $($e.Puerto) sigue ocupado (otro proceso lo usa)." }
  }
  $Procs.Clear()
  Write-Host '  Detenido.'
}

$rc = 0
$cierre = $null
try {
  New-Item -ItemType Directory -Force -Path $script:Logs | Out-Null

  # 0) Configuración local: consultaya-deploy\.env
  Import-EntornoDeploy

  # uv
  $script:Uv = Resolve-Uv
  Write-Linea "  uv: $($script:Uv)"

  # En primer plano: abortar si los puertos ya están ocupados (p. ej. por un dev-up en segundo plano).
  if ($Foreground) {
    $ocupados = @()
    foreach ($s in $Servicios) { if ((Test-RepoListo $s.Nombre) -and (Test-PuertoEnUso $s.Puerto)) { $ocupados += $s.Puerto } }
    if (-not $NoFront -and (Test-Path (Join-Path $FrontDir 'package.json')) -and (Test-PuertoEnUso 5173)) { $ocupados += 5173 }
    if ($ocupados.Count -gt 0) {
      throw ("ya hay procesos escuchando en los puertos: $($ocupados -join ' ').`n" +
        '         Si son de un dev-up anterior, ejecuta primero: scripts\dev-down.ps1')
    }
    # Mejor esfuerzo: si la consola se cierra, detener también los procesos.
    $cierre = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
      $todos = @($global:CY_FG_HIJOS) + @($global:CY_FG_PIDS)
      foreach ($p in $todos) {
        if (-not (Get-Process -Id $p -ErrorAction SilentlyContinue)) { continue }
        if ($env:OS -eq 'Windows_NT') { & taskkill.exe /PID $p /T /F *> $null } else { & kill -TERM $p 2>$null }
      }
    }
  }

  # 1) Bases
  Write-Paso 'Bases de datos locales'
  & (Join-Path $PSScriptRoot 'db-local-init.ps1')
  if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) { throw 'db-local-init.ps1 falló.' }

  # 2) Dependencias y migraciones
  Write-Paso 'Dependencias y migraciones'
  $activos = @()
  foreach ($s in $Servicios) {
    $svc = $s.Nombre
    $dir = Join-Path $script:Workspace "consultaya-$svc"
    if (-not (Test-RepoListo $svc)) { Write-Aviso "consultaya-$svc todavía no tiene código (falta pyproject.toml); se omite."; continue }
    $activos += $s
    Write-Linea "-- $svc"
    # Si el servicio no tiene .env se genera desde su .env.example con los datos de deploy\.env.
    # Si ya existe NO se toca.
    $envSvc = Join-Path $dir '.env'
    $ejemplo = Join-Path $dir '.env.example'
    if (-not (Test-Path $envSvc)) {
      if (Test-Path $ejemplo) {
        New-EnvServicio -Ejemplo $ejemplo -Destino $envSvc -Svc $svc -DbHost $script:Cfg['DB_HOST']
        Write-Linea '  .env generado desde .env.example (con los datos de consultaya-deploy\.env)'
      } else { Write-Aviso "consultaya-$svc no tiene .env ni .env.example." }
    }
    Invoke-EnDir $dir @('sync')
    Invoke-EnDir $dir @('run', 'alembic', 'upgrade', 'head')
  }

  # 3) Seeds
  if (-not $NoSeed) {
    Write-Paso 'Seeds'
    foreach ($par in @(@('lecciones', 'seed.py'), @('usuarios', 'seed_demo.py'), @('progreso', 'seed_demo.py'))) {
      $svc = $par[0]; $archivoSeed = $par[1]
      if (-not (Test-RepoListo $svc)) { continue }
      $dir = Join-Path $script:Workspace "consultaya-$svc"
      if (Test-Path (Join-Path $dir "scripts/$archivoSeed")) {
        Write-Linea "-- ${svc}: $archivoSeed"
        Invoke-EnDir $dir @('run', 'python', "scripts/$archivoSeed")
      } else { Write-Aviso "consultaya-$svc no tiene scripts/$archivoSeed todavía; se omite." }
    }
  } else { Write-Paso 'Seeds omitidos (-NoSeed)' }

  # 4) Servicios
  Write-Paso 'Servicios'
  $uvCita = Get-Cita $script:Uv
  $extra = ''
  if ($Foreground) { $extra = ' --reload --reload-dir app' }
  foreach ($s in $activos) {
    $linea = "$uvCita run --no-sync uvicorn app.main:app --host 127.0.0.1 --port $($s.Puerto)$extra"
    Start-Servicio $s.Nombre $s.Puerto (Join-Path $script:Workspace "consultaya-$($s.Nombre)") "http://localhost:$($s.Puerto)/health" $linea
  }

  # 5) Health
  Write-Paso 'Esperando /health'
  foreach ($s in $activos) { Wait-Url "http://localhost:$($s.Puerto)/health" $s.Nombre 60 }

  # 6) Frontend
  $front = -not $NoFront
  if ($front) {
    Write-Paso 'Frontend (Vite)'
    if (-not (Test-Path (Join-Path $FrontDir 'package.json'))) {
      Write-Aviso 'consultaya-frontend todavía no tiene package.json; se omite.'
      $front = $false
    } else {
      if (-not (Test-Path (Join-Path $FrontDir 'node_modules'))) {
        Push-Location $FrontDir
        try { & npm install --no-audit --no-fund; if ($LASTEXITCODE -ne 0) { throw 'npm install falló.' } } finally { Pop-Location }
      }
      $env:VITE_BACKEND = 'native'
      Start-Servicio 'frontend' 5173 $FrontDir 'http://localhost:5173/' 'npm run dev -- --host 127.0.0.1 --port 5173 --strictPort'
      Wait-Url 'http://localhost:5173/' 'frontend' 60
    }
  }

  # 7) Resumen
  Write-Paso 'Listo'
  foreach ($s in $activos) { Write-Linea "  $($s.Nombre): http://localhost:$($s.Puerto)/api/$($s.Nombre)/docs" }
  if ($front) {
    Write-Linea '  Aplicación: http://localhost:5173'
    Write-Linea '  Cuenta demo: demo@consultaya.pe / demo1234'
  }
  Write-Linea "  Logs: $($script:Logs)   Estado: scripts\dev-status.ps1   Detener: scripts\dev-down.ps1"

  if ($Foreground) {
    if ($Procs.Count -eq 0) { Write-Linea '  No se arrancó ningún proceso; nada que mantener en primer plano.' }
    else {
      Write-Host ''
      Write-Linea '  Modo en primer plano: Ctrl+C detiene todo. Salida en vivo abajo (también en .logs\).'
      while ($true) { Test-Procesos; Start-Sleep -Milliseconds 500 }
    }
  }
} catch {
  [Console]::Error.WriteLine("[dev-up] ERROR: $($_.Exception.Message)")
  $rc = 1
} finally {
  Stop-Todo
  if ($cierre) { Unregister-Event -SourceIdentifier PowerShell.Exiting -ErrorAction SilentlyContinue }
}
exit $rc
