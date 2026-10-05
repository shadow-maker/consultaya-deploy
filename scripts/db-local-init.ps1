<#
.SYNOPSIS
  Crea las 6 bases locales de ConsultaYa si no existen (idempotente; NUNCA borra nada).
  Equivale a scripts/db-local-init.sh.
.DESCRIPTION
  Bases: consultaya_usuarios, consultaya_lecciones, consultaya_progreso y sus _test.
  Imprime qué creó y qué ya existía. No toca ninguna otra base.
  Conexión: lee DB_HOST, DB_PORT, DB_USER y DB_PASSWORD de consultaya-deploy\.env (copia
  .env.example a .env). Las variables de entorno con esos nombres tienen prioridad
  (por ejemplo: $env:DB_PORT = 55432). Si hay contraseña se pasa a psql con PGPASSWORD y nunca se imprime.
.PARAMETER Help
  Muestra esta ayuda.
#>
[CmdletBinding()]
param([switch]$Help)

$ErrorActionPreference = 'Stop'
if ($Help) { Get-Help $PSCommandPath -Detailed; return }

. (Join-Path $PSScriptRoot 'lib/entorno.ps1')

$rc = 0
try {
  Import-EntornoDeploy
  $psql = Find-Psql
  if (-not $psql) { throw 'No se encontró psql. Instala el cliente de PostgreSQL (ver README) o agrégalo al PATH.' }

  $bases = @('consultaya_usuarios', 'consultaya_usuarios_test', 'consultaya_lecciones', 'consultaya_lecciones_test',
    'consultaya_progreso', 'consultaya_progreso_test')
  $dbHost = $script:Cfg['DB_HOST']; $dbPort = $script:Cfg['DB_PORT']; $dbUser = $script:Cfg['DB_USER']

  function Invoke-Psql([string]$Sql) {
    $r = Invoke-Nativo $psql @('-h', $dbHost, '-p', $dbPort, '-U', $dbUser, '-d', 'postgres', '-v', 'ON_ERROR_STOP=1', '-X', '-A', '-t', '-q', '-c', $Sql)
    return $r
  }

  $r = Invoke-Psql 'select 1'
  if ($r.Codigo -ne 0) {
    [Console]::Error.WriteLine("No se pudo conectar a PostgreSQL en ${dbHost}:$dbPort como $dbUser.")
    [Console]::Error.WriteLine('Revisa DB_HOST, DB_PORT, DB_USER y DB_PASSWORD en consultaya-deploy\.env.')
    if ($r.Salida) { [Console]::Error.WriteLine($r.Salida) }
    exit 1
  }

  $creadas = 0; $existentes = 0
  foreach ($base in $bases) {
    # Guardia: este script solo maneja bases consultaya_*.
    if (-not $base.StartsWith('consultaya_')) { throw "Base no permitida: $base" }
    $r = Invoke-Psql "select 1 from pg_database where datname = '$base'"
    if ($r.Codigo -ne 0) { throw "Falló la consulta de $base`: $($r.Salida)" }
    if ($r.Salida.Trim() -eq '1') {
      Write-Host "  ya existía: $base"; $existentes++
    } else {
      $c = Invoke-Psql "CREATE DATABASE $base"
      if ($c.Codigo -ne 0) { throw "No se pudo crear ${base}: $($c.Salida)" }
      Write-Host "  creada:     $base"; $creadas++
    }
  }
  Write-Host "Bases consultaya_*: $creadas creada(s), $existentes ya existía(n)."
} catch {
  [Console]::Error.WriteLine($_.Exception.Message)
  $rc = 1
}
exit $rc
