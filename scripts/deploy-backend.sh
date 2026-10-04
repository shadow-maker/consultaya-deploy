#!/usr/bin/env bash
# Actualiza y reconstruye uno o todos los microservicios en la EC2.
set -euo pipefail

uso() {
  cat <<'AYUDA'
Uso: scripts/deploy-backend.sh <usuarios|lecciones|progreso|todos> [--no-pull] [--help]

Para el servicio indicado:
  1. git pull --ff-only en ../consultaya-<servicio>   (omitir con --no-pull)
  2. docker compose up -d --build <servicio>
  3. espera a que http://localhost/api/<servicio>/health responda (vía nginx)
  4. docker image prune -f (limpia imágenes huérfanas)
Con "todos" repite el proceso para los 3 servicios.

Ejecutar desde la EC2 (en consultaya-deploy). Usa docker-compose.yml de producción.
Para otro compose: COMPOSE_FILES="-f docker-compose.yml -f docker-compose.local.yml".
Variable HEALTH_BASE (por defecto http://localhost) cambia la base del chequeo.
AYUDA
}

SERVICIO=""
PULL=1
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) uso; exit 0 ;;
    --no-pull) PULL=0 ;;
    usuarios|lecciones|progreso|todos)
      if [ -n "$SERVICIO" ]; then echo "Indica un solo servicio." >&2; exit 2; fi
      SERVICIO="$1" ;;
    *) echo "Argumento desconocido: $1" >&2; uso >&2; exit 2 ;;
  esac
  shift
done

if [ -z "$SERVICIO" ]; then
  echo "Falta el servicio." >&2
  uso >&2
  exit 2
fi

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
WORKSPACE="$(cd "$DEPLOY_DIR/.." && pwd)"
HEALTH_BASE="${HEALTH_BASE:-http://localhost}"
COMPOSE_FILES="${COMPOSE_FILES:--f docker-compose.yml}"

if [ "$SERVICIO" = "todos" ]; then
  LISTA=(usuarios lecciones progreso)
else
  LISTA=("$SERVICIO")
fi

cd "$DEPLOY_DIR"

for svc in "${LISTA[@]}"; do
  echo "==> $svc"
  repo="$WORKSPACE/consultaya-$svc"
  if [ "$PULL" = "1" ]; then
    if [ ! -d "$repo/.git" ]; then
      echo "No existe el repo $repo (¿se clonó en el mismo directorio que consultaya-deploy?)." >&2
      exit 1
    fi
    git -C "$repo" pull --ff-only
  fi
  # shellcheck disable=SC2086
  docker compose $COMPOSE_FILES up -d --build "$svc"

  url="$HEALTH_BASE/api/$svc/health"
  for i in $(seq 1 40); do
    if curl -fsS --max-time 3 "$url" >/dev/null 2>&1; then
      echo "  $svc responde en $url"
      break
    fi
    if [ "$i" -eq 40 ]; then
      echo "  $svc no respondió en $url tras 80 s. Revisa: docker compose logs $svc" >&2
      exit 1
    fi
    sleep 2
  done
done

docker image prune -f >/dev/null
echo "Listo."
