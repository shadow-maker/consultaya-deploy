#!/usr/bin/env bash
# Levanta ConsultaYa en modo nativo: bases, migraciones, seeds, 3 servicios y Vite.
set -euo pipefail

uso() {
  cat <<'AYUDA'
Uso: scripts/dev-up.sh [--no-seed] [--no-front] [--help]

En orden:
  1. db-local-init.sh (crea las bases consultaya_* que falten)
  2. por servicio: uv sync + alembic upgrade head (usuarios 8001, lecciones 8002, progreso 8003)
  3. seeds: lecciones (seed.py), usuarios y progreso (seed_demo.py)
  4. uvicorn de cada servicio en segundo plano (logs y PIDs en .logs/)
  5. espera a que cada /health responda
  6. Vite en 5173 (VITE_BACKEND=native), salvo con --no-front
  7. imprime las URLs

Opciones:
  --no-seed   no corre los seeds
  --no-front  no arranca el frontend
Detener todo: scripts/dev-down.sh   Estado: scripts/dev-status.sh
Si un repo o un script de seed aún no existe, se avisa y se continúa.
AYUDA
}

SEED=1
FRONT=1
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) uso; exit 0 ;;
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

# uv: en esta Mac suele ser un shim de pyenv que falla dentro de repos con .python-version.
# Se prueba `uv --version` dentro de un repo de servicio y, si falla, se antepone al PATH
# el binario real de ~/.pyenv/versions/*/bin/uv.
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
  echo "No se encontró un uv funcional (ni en el PATH ni en ~/.pyenv/versions/*/bin/uv)." >&2
  return 1
}
resolver_uv

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
  if [ ! -f "$dir/.env" ] && [ -f "$dir/.env.example" ]; then
    cp "$dir/.env.example" "$dir/.env"
    echo "  .env creado desde .env.example"
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
for item in "${ACTIVOS[@]:-}"; do
  [ -n "$item" ] || continue
  svc="${item%%:*}"; puerto="${item##*:}"
  arrancar "$svc" "$puerto" "$WORKSPACE/consultaya-$svc" "http://localhost:$puerto/health" \
    uv run --no-sync uvicorn app.main:app --host 127.0.0.1 --port "$puerto"
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
    VITE_BACKEND=native arrancar frontend 5173 "$FRONT_DIR" "http://localhost:5173/" \
      npm run dev -- --host 127.0.0.1 --port 5173 --strictPort
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
