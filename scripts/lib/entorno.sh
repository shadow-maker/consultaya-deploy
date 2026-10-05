#!/usr/bin/env bash
# Funciones comunes de los scripts locales (se carga con `source`, no se ejecuta).
# Lee consultaya-deploy/.env (fuente única de la configuración local) y genera los .env
# de los servicios. No usa eval: el .env se interpreta línea por línea.

# Directorio de consultaya-deploy (esta librería está en scripts/lib).
ENTORNO_DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENTORNO_ARCHIVO="$ENTORNO_DEPLOY_DIR/.env"

# Lee KEY=VALUE de un archivo y exporta solo las claves permitidas que NO estén ya en el
# entorno (el entorno tiene prioridad: DB_PORT=55432 scripts/db-local-init.sh).
entorno_leer() { # archivo
  local linea clave valor
  while IFS= read -r linea || [ -n "$linea" ]; do
    linea="${linea%$'\r'}"
    case "$linea" in ''|'#'*) continue ;; esac
    clave="${linea%%=*}"
    valor="${linea#*=}"
    case "$clave" in DB_HOST|DB_PORT|DB_USER|DB_PASSWORD|JWT_SECRET) ;; *) continue ;; esac
    # Quita comillas envolventes.
    case "$valor" in
      \"*\") valor="${valor#\"}"; valor="${valor%\"}" ;;
      \'*\') valor="${valor#\'}"; valor="${valor%\'}" ;;
    esac
    if [ -z "${!clave+x}" ]; then
      export "$clave=$valor"
    fi
  done <"$1"
}

# Exige consultaya-deploy/.env (o las variables DB_* en el entorno) y fija valores por defecto
# solo donde son neutros (host, puerto, secreto de desarrollo). El usuario NO se adivina.
entorno_cargar() {
  if [ -f "$ENTORNO_ARCHIVO" ]; then
    entorno_leer "$ENTORNO_ARCHIVO"
  elif [ -z "${DB_USER:-}" ]; then
    cat >&2 <<AYUDA
No existe $ENTORNO_ARCHIVO.
Copia .env.example a .env y ajusta tu usuario y contraseña de PostgreSQL:
  cp "$ENTORNO_DEPLOY_DIR/.env.example" "$ENTORNO_ARCHIVO"
AYUDA
    return 1
  fi
  if [ -z "${DB_USER:-}" ]; then
    echo "Falta DB_USER en $ENTORNO_ARCHIVO (usuario de PostgreSQL)." >&2
    return 1
  fi
  export DB_HOST="${DB_HOST:-localhost}" DB_PORT="${DB_PORT:-5432}" DB_PASSWORD="${DB_PASSWORD:-}"
  export JWT_SECRET="${JWT_SECRET:-dev-secret-cambiar}"
  # psql usa PGPASSWORD (nunca se imprime).
  if [ -n "$DB_PASSWORD" ]; then export PGPASSWORD="$DB_PASSWORD"; fi
}

# Codificación porcentual (RFC 3986) para usuario/contraseña dentro de una URL.
entorno_urlencode() {
  local texto="$1" i c hex salida=""
  local LC_ALL=C
  for ((i = 0; i < ${#texto}; i++)); do
    c="${texto:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) salida+="$c" ;;
      *) hex="$(printf '%02X' "'$c")"; salida+="%${hex: -2}" ;;
    esac
  done
  printf '%s' "$salida"
}

# URL base de una base: postgresql+psycopg://user[:pass]@host:port/<base>
entorno_url_db() { # host base
  local cred
  cred="$(entorno_urlencode "$DB_USER")"
  if [ -n "$DB_PASSWORD" ]; then cred="$cred:$(entorno_urlencode "$DB_PASSWORD")"; fi
  printf 'postgresql+psycopg://%s@%s:%s/%s' "$cred" "$1" "$DB_PORT" "$2"
}

# Genera un .env copiando un .env.example y reemplazando SOLO DATABASE_URL, TEST_DATABASE_URL
# y JWT_SECRET (el resto de líneas se conserva). Si falta alguna de las tres, se agrega.
entorno_generar() { # ejemplo destino servicio host [sin_test]
  local ejemplo="$1" destino="$2" svc="$3" host="$4" sin_test="${5:-}" linea
  local url test_url vistos=" "
  url="$(entorno_url_db "$host" "consultaya_$svc")"
  test_url="$(entorno_url_db "$host" "consultaya_${svc}_test")"
  {
    while IFS= read -r linea || [ -n "$linea" ]; do
      linea="${linea%$'\r'}"
      case "$linea" in
        DATABASE_URL=*)      printf 'DATABASE_URL=%s\n' "$url"; vistos+="D " ;;
        TEST_DATABASE_URL=*) printf 'TEST_DATABASE_URL=%s\n' "$test_url"; vistos+="T " ;;
        JWT_SECRET=*)        printf 'JWT_SECRET=%s\n' "$JWT_SECRET"; vistos+="J " ;;
        *) printf '%s\n' "$linea" ;;
      esac
    done <"$ejemplo"
    case "$vistos" in *" D "*) ;; *) printf 'DATABASE_URL=%s\n' "$url" ;; esac
    if [ -z "$sin_test" ]; then
      case "$vistos" in *" T "*) ;; *) printf 'TEST_DATABASE_URL=%s\n' "$test_url" ;; esac
    fi
    case "$vistos" in *" J "*) ;; *) printf 'JWT_SECRET=%s\n' "$JWT_SECRET" ;; esac
  } >"$destino.tmp"
  mv "$destino.tmp" "$destino"
  chmod 600 "$destino" 2>/dev/null || true
}
