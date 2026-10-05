#!/usr/bin/env bash
# Levanta ConsultaYa en modo nativo: bases, migraciones, seeds, 3 servicios y Vite.
# Por defecto en segundo plano; con --foreground, atado a la terminal (Ctrl+C lo detiene todo).
set -euo pipefail

uso() {
  cat <<'AYUDA'
Uso: scripts/dev-up.sh [--foreground] [--no-seed] [--no-front] [--help]

En orden:
  0. exige consultaya-deploy/.env (copia .env.example a .env y ajusta tu usuario y contraseña
     de PostgreSQL); si falta, aborta con instrucciones
  1. db-local-init.sh (crea las bases consultaya_* que falten)
  2. por servicio: si no tiene .env, lo genera desde su .env.example con los datos de
     deploy/.env (si ya existe, no se toca); uv sync + alembic upgrade head
     (usuarios 8001, lecciones 8002, progreso 8003)
  3. seeds: lecciones (seed.py), usuarios y progreso (seed_demo.py)
  4. uvicorn de cada servicio (por defecto en segundo plano; logs y PIDs en .logs/)
  5. espera a que cada /health responda
  6. Vite en 5173 (VITE_BACKEND=native), salvo con --no-front
  7. imprime las URLs

Opciones:
  --foreground  los 3 uvicorn (con --reload) y Vite quedan atados a la terminal: su salida
                se ve en vivo con un prefijo por servicio ([usuarios], [lecciones], ...,
                con color si la terminal lo soporta) y se sigue escribiendo en .logs/<servicio>.log.
                Ctrl+C (SIGINT), SIGTERM o cerrar la terminal (SIGHUP) detienen los 4
                procesos y sus hijos (solo los que arrancó este script) y borran los .pid.
                Si un servicio muere solo, se avisa con su nombre y código de salida y se
                detienen los demás. Si los puertos 8001/8002/8003/5173 ya están ocupados,
                aborta y sugiere scripts/dev-down.sh.
  --no-seed     no corre los seeds
  --no-front    no arranca el frontend
Detener (modo segundo plano): scripts/dev-down.sh   Estado: scripts/dev-status.sh
Si un repo o un script de seed aún no existe, se avisa y se continúa.
AYUDA
}

SEED=1
FRONT=1
FOREGROUND=0
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) uso; exit 0 ;;
    --foreground) FOREGROUND=1 ;;
    --no-seed) SEED=0 ;;
    --no-front) FRONT=0 ;;
    *) echo "Opción desconocida: $1" >&2; uso >&2; exit 2 ;;
  esac
  shift
done

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
WORKSPACE="$(cd "$DEPLOY_DIR/.." && pwd)"
LOGS="$DEPLOY_DIR/.logs"
mkdir -p "$LOGS"

# Configuración local: consultaya-deploy/.env (DB_HOST, DB_PORT, DB_USER, DB_PASSWORD, JWT_SECRET).
# shellcheck source=lib/entorno.sh
source "$SCRIPTS_DIR/lib/entorno.sh"
entorno_cargar || exit 1

# servicio:puerto
SERVICIOS=("usuarios:8001" "lecciones:8002" "progreso:8003")

log()  { printf '\n==> %s\n' "$*"; }
aviso(){ printf '  [aviso] %s\n' "$*" >&2; }

repo_listo() { # directorio con pyproject.toml
  [ -f "$WORKSPACE/consultaya-$1/pyproject.toml" ]
}

puerto_en_uso() { lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }

esperar_url() { # url etiqueta segundos
  local url="$1" etiqueta="$2" max="${3:-60}" i=0
  until curl -fsS --max-time 2 "$url" >/dev/null 2>&1; do
    if [ "$FOREGROUND" = "1" ]; then fg_verificar; fi
    i=$((i + 1))
    if [ "$i" -ge "$max" ]; then
      echo "  $etiqueta no respondió en ${max}s. Revisa los logs en $LOGS/" >&2
      return 1
    fi
    sleep 1
  done
  echo "  $etiqueta listo."
}

arrancar() { # etiqueta puerto directorio url-health comando...
  local etiqueta="$1" puerto="$2" dir="$3" url="$4"
  shift 4
  if [ "$FOREGROUND" = "1" ]; then
    arrancar_fg "$etiqueta" "$puerto" "$dir" "$@"
    return 0
  fi
  if curl -fsS --max-time 2 "$url" >/dev/null 2>&1; then
    echo "  $etiqueta ya responde en el puerto $puerto; no se vuelve a arrancar."
    return 0
  fi
  if puerto_en_uso "$puerto"; then
    echo "  El puerto $puerto está ocupado por otro proceso y $etiqueta no responde. Libéralo o usa scripts/dev-down.sh." >&2
    return 1
  fi
  (
    cd "$dir"
    nohup "$@" >"$LOGS/$etiqueta.log" 2>&1 &
    echo $! >"$LOGS/$etiqueta.pid"
  )
  echo "  $etiqueta arrancando (PID $(cat "$LOGS/$etiqueta.pid"), puerto $puerto)."
}


# ---------------------------------------------------------------------------
# Modo --foreground: procesos atados a la terminal, con prefijo por servicio.
# ---------------------------------------------------------------------------
FG_NOMBRES=()
FG_PIDS=()
FG_PUERTOS=()
FG_HIJOS=()   # descendientes ya vistos (si un padre muere, sus hijos quedan huérfanos y pgrep -P ya no los ve)

prefijo() { # etiqueta -> "[etiqueta] " (con color si la terminal lo soporta)
  local codigo=""
  if [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ] && [ -z "${NO_COLOR:-}" ]; then
    case "$1" in
      usuarios) codigo=36 ;; lecciones) codigo=35 ;; progreso) codigo=33 ;; *) codigo=32 ;;
    esac
  fi
  if [ -n "$codigo" ]; then printf '\033[%sm[%s]\033[0m ' "$codigo" "$1"; else printf '[%s] ' "$1"; fi
}

arrancar_fg() { # etiqueta puerto directorio comando...
  local etiqueta="$1" puerto="$2" dir="$3" pfx pid
  shift 3
  pfx="$(prefijo "$etiqueta")"
  ( cd "$dir" && exec "$@" ) \
    > >(tee "$LOGS/$etiqueta.log" | awk -v p="$pfx" '{ print p $0; fflush() }') 2>&1 &
  pid=$!
  echo "$pid" >"$LOGS/$etiqueta.pid"
  FG_NOMBRES+=("$etiqueta"); FG_PIDS+=("$pid"); FG_PUERTOS+=("$puerto")
  echo "  $etiqueta arrancando en primer plano (PID $pid, puerto $puerto)."
}

# Si algún proceso arrancado murió solo: avisa con nombre y código, y sale (el trap detiene el resto).
fg_registrar_hijos() {
  local pid p
  for pid in "${FG_PIDS[@]}"; do
    for p in $(descendientes "$pid"); do
      case " ${FG_HIJOS[*]:-} " in *" $p "*) ;; *) FG_HIJOS+=("$p") ;; esac
    done
  done
}

fg_verificar() {
  local i code
  fg_registrar_hijos
  for i in "${!FG_PIDS[@]}"; do
    if ! kill -0 "${FG_PIDS[$i]}" 2>/dev/null; then
      code=0
      wait "${FG_PIDS[$i]}" 2>/dev/null || code=$?
      printf '\n[dev-up] ERROR: %s terminó por su cuenta (código de salida %s). Deteniendo los demás. Revisa %s/%s.log\n' \
        "${FG_NOMBRES[$i]}" "$code" "$LOGS" "${FG_NOMBRES[$i]}" >&2
      exit 1
    fi
  done
}

descendientes() { # pid -> pids de todos sus descendientes
  local h
  for h in $(pgrep -P "$1" 2>/dev/null || true); do
    echo "$h"
    descendientes "$h"
  done
}

fg_limpiar() {
  local rc=$? pid p i vivos
  trap - EXIT INT TERM HUP
  if [ "$FOREGROUND" != "1" ] || [ "${#FG_PIDS[@]}" -eq 0 ]; then return "$rc"; fi
  printf '\n==> Deteniendo servicios (y sus procesos hijos)...\n'
  fg_registrar_hijos
  local todos=("${FG_HIJOS[@]:-}")
  for pid in "${FG_PIDS[@]}"; do todos+=("$pid"); done
  kill -TERM "${todos[@]}" 2>/dev/null || true
  for i in $(seq 1 50); do
    vivos=0
    for p in "${todos[@]}"; do if kill -0 "$p" 2>/dev/null; then vivos=1; break; fi; done
    [ "$vivos" = "0" ] && break
    sleep 0.2
  done
  if [ "$vivos" = "1" ]; then
    kill -KILL "${todos[@]}" 2>/dev/null || true
    sleep 0.5
  fi
  for i in "${!FG_NOMBRES[@]}"; do
    rm -f "$LOGS/${FG_NOMBRES[$i]}.pid"
    if puerto_en_uso "${FG_PUERTOS[$i]}"; then
      aviso "el puerto ${FG_PUERTOS[$i]} sigue ocupado (otro proceso lo usa)."
    fi
  done
  echo "  Detenido."
  return "$rc"
}

# Aborta si algo ya escucha en los puertos que se van a usar (p. ej. un dev-up.sh en segundo plano).
fg_verificar_puertos() {
  local item puerto ocupados=()
  for item in "${SERVICIOS[@]}"; do
    repo_listo "${item%%:*}" || continue
    puerto="${item##*:}"
    if puerto_en_uso "$puerto"; then ocupados+=("$puerto"); fi
  done
  if [ "$FRONT" = "1" ] && [ -f "$WORKSPACE/consultaya-frontend/package.json" ] && puerto_en_uso 5173; then
    ocupados+=(5173)
  fi
  if [ "${#ocupados[@]}" -gt 0 ]; then
    echo "[dev-up] ERROR: ya hay procesos escuchando en los puertos: ${ocupados[*]}." >&2
    echo "         Si son de un dev-up.sh anterior, ejecuta primero: scripts/dev-down.sh" >&2
    exit 1
  fi
}

if [ "$FOREGROUND" = "1" ]; then
  trap fg_limpiar EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
fi

# uv: a veces `uv` es un shim (p. ej. de pyenv) que falla dentro de repos con .python-version.
# Se prueba `uv --version` dentro de un repo de servicio y, si falla, se busca un uv real en
# ~/.pyenv/versions/*/bin como respaldo.
resolver_uv() {
  local probe="$WORKSPACE/consultaya-usuarios" cand
  [ -d "$probe" ] || probe="$DEPLOY_DIR"
  if (cd "$probe" && uv --version >/dev/null 2>&1); then return 0; fi
  for cand in "$HOME"/.pyenv/versions/*/bin/uv; do
    if [ -x "$cand" ] && (cd "$probe" && "$cand" --version >/dev/null 2>&1); then
      PATH="$(dirname "$cand"):$PATH"
      export PATH
      echo "  uv resuelto en $cand"
      return 0
    fi
  done
  echo "No se encontró un uv funcional. Instálalo (ver README, \"Primeros pasos\") y vuelve a intentar." >&2
  return 1
}
resolver_uv

if [ "$FOREGROUND" = "1" ]; then fg_verificar_puertos; fi

# 1) Bases
log "Bases de datos locales"
"$SCRIPTS_DIR/db-local-init.sh"

# 2) Dependencias y migraciones
log "Dependencias y migraciones"
ACTIVOS=()
for item in "${SERVICIOS[@]}"; do
  svc="${item%%:*}"
  dir="$WORKSPACE/consultaya-$svc"
  if ! repo_listo "$svc"; then
    aviso "consultaya-$svc todavía no tiene código (falta pyproject.toml); se omite."
    continue
  fi
  ACTIVOS+=("$item")
  echo "-- $svc"
  # Si el servicio no tiene .env se genera desde su .env.example con los datos de deploy/.env.
  # Si ya existe NO se toca.
  if [ ! -f "$dir/.env" ]; then
    if [ -f "$dir/.env.example" ]; then
      entorno_generar "$dir/.env.example" "$dir/.env" "$svc" "$DB_HOST"
      echo "  .env generado desde .env.example (con los datos de consultaya-deploy/.env)"
    else
      aviso "consultaya-$svc no tiene .env ni .env.example."
    fi
  fi
  (cd "$dir" && uv sync && uv run alembic upgrade head)
done

# 3) Seeds
if [ "$SEED" = "1" ]; then
  log "Seeds"
  hacer_seed() { # servicio script
    local svc="$1" script="$2" dir="$WORKSPACE/consultaya-$1"
    if ! repo_listo "$svc"; then return 0; fi
    if [ -f "$dir/scripts/$script" ]; then
      echo "-- $svc: $script"
      (cd "$dir" && uv run python "scripts/$script")
    else
      aviso "consultaya-$svc no tiene scripts/$script todavía; se omite."
    fi
  }
  hacer_seed lecciones seed.py
  hacer_seed usuarios seed_demo.py
  hacer_seed progreso seed_demo.py
else
  log "Seeds omitidos (--no-seed)"
fi

# 4) Servicios
log "Servicios"
UVICORN_EXTRA=()
if [ "$FOREGROUND" = "1" ]; then UVICORN_EXTRA=(--reload --reload-dir app); fi
for item in "${ACTIVOS[@]:-}"; do
  [ -n "$item" ] || continue
  svc="${item%%:*}"; puerto="${item##*:}"
  arrancar "$svc" "$puerto" "$WORKSPACE/consultaya-$svc" "http://localhost:$puerto/health" \
    uv run --no-sync uvicorn app.main:app --host 127.0.0.1 --port "$puerto" ${UVICORN_EXTRA[@]+"${UVICORN_EXTRA[@]}"}
done

# 5) Health
log "Esperando /health"
for item in "${ACTIVOS[@]:-}"; do
  [ -n "$item" ] || continue
  svc="${item%%:*}"; puerto="${item##*:}"
  esperar_url "http://localhost:$puerto/health" "$svc" 60
done

# 6) Frontend
FRONT_DIR="$WORKSPACE/consultaya-frontend"
if [ "$FRONT" = "1" ]; then
  log "Frontend (Vite)"
  if [ ! -f "$FRONT_DIR/package.json" ]; then
    aviso "consultaya-frontend todavía no tiene package.json; se omite."
    FRONT=0
  else
    if [ ! -d "$FRONT_DIR/node_modules" ]; then
      (cd "$FRONT_DIR" && npm install --no-audit --no-fund)
    fi
    arrancar frontend 5173 "$FRONT_DIR" "http://localhost:5173/" \
      env VITE_BACKEND=native npm run dev -- --host 127.0.0.1 --port 5173 --strictPort
    esperar_url "http://localhost:5173/" frontend 60
  fi
fi

# 7) Resumen
log "Listo"
for item in "${ACTIVOS[@]:-}"; do
  [ -n "$item" ] || continue
  svc="${item%%:*}"; puerto="${item##*:}"
  echo "  $svc: http://localhost:$puerto/api/$svc/docs"
done
if [ "$FRONT" = "1" ]; then
  echo "  Aplicación: http://localhost:5173"
  echo "  Cuenta demo: demo@consultaya.pe / demo1234"
fi
echo "  Logs: $LOGS/   Estado: scripts/dev-status.sh   Detener: scripts/dev-down.sh"
if [ "$FOREGROUND" = "1" ]; then
  if [ "${#FG_PIDS[@]}" -eq 0 ]; then echo "  No se arrancó ningún proceso; nada que mantener en primer plano."; exit 0; fi
  echo
  echo "  Modo en primer plano: Ctrl+C detiene todo. Salida en vivo abajo (también en .logs/)."
  while true; do
    fg_verificar
    sleep 1 & wait $!
  done
fi
