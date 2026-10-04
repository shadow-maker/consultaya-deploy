#!/usr/bin/env bash
# Detiene lo que arrancó dev-up.sh (por PID; como respaldo, por los puertos de ConsultaYa).
set -euo pipefail

uso() {
  cat <<'AYUDA'
Uso: scripts/dev-down.sh [--help]

Detiene los procesos que arrancó scripts/dev-up.sh:
  1. Por PID guardado en .logs/*.pid (y sus procesos hijos).
  2. Como respaldo, lo que escuche en los puertos 8001, 8002, 8003 y 5173,
     solo si es un proceso python/uvicorn/node/uv.
NUNCA toca procesos en otros puertos ni detiene Postgres.
AYUDA
}

case "${1:-}" in
  -h|--help) uso; exit 0 ;;
  "") ;;
  *) echo "Opción desconocida: $1" >&2; uso >&2; exit 2 ;;
esac

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS="$(cd "$SCRIPTS_DIR/.." && pwd)/.logs"

hijos() { pgrep -P "$1" 2>/dev/null || true; }

matar_arbol() { # pid
  local pid="$1" h
  for h in $(hijos "$pid"); do matar_arbol "$h"; done
  kill -TERM "$pid" 2>/dev/null || true
}

detenidos=0

# 1) Por PID
for pidfile in "$LOGS"/usuarios.pid "$LOGS"/lecciones.pid "$LOGS"/progreso.pid "$LOGS"/frontend.pid; do
  [ -f "$pidfile" ] || continue
  nombre="$(basename "$pidfile" .pid)"
  pid="$(cat "$pidfile")"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    matar_arbol "$pid"
    echo "  $nombre detenido (PID $pid)."
    detenidos=$((detenidos + 1))
  fi
  rm -f "$pidfile"
done

sleep 1

# 2) Respaldo por puerto (solo estos puertos y solo procesos de desarrollo)
for puerto in 8001 8002 8003 5173; do
  for pid in $(lsof -nP -tiTCP:"$puerto" -sTCP:LISTEN 2>/dev/null || true); do
    cmd="$(ps -o comm= -p "$pid" 2>/dev/null || true)"
    case "$(basename "${cmd:-?}")" in
      python*|Python*|uvicorn|node|uv|npm)
        kill -TERM "$pid" 2>/dev/null || true
        echo "  puerto $puerto: proceso $(basename "$cmd") (PID $pid) detenido."
        detenidos=$((detenidos + 1))
        ;;
      *)
        echo "  puerto $puerto: lo usa '$(basename "${cmd:-?}")' (PID $pid), no es de ConsultaYa; no se toca." >&2
        ;;
    esac
  done
done

if [ "$detenidos" -eq 0 ]; then
  echo "No había nada que detener."
else
  echo "Listo."
fi
