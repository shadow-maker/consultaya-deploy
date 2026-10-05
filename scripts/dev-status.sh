#!/usr/bin/env bash
# Muestra el /health de cada servicio local de ConsultaYa.
set -euo pipefail

uso() {
  cat <<'AYUDA'
Uso: scripts/dev-status.sh [--help]

Consulta el estado del modo nativo (y del modo Docker si está arriba):
  usuarios  http://localhost:8001/health
  lecciones http://localhost:8002/health
  progreso  http://localhost:8003/health
  frontend  http://localhost:5173/        (Vite)
  gateway   http://localhost:8080/health  (nginx del modo Docker; opcional)
Código de salida: 0 si los 3 servicios nativos responden, 1 si alguno no.
AYUDA
}

case "${1:-}" in
  -h|--help) uso; exit 0 ;;
  "") ;;
  *) echo "Opción desconocida: $1" >&2; uso >&2; exit 2 ;;
esac

fallos=0

estado() { # nombre url obligatorio(1|0)
  local nombre="$1" url="$2" obligatorio="$3" cuerpo
  if cuerpo="$(curl -fsS --max-time 3 "$url" 2>/dev/null)"; then
    cuerpo="${cuerpo%%$'\n'*}"
    printf '  %-10s OK       %s\n' "$nombre" "${cuerpo:0:80}"
  else
    printf '  %-10s caído    %s\n' "$nombre" "$url"
    if [ "$obligatorio" = "1" ]; then fallos=$((fallos + 1)); fi
  fi
}

echo "Modo nativo:"
estado usuarios  http://localhost:8001/health 1
estado lecciones http://localhost:8002/health 1
estado progreso  http://localhost:8003/health 1
estado frontend  http://localhost:5173/       0
echo "Modo Docker (opcional):"
estado gateway   http://localhost:8080/health 0

if [ "$fallos" -gt 0 ]; then
  echo "$fallos servicio(s) nativo(s) sin respuesta. Usa scripts/dev-up.sh." >&2
  exit 1
fi
