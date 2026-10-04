#!/usr/bin/env bash
# Modo Docker local (paridad con la EC2): nginx en http://localhost:8080.
set -euo pipefail

uso() {
  cat <<'AYUDA'
Uso: scripts/docker-local.sh <up|seed|status|down> [opciones]

  up      prepara env/local/*.env, compila el frontend si falta, y levanta
          nginx + usuarios + lecciones + progreso en http://localhost:8080
  seed    corre los seeds dentro de los contenedores (lecciones, usuarios, progreso)
  status  docker compose ps + /health de cada servicio vía nginx
  down    detiene y elimina los contenedores (el volumen del plan B se conserva)

Opciones de up:
  --db host        usa el Postgres del host (host.docker.internal:5432)
  --db container   plan B: Postgres en contenedor (puerto 55432)
  --db auto        (por defecto) prueba el host y, si falla, usa el plan B y lo avisa
  --build-front    fuerza `npm run build` del frontend
  --no-seed        no corre los seeds al terminar
Opciones de down:
  --volumes        además borra el volumen del Postgres del plan B (solo bases consultaya_*)

Nunca se modifica la configuración del Postgres del host.
AYUDA
}

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
WORKSPACE="$(cd "$DEPLOY_DIR/.." && pwd)"
FRONT_DIR="$WORKSPACE/consultaya-frontend"
BASE=(-f docker-compose.yml -f docker-compose.local.yml)
PLAN_B=(-f docker-compose.localdb.yml)
MODE_FILE="$DEPLOY_DIR/.logs/docker-db-mode"
URL="http://localhost:8080"

CMD="${1:-}"
case "$CMD" in
  -h|--help|"") uso; [ -n "$CMD" ] && exit 0 || exit 2 ;;
  up|seed|status|down) shift ;;
  *) echo "Comando desconocido: $CMD" >&2; uso >&2; exit 2 ;;
esac

DB_MODE="auto"
BUILD_FRONT=0
SEED=1
VOLUMES=0
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) uso; exit 0 ;;
    --db) DB_MODE="${2:-}"; shift ;;
    --build-front) BUILD_FRONT=1 ;;
    --no-seed) SEED=0 ;;
    --volumes) VOLUMES=1 ;;
    *) echo "Opción desconocida: $1" >&2; uso >&2; exit 2 ;;
  esac
  shift
done
case "$DB_MODE" in host|container|auto) ;; *) echo "--db debe ser host, container o auto" >&2; exit 2 ;; esac

cd "$DEPLOY_DIR"
mkdir -p .logs

# Qué compose usar según el modo guardado por el último "up" (para seed/status/down).
compose() {
  local files=("${BASE[@]}")
  if [ -f "$MODE_FILE" ] && [ "$(cat "$MODE_FILE")" = "container" ]; then files+=("${PLAN_B[@]}"); fi
  docker compose "${files[@]}" "$@"
}

esperar() { # url etiqueta
  local i
  for i in $(seq 1 60); do
    if curl -fsS --max-time 3 "$1" >/dev/null 2>&1; then echo "  $2 OK"; return 0; fi
    sleep 2
  done
  echo "  $2 no respondió: $1" >&2
  return 1
}

hacer_seeds() {
  echo "==> Seeds"
  compose exec -T lecciones python scripts/seed.py
  compose exec -T usuarios python scripts/seed_demo.py
  compose exec -T progreso python scripts/seed_demo.py
}

case "$CMD" in
  up)
    echo "==> env/local/*.env"
    for svc in usuarios lecciones progreso; do
      if [ ! -f "env/local/$svc.env" ]; then
        cp "env/local/$svc.env.example" "env/local/$svc.env"
        echo "  creado env/local/$svc.env"
      fi
    done

    echo "==> Conexión de un contenedor al Postgres del host"
    if [ "$DB_MODE" = "auto" ] || [ "$DB_MODE" = "host" ]; then
      if docker run --rm postgres:18-alpine psql -h host.docker.internal -U ca -d postgres -Atc "select 1" >/dev/null 2>.logs/docker-pg-test.log; then
        echo "  OK: los contenedores llegan al Postgres del host."
        DB_MODE="host"
      else
        echo "  FALLÓ (detalle en .logs/docker-pg-test.log):" >&2
        sed 's/^/    /' .logs/docker-pg-test.log >&2
        if [ "$DB_MODE" = "host" ]; then
          echo "  No se toca la configuración de Postgres. Usa --db container (plan B)." >&2
          exit 1
        fi
        echo "  AVISO: se usa el plan B (Postgres en contenedor, puerto 55432). No se cambió el Postgres del host." >&2
        DB_MODE="container"
      fi
    fi
    echo "$DB_MODE" >"$MODE_FILE"

    if [ "$DB_MODE" = "host" ]; then
      "$SCRIPTS_DIR/db-local-init.sh"
    fi

    if [ "$BUILD_FRONT" = "1" ] || [ ! -f "$FRONT_DIR/dist/index.html" ]; then
      echo "==> Build del frontend"
      if [ ! -f "$FRONT_DIR/package.json" ]; then
        echo "  consultaya-frontend no tiene package.json todavía." >&2; exit 1
      fi
      (cd "$FRONT_DIR" && { [ -d node_modules ] || npm install --no-audit --no-fund; } && npm run build)
    fi

    echo "==> docker compose up (db: $DB_MODE)"
    compose up -d --build

    echo "==> Esperando servicios"
    esperar "$URL/health" gateway
    for svc in usuarios lecciones progreso; do esperar "$URL/api/$svc/health" "$svc"; done

    if [ "$SEED" = "1" ]; then hacer_seeds; fi
    echo "Listo: $URL   (demo@consultaya.pe / demo1234)"
    ;;
  seed)
    hacer_seeds
    ;;
  status)
    compose ps
    for ruta in health api/usuarios/health api/lecciones/health api/progreso/health; do
      printf '  %-24s ' "/$ruta"
      curl -fsS --max-time 3 "$URL/$ruta" 2>/dev/null || echo "sin respuesta"
      echo
    done
    ;;
  down)
    args=(down --remove-orphans)
    if [ "$VOLUMES" = "1" ]; then args+=(--volumes); fi
    # Con ambos compose para que también baje el Postgres del plan B si estuvo activo.
    docker compose "${BASE[@]}" "${PLAN_B[@]}" "${args[@]}"
    rm -f "$MODE_FILE"
    ;;
esac
