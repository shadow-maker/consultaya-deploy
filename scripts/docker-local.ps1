<#
.SYNOPSIS
  Modo Docker local (paridad con la EC2): nginx en http://localhost:8080. Equivale a scripts/docker-local.sh.
.DESCRIPTION
  Uso: scripts\docker-local.ps1 <up|seed|status|down> [opciones]
    up      genera env\local\*.env desde consultaya-deploy\.env, compila el frontend si falta dist\ y
            levanta nginx + usuarios + lecciones + progreso en http://localhost:8080
    seed    corre los seeds dentro de los contenedores (lecciones, usuarios, progreso)
    status  docker compose ps + /health de cada servicio vía nginx
    down    detiene y elimina los contenedores (el volumen del plan B se conserva)
  Configuración: lee consultaya-deploy\.env (copia .env.example a .env). Nunca se modifica la
  configuración de tu PostgreSQL.
.PARAMETER Comando
  up, seed, status o down.
.PARAMETER Db
  host (PostgreSQL de tu máquina vía host.docker.internal), container (plan B: PostgreSQL en contenedor,
  puerto 55432, usuario/contraseña "consultaya") o auto (por defecto: prueba tu PostgreSQL y, si
  falla, usa el plan B y lo avisa).
.PARAMETER BuildFront
  Fuerza `npm run build` del frontend.
.PARAMETER NoSeed
  No corre los seeds al terminar `up`.
.PARAMETER Volumes
  Con `down`: además borra el volumen del PostgreSQL del plan B (solo bases consultaya_*).
.PARAMETER Help
  Muestra esta ayuda.
#>
# Sin [CmdletBinding()] ni [Parameter()]: así el script no es una función "avanzada" y PowerShell no
# agrega los parámetros comunes. De lo contrario -Debug tendría el alias "db" y chocaría con -Db.
param(
  [string]$Comando,
  [ValidateSet('host', 'container', 'auto')][string]$Db = 'auto',
  [switch]$BuildFront,
  [switch]$NoSeed,
  [switch]$Volumes,
  [switch]$Help
)

$ErrorActionPreference = 'Stop'
if ($Help) { Get-Help $PSCommandPath -Detailed; return }
if (@('up', 'seed', 'status', 'down') -notcontains $Comando) {
  [Console]::Error.WriteLine('Comando desconocido o ausente. Usa: up, seed, status o down (o -Help).')
  exit 2
}

. (Join-Path $PSScriptRoot 'lib/entorno.ps1')

$Url = 'http://localhost:8080'
$FrontDir = Join-Path $script:Workspace 'consultaya-frontend'
$Base = @('-f', 'docker-compose.yml', '-f', 'docker-compose.local.yml')
$PlanB = @('-f', 'docker-compose.localdb.yml')
$ModoArchivo = Join-Path $script:Logs 'docker-db-mode'

function Get-ArchivosCompose {
  $f = @() + $Base
  if ((Test-Path $ModoArchivo) -and ((Get-Content $ModoArchivo -Raw).Trim() -eq 'container')) { $f += $PlanB }
  return $f
}

function Invoke-Compose([string[]]$Archivos, [string[]]$Argumentos) {
  & docker compose @Archivos @Argumentos
  if ($LASTEXITCODE -ne 0) { throw "Falló: docker compose $($Argumentos -join ' ')" }
}

function Wait-Servicio([string]$Ruta, [string]$Etiqueta) {
  for ($i = 0; $i -lt 60; $i++) {
    if (Test-Health $Ruta) { Write-Host "  $Etiqueta OK"; return }
    Start-Sleep -Seconds 2
  }
  throw "$Etiqueta no respondió: $Ruta"
}

function Invoke-Seeds {
  Write-Host '==> Seeds'
  $archivos = Get-ArchivosCompose
  Invoke-Compose $archivos @('exec', '-T', 'lecciones', 'python', 'scripts/seed.py')
  Invoke-Compose $archivos @('exec', '-T', 'usuarios', 'python', 'scripts/seed_demo.py')
  Invoke-Compose $archivos @('exec', '-T', 'progreso', 'python', 'scripts/seed_demo.py')
}

$rc = 0
Push-Location $script:DeployDir
try {
  New-Item -ItemType Directory -Force -Path $script:Logs | Out-Null
  switch ($Comando) {
    'up' {
      Import-EntornoDeploy
      Write-Host '==> env/local/*.env (generados desde consultaya-deploy\.env)'
      foreach ($svc in @('usuarios', 'lecciones', 'progreso')) {
        New-EnvServicio -Ejemplo (Join-Path $script:DeployDir "env/local/$svc.env.example") `
          -Destino (Join-Path $script:DeployDir "env/local/$svc.env") -Svc $svc -DbHost 'host.docker.internal' -SinTest
        Write-Host "  generado env/local/$svc.env"
      }

      $modo = $Db
      Write-Host "==> Conexión de un contenedor a tu PostgreSQL (host.docker.internal:$($script:Cfg['DB_PORT']))"
      if ($modo -eq 'auto' -or $modo -eq 'host') {
        # PGPASSWORD (si hay) se pasa por nombre: el valor no se imprime.
        $r = Invoke-Nativo 'docker' @('run', '--rm', '-e', 'PGPASSWORD', 'postgres:18-alpine', 'psql', '-h', 'host.docker.internal',
          '-p', $script:Cfg['DB_PORT'], '-U', $script:Cfg['DB_USER'], '-d', 'postgres', '-Atc', 'select 1')
        if ($r.Codigo -eq 0) {
          Write-Host '  OK: los contenedores llegan a tu PostgreSQL.'
          $modo = 'host'
        } else {
          [Console]::Error.WriteLine('  FALLÓ:')
          foreach ($l in ($r.Salida -split "`n")) { [Console]::Error.WriteLine("    $l") }
          if ($modo -eq 'host') {
            [Console]::Error.WriteLine('  No se toca la configuración de PostgreSQL. Usa -Db container (plan B).')
            throw 'Sin conexión de los contenedores a tu PostgreSQL.'
          }
          [Console]::Error.WriteLine('  AVISO: se usa el plan B (PostgreSQL en contenedor, puerto 55432). No se cambió tu PostgreSQL.')
          $modo = 'container'
        }
      }
      Set-Content -Path $ModoArchivo -Value $modo -Encoding ASCII

      if ($modo -eq 'host') { & (Join-Path $PSScriptRoot 'db-local-init.ps1'); if ($LASTEXITCODE -ne 0) { throw 'db-local-init.ps1 falló.' } }

      if ($BuildFront -or -not (Test-Path (Join-Path $FrontDir 'dist/index.html'))) {
        Write-Host '==> Build del frontend'
        if (-not (Test-Path (Join-Path $FrontDir 'package.json'))) { throw 'consultaya-frontend no tiene package.json todavía.' }
        Push-Location $FrontDir
        try {
          if (-not (Test-Path 'node_modules')) { & npm install --no-audit --no-fund; if ($LASTEXITCODE -ne 0) { throw 'npm install falló.' } }
          & npm run build
          if ($LASTEXITCODE -ne 0) { throw 'npm run build falló.' }
        } finally { Pop-Location }
      }

      Write-Host "==> docker compose up (db: $modo)"
      Invoke-Compose (Get-ArchivosCompose) @('up', '-d', '--build')

      Write-Host '==> Esperando servicios'
      Wait-Servicio "$Url/health" 'gateway'
      foreach ($svc in @('usuarios', 'lecciones', 'progreso')) { Wait-Servicio "$Url/api/$svc/health" $svc }

      if (-not $NoSeed) { Invoke-Seeds }
      Write-Host "Listo: $Url   (demo@consultaya.pe / demo1234)"
    }
    'seed' { Invoke-Seeds }
    'status' {
      Invoke-Compose (Get-ArchivosCompose) @('ps')
      foreach ($ruta in @('health', 'api/usuarios/health', 'api/lecciones/health', 'api/progreso/health')) {
        $t = Get-RespuestaCorta "$Url/$ruta"
        if ($null -eq $t) { $t = 'sin respuesta' }
        Write-Host ('  {0,-24} {1}' -f "/$ruta", $t)
      }
    }
    'down' {
      $args2 = @('down', '--remove-orphans')
      if ($Volumes) { $args2 += '--volumes' }
      # Con ambos compose para que también baje el PostgreSQL del plan B si estuvo activo.
      Invoke-Compose ($Base + $PlanB) $args2
      Remove-Item -Path $ModoArchivo -ErrorAction SilentlyContinue
    }
  }
} catch {
  [Console]::Error.WriteLine($_.Exception.Message)
  $rc = 1
} finally {
  Pop-Location
}
exit $rc
