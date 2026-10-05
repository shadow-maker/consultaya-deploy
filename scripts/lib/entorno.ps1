# Funciones comunes de los scripts de PowerShell (se carga con `. "$PSScriptRoot\lib\entorno.ps1"`).
# Compatible con Windows PowerShell 5.1 y PowerShell 7 (Windows, macOS y Linux).
# Lee consultaya-deploy\.env (fuente única de la configuración local) y genera los .env de los servicios.

$script:DeployDir = (Resolve-Path (Join-Path (Join-Path $PSScriptRoot '..') '..')).Path
$script:EnvDeploy = Join-Path $script:DeployDir '.env'
$script:Workspace = (Resolve-Path (Join-Path $script:DeployDir '..')).Path
$script:Logs = Join-Path $script:DeployDir '.logs'

function Test-EsWindows { return ($env:OS -eq 'Windows_NT') }

function Write-Linea([string]$Texto) { Write-Host $Texto }
function Write-Aviso([string]$Texto) { [Console]::Error.WriteLine("  [aviso] $Texto") }
function Write-Paso([string]$Texto) { Write-Host ''; Write-Host "==> $Texto" }

# Lee DB_HOST, DB_PORT, DB_USER, DB_PASSWORD y JWT_SECRET. El entorno tiene prioridad sobre el .env.
# El usuario NO se adivina: si falta el .env (y no hay DB_USER en el entorno) se aborta con instrucciones.
function Import-EntornoDeploy {
  $claves = @('DB_HOST', 'DB_PORT', 'DB_USER', 'DB_PASSWORD', 'JWT_SECRET')
  $cfg = @{}
  if (Test-Path $script:EnvDeploy) {
    foreach ($linea in [System.IO.File]::ReadAllLines($script:EnvDeploy)) {
      $l = $linea.TrimEnd("`r")
      if ($l -eq '' -or $l.StartsWith('#')) { continue }
      $i = $l.IndexOf('=')
      if ($i -lt 1) { continue }
      $k = $l.Substring(0, $i)
      $v = $l.Substring($i + 1)
      if ($claves -notcontains $k) { continue }
      if ($v.Length -ge 2 -and (($v.StartsWith('"') -and $v.EndsWith('"')) -or ($v.StartsWith("'") -and $v.EndsWith("'")))) {
        $v = $v.Substring(1, $v.Length - 2)
      }
      $cfg[$k] = $v
    }
  } elseif ([string]::IsNullOrEmpty($env:DB_USER)) {
    throw ("No existe $($script:EnvDeploy).`n" +
      "Copia .env.example a .env y ajusta tu usuario y contraseña de PostgreSQL:`n" +
      "  Copy-Item `"$(Join-Path $script:DeployDir '.env.example')`" `"$($script:EnvDeploy)`"")
  }
  foreach ($k in $claves) {
    $delEntorno = [Environment]::GetEnvironmentVariable($k)
    if (-not [string]::IsNullOrEmpty($delEntorno)) { $cfg[$k] = $delEntorno }
  }
  if (-not $cfg.ContainsKey('DB_USER') -or [string]::IsNullOrEmpty($cfg['DB_USER'])) {
    throw "Falta DB_USER en $($script:EnvDeploy) (usuario de PostgreSQL)."
  }
  if (-not $cfg.ContainsKey('DB_HOST') -or $cfg['DB_HOST'] -eq '') { $cfg['DB_HOST'] = 'localhost' }
  if (-not $cfg.ContainsKey('DB_PORT') -or $cfg['DB_PORT'] -eq '') { $cfg['DB_PORT'] = '5432' }
  if (-not $cfg.ContainsKey('DB_PASSWORD')) { $cfg['DB_PASSWORD'] = '' }
  if (-not $cfg.ContainsKey('JWT_SECRET') -or $cfg['JWT_SECRET'] -eq '') { $cfg['JWT_SECRET'] = 'dev-secret-cambiar' }
  $script:Cfg = $cfg
  # psql usa PGPASSWORD (nunca se imprime).
  if ($cfg['DB_PASSWORD'] -ne '') { $env:PGPASSWORD = $cfg['DB_PASSWORD'] }
}

# Codificación porcentual (RFC 3986, sobre bytes UTF-8) para usuario/contraseña en una URL.
function ConvertTo-UrlCodificado([string]$Texto) {
  $sb = New-Object System.Text.StringBuilder
  foreach ($b in [System.Text.Encoding]::UTF8.GetBytes($Texto)) {
    $c = [char]$b
    if (($b -ge 48 -and $b -le 57) -or ($b -ge 65 -and $b -le 90) -or ($b -ge 97 -and $b -le 122) -or '-._~'.Contains([string]$c)) {
      [void]$sb.Append($c)
    } else {
      [void]$sb.AppendFormat('%{0:X2}', $b)
    }
  }
  return $sb.ToString()
}

function Get-UrlDb([string]$DbHost, [string]$Base) {
  $cred = ConvertTo-UrlCodificado $script:Cfg['DB_USER']
  if ($script:Cfg['DB_PASSWORD'] -ne '') { $cred = $cred + ':' + (ConvertTo-UrlCodificado $script:Cfg['DB_PASSWORD']) }
  return "postgresql+psycopg://$cred@${DbHost}:$($script:Cfg['DB_PORT'])/$Base"
}

# Genera un .env copiando un .env.example y reemplazando SOLO DATABASE_URL, TEST_DATABASE_URL y
# JWT_SECRET (el resto de líneas se conserva). Si falta alguna de las tres, se agrega.
function New-EnvServicio([string]$Ejemplo, [string]$Destino, [string]$Svc, [string]$DbHost, [switch]$SinTest) {
  $url = Get-UrlDb $DbHost "consultaya_$Svc"
  $urlTest = Get-UrlDb $DbHost "consultaya_${Svc}_test"
  $vistos = @{}
  $salida = New-Object System.Collections.Generic.List[string]
  foreach ($linea in [System.IO.File]::ReadAllLines($Ejemplo)) {
    $l = $linea.TrimEnd("`r")
    if ($l.StartsWith('TEST_DATABASE_URL=')) { $salida.Add("TEST_DATABASE_URL=$urlTest"); $vistos['T'] = $true }
    elseif ($l.StartsWith('DATABASE_URL=')) { $salida.Add("DATABASE_URL=$url"); $vistos['D'] = $true }
    elseif ($l.StartsWith('JWT_SECRET=')) { $salida.Add("JWT_SECRET=$($script:Cfg['JWT_SECRET'])"); $vistos['J'] = $true }
    else { $salida.Add($l) }
  }
  if (-not $vistos.ContainsKey('D')) { $salida.Add("DATABASE_URL=$url") }
  if (-not $vistos.ContainsKey('T') -and -not $SinTest) { $salida.Add("TEST_DATABASE_URL=$urlTest") }
  if (-not $vistos.ContainsKey('J')) { $salida.Add("JWT_SECRET=$($script:Cfg['JWT_SECRET'])") }
  $texto = ($salida -join "`n") + "`n"
  [System.IO.File]::WriteAllText($Destino, $texto, (New-Object System.Text.UTF8Encoding($false)))
}

# Ejecuta un programa nativo capturando su salida (stdout+stderr) sin que $ErrorActionPreference='Stop'
# convierta el stderr en excepción (Windows PowerShell 5.1). Devuelve @{ Codigo; Salida }.
function Invoke-Nativo([string]$Exe, [string[]]$Argumentos) {
  $previo = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $salida = & $Exe @Argumentos 2>&1 | ForEach-Object { "$_" }
    $codigo = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previo
  }
  return @{ Codigo = $codigo; Salida = ($salida -join "`n") }
}

# psql: primero el PATH; si no está, ubicaciones habituales de las instalaciones de PostgreSQL.
function Find-Psql {
  $cmd = Get-Command psql -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $candidatos = @()
  if (Test-EsWindows) {
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
      if ($base) { $candidatos += (Get-ChildItem -Path (Join-Path $base 'PostgreSQL\*\bin\psql.exe') -ErrorAction SilentlyContinue | Sort-Object FullName -Descending) }
    }
  } else {
    foreach ($patron in @('/Applications/Postgres.app/Contents/Versions/latest/bin/psql', '/opt/homebrew/opt/postgresql*/bin/psql',
        '/usr/local/opt/postgresql*/bin/psql', '/usr/lib/postgresql/*/bin/psql')) {
      $candidatos += (Get-ChildItem -Path $patron -ErrorAction SilentlyContinue)
    }
  }
  if ($candidatos.Count -gt 0) { return $candidatos[0].FullName }
  return $null
}

# uv: a veces `uv` es un shim (p. ej. de pyenv) que falla dentro de repos con .python-version.
# Se prueba `uv --version` dentro de un repo de servicio y, si falla, se busca un uv real como respaldo.
function Resolve-Uv {
  $probe = Join-Path $script:Workspace 'consultaya-usuarios'
  if (-not (Test-Path $probe)) { $probe = $script:DeployDir }
  $candidatos = @()
  $cmd = Get-Command uv -ErrorAction SilentlyContinue
  if ($cmd) { $candidatos += $cmd.Source }
  if ($env:USERPROFILE) { $candidatos += (Join-Path $env:USERPROFILE '.local\bin\uv.exe'), (Join-Path $env:USERPROFILE '.cargo\bin\uv.exe') }
  if ($env:HOME) {
    $candidatos += (Get-ChildItem -Path (Join-Path $env:HOME '.pyenv/versions/*/bin/uv') -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
  }
  foreach ($c in $candidatos) {
    if (-not (Test-Path $c)) { continue }
    Push-Location $probe
    try { $r = Invoke-Nativo $c @('--version') } finally { Pop-Location }
    if ($r.Codigo -eq 0) { return $c }
  }
  throw 'No se encontró un uv funcional. Instálalo (ver README, "Primeros pasos") y vuelve a intentar.'
}

function Test-PuertoEnUso([int]$Puerto) {
  $oyentes = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
  foreach ($o in $oyentes) { if ($o.Port -eq $Puerto) { return $true } }
  return $false
}

function Get-PidsEnPuerto([int]$Puerto) {
  if (Test-EsWindows) {
    $c = Get-NetTCPConnection -LocalPort $Puerto -State Listen -ErrorAction SilentlyContinue
    if ($c) { return @($c | Select-Object -ExpandProperty OwningProcess -Unique) }
    return @()
  }
  $r = Invoke-Nativo 'lsof' @('-nP', "-tiTCP:$Puerto", '-sTCP:LISTEN')
  if ($r.Codigo -ne 0 -or $r.Salida -eq '') { return @() }
  return @($r.Salida -split "`n" | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })
}

function Test-Health([string]$Url) {
  try {
    $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 2
    return ($r.StatusCode -ge 200 -and $r.StatusCode -lt 300)
  } catch { return $false }
}

function Get-RespuestaCorta([string]$Url) {
  try {
    $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 3
    $t = ([string]$r.Content).Split("`n")[0].Trim()
    if ($t.Length -gt 80) { $t = $t.Substring(0, 80) }
    return $t
  } catch { return $null }
}

# Descendientes (hijos, nietos...) de un proceso.
function Get-Descendientes([int]$ProcId) {
  $res = New-Object System.Collections.Generic.List[int]
  if (Test-EsWindows) {
    $todos = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId -ErrorAction SilentlyContinue)
    $pendientes = New-Object System.Collections.Generic.Queue[int]
    $pendientes.Enqueue($ProcId)
    while ($pendientes.Count -gt 0) {
      $p = $pendientes.Dequeue()
      foreach ($h in ($todos | Where-Object { $_.ParentProcessId -eq $p })) {
        if (-not $res.Contains([int]$h.ProcessId)) { $res.Add([int]$h.ProcessId); $pendientes.Enqueue([int]$h.ProcessId) }
      }
    }
  } else {
    $r = Invoke-Nativo 'pgrep' @('-P', "$ProcId")
    if ($r.Codigo -eq 0 -and $r.Salida -ne '') {
      foreach ($h in ($r.Salida -split "`n" | Where-Object { $_ -match '^\d+$' })) {
        $res.Add([int]$h)
        foreach ($n in (Get-Descendientes ([int]$h))) { if (-not $res.Contains($n)) { $res.Add($n) } }
      }
    }
  }
  return $res.ToArray()
}

function Test-ProcesoVivo([int]$ProcId) {
  return [bool](Get-Process -Id $ProcId -ErrorAction SilentlyContinue)
}

# Detiene procesos y TODO su árbol. Windows: taskkill /T /F. Otros SO: TERM y, si hace falta, KILL.
# $Extra: descendientes ya vistos (si un padre muere, sus hijos quedan huérfanos y ya no cuelgan de él).
function Stop-Arbol([int[]]$Raices, [int[]]$Extra = @()) {
  $todos = New-Object System.Collections.Generic.List[int]
  foreach ($r in $Raices) {
    foreach ($d in (Get-Descendientes $r)) { if (-not $todos.Contains($d)) { $todos.Add($d) } }
  }
  foreach ($e in $Extra) { if (-not $todos.Contains($e)) { $todos.Add($e) } }
  foreach ($r in $Raices) { if (-not $todos.Contains($r)) { $todos.Add($r) } }
  if (Test-EsWindows) {
    foreach ($r in $Raices) { [void](Invoke-Nativo 'taskkill.exe' @('/PID', "$r", '/T', '/F')) }
    foreach ($p in $todos) { if (Test-ProcesoVivo $p) { [void](Invoke-Nativo 'taskkill.exe' @('/PID', "$p", '/F')) } }
    return
  }
  foreach ($p in $todos) { [void](Invoke-Nativo 'kill' @('-TERM', "$p")) }
  for ($i = 0; $i -lt 50; $i++) {
    $vivos = @($todos | Where-Object { Test-ProcesoVivo $_ })
    if ($vivos.Count -eq 0) { return }
    Start-Sleep -Milliseconds 200
  }
  foreach ($p in $todos) { if (Test-ProcesoVivo $p) { [void](Invoke-Nativo 'kill' @('-KILL', "$p")) } }
}

# Arranca un comando en segundo plano, sin ventana, con stdout+stderr en el log. Devuelve el proceso.
function Start-Desacoplado([string]$Dir, [string]$LineaComando, [string]$Log) {
  if (Test-EsWindows) {
    $arg = '/d /s /c "' + $LineaComando + ' > "' + $Log + '" 2>&1"'
    return Start-Process -FilePath $env:ComSpec -ArgumentList $arg -WorkingDirectory $Dir -WindowStyle Hidden -PassThru
  }
  # macOS/Linux (solo PowerShell 7): se usa ProcessStartInfo para que los argumentos no se partan.
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = '/bin/sh'
  $psi.ArgumentList.Add('-c')
  $psi.ArgumentList.Add('exec ' + $LineaComando + ' > "' + $Log + '" 2>&1')
  $psi.WorkingDirectory = $Dir
  $psi.UseShellExecute = $false
  return [System.Diagnostics.Process]::Start($psi)
}

function Get-Cita([string]$Ruta) { return '"' + $Ruta + '"' }

function Save-Pid([string]$Nombre, [int]$ProcId) {
  Set-Content -Path (Join-Path $script:Logs "$Nombre.pid") -Value $ProcId -Encoding ASCII
}

function Get-PidGuardado([string]$Nombre) {
  $f = Join-Path $script:Logs "$Nombre.pid"
  if (-not (Test-Path $f)) { return $null }
  $t = (Get-Content -Path $f -ErrorAction SilentlyContinue | Select-Object -First 1)
  if ($t -match '^\d+$') { return [int]$t }
  return $null
}
