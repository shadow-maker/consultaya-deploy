#!/usr/bin/env bash
# Crea las 6 bases locales de ConsultaYa si no existen. Idempotente. NUNCA borra nada.
set -euo pipefail

uso() {
  cat <<'AYUDA'
Uso: scripts/db-local-init.sh [--help]

Crea (solo si no existen) las bases del Postgres local:
  consultaya_usuarios   consultaya_usuarios_test
  consultaya_lecciones  consultaya_lecciones_test
  consultaya_progreso   consultaya_progreso_test
Imprime qué creó y qué ya existía. No toca ninguna otra base ni borra nada.

Variables opcionales (valores por defecto entre paréntesis):
  DB_HOST (localhost)  DB_PORT (5432)  DB_USER (ca)
Ejemplo con el Postgres del plan B (docker-compose.localdb.yml):
  DB_PORT=55432 scripts/db-local-init.sh
AYUDA
}

case "${1:-}" in
  -h|--help) uso; exit 0 ;;
  "") ;;
  *) echo "Opción desconocida: $1" >&2; uso >&2; exit 2 ;;
esac

DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"
DB_USER="${DB_USER:-ca}"

# Postgres.app no siempre deja psql en el PATH.
if ! command -v psql >/dev/null 2>&1; then
  PG_APP_BIN="/Applications/Postgres.app/Contents/Versions/latest/bin"
  if [ -x "$PG_APP_BIN/psql" ]; then
    PATH="$PG_APP_BIN:$PATH"
  else
    echo "No se encontró psql. Instala/abre Postgres.app o agrega psql al PATH." >&2
    exit 1
  fi
fi

BASES=(
  consultaya_usuarios consultaya_usuarios_test
  consultaya_lecciones consultaya_lecciones_test
  consultaya_progreso consultaya_progreso_test
)

# Siempre contra la base de mantenimiento "postgres"; solo se consulta pg_database.
psql_admin() { psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d postgres -v ON_ERROR_STOP=1 -X -Atq "$@"; }

if ! psql_admin -c "select 1" >/dev/null; then
  echo "No se pudo conectar a Postgres en $DB_HOST:$DB_PORT como $DB_USER." >&2
  exit 1
fi

creadas=0
existentes=0
for base in "${BASES[@]}"; do
  # Guardia: este script solo maneja bases consultaya_*.
  case "$base" in consultaya_*) ;; *) echo "Base no permitida: $base" >&2; exit 1 ;; esac
  existe="$(psql_admin -c "select 1 from pg_database where datname = '$base'")"
  if [ "$existe" = "1" ]; then
    echo "  ya existía: $base"
    existentes=$((existentes + 1))
  else
    createdb -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" "$base"
    echo "  creada:     $base"
    creadas=$((creadas + 1))
  fi
done

echo "Bases consultaya_*: $creadas creada(s), $existentes ya existía(n)."
