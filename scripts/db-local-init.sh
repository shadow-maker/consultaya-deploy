#!/usr/bin/env bash
# Crea las 6 bases locales de ConsultaYa si no existen. Idempotente. NUNCA borra nada.
set -euo pipefail

uso() {
  cat <<'AYUDA'
Uso: scripts/db-local-init.sh [--help]

Crea (solo si no existen) las bases del PostgreSQL local:
  consultaya_usuarios   consultaya_usuarios_test
  consultaya_lecciones  consultaya_lecciones_test
  consultaya_progreso   consultaya_progreso_test
Imprime qué creó y qué ya existía. No toca ninguna otra base ni borra nada.

Conexión: lee DB_HOST, DB_PORT, DB_USER y DB_PASSWORD de consultaya-deploy/.env
(copia .env.example a .env). Las variables de entorno con esos nombres tienen prioridad:
  DB_PORT=55432 scripts/db-local-init.sh
Si hay contraseña se pasa a psql con PGPASSWORD y nunca se imprime.
AYUDA
}

case "${1:-}" in
  -h|--help) uso; exit 0 ;;
  "") ;;
  *) echo "Opción desconocida: $1" >&2; uso >&2; exit 2 ;;
esac

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/entorno.sh
source "$SCRIPTS_DIR/lib/entorno.sh"
entorno_cargar

# psql: primero el PATH; si no está, ubicaciones habituales de las instalaciones de PostgreSQL.
if ! command -v psql >/dev/null 2>&1; then
  for dir in \
    /Applications/Postgres.app/Contents/Versions/latest/bin \
    /opt/homebrew/opt/postgresql*/bin /usr/local/opt/postgresql*/bin \
    /usr/lib/postgresql/*/bin /usr/pgsql-*/bin; do
    if [ -x "$dir/psql" ]; then PATH="$dir:$PATH"; break; fi
  done
fi
if ! command -v psql >/dev/null 2>&1; then
  echo "No se encontró psql. Instala el cliente de PostgreSQL (ver README) o agrégalo al PATH." >&2
  exit 1
fi

BASES=(
  consultaya_usuarios consultaya_usuarios_test
  consultaya_lecciones consultaya_lecciones_test
  consultaya_progreso consultaya_progreso_test
)

# Siempre contra la base de mantenimiento "postgres"; solo se consulta pg_database y se crean bases.
psql_admin() { psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d postgres -v ON_ERROR_STOP=1 -X -Atq "$@"; }

if ! psql_admin -c "select 1" >/dev/null; then
  echo "No se pudo conectar a PostgreSQL en $DB_HOST:$DB_PORT como $DB_USER." >&2
  echo "Revisa DB_HOST, DB_PORT, DB_USER y DB_PASSWORD en consultaya-deploy/.env." >&2
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
    psql_admin -c "CREATE DATABASE \"$base\"" >/dev/null
    echo "  creada:     $base"
    creadas=$((creadas + 1))
  fi
done

echo "Bases consultaya_*: $creadas creada(s), $existentes ya existía(n)."
