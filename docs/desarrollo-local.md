# Desarrollo local

Dos modos: **nativo** (el día a día: uvicorn + Vite sobre tu PostgreSQL) y **Docker** (paridad con la EC2: nginx + contenedores). Para instalar los requisitos y clonar los repos, empieza por el [README](../README.md#primeros-pasos-para-el-equipo).

## Configuración: `consultaya-deploy/.env`

Es la **fuente única** de la configuración local y Git la ignora. Se crea copiando el ejemplo:

```bash
cp .env.example .env              # macOS / Linux
Copy-Item .env.example .env       # Windows (PowerShell)
```

| Variable | Qué es |
|---|---|
| `DB_HOST` / `DB_PORT` | Servidor PostgreSQL (por defecto `localhost` / `5432`) |
| `DB_USER` / `DB_PASSWORD` | Usuario con permiso para crear bases y su contraseña (puede ir vacía). No hace falta escapar caracteres especiales: los scripts los codifican en las URLs |
| `JWT_SECRET` | Secreto de desarrollo, igual para los 3 servicios |

Qué hacen los scripts con ese archivo:

- **Sin `.env` no arrancan**: abortan con instrucciones (no adivinan tu usuario).
- `dev-up` genera `consultaya-<servicio>/.env` copiando el `.env.example` del servicio y reemplazando solo `DATABASE_URL`, `TEST_DATABASE_URL` y `JWT_SECRET` (`postgresql+psycopg://<usuario>[:<contraseña>]@<host>:<puerto>/consultaya_<servicio>[_test]`). El resto de líneas se conserva. **Si el `.env` del servicio ya existe, no se toca.**
- `docker-local up` genera `env/local/<servicio>.env` en cada ejecución (con `host.docker.internal`).
- Las variables de entorno con los mismos nombres tienen prioridad sobre el archivo: `DB_PORT=55432 scripts/db-local-init.sh`.

## Bases de datos

Solo se crean y usan bases con prefijo `consultaya_`: `consultaya_usuarios`, `consultaya_lecciones`, `consultaya_progreso` y sus `_test`. `scripts/db-local-init.*` crea las que falten, nunca borra nada y no toca otras bases. Los scripts no modifican la configuración de tu PostgreSQL.

## Modo nativo

| | macOS / Linux | Windows (PowerShell) |
|---|---|---|
| Levantar todo (segundo plano) | `scripts/dev-up.sh` | `scripts\dev-up.ps1` |
| Levantar atado a la terminal | `scripts/dev-up.sh --foreground` | `scripts\dev-up.ps1 -Foreground` |
| Estado | `scripts/dev-status.sh` | `scripts\dev-status.ps1` |
| Detener | `scripts/dev-down.sh` | `scripts\dev-down.ps1` |
| Solo las bases | `scripts/db-local-init.sh` | `scripts\db-local-init.ps1` |

Opciones de `dev-up`: `--no-seed` / `-NoSeed` (sin seeds), `--no-front` / `-NoFront` (sin Vite), `--help` / `-Help`.

Pasos que hace, en orden: exige el `.env` de deploy → crea las bases → por servicio genera su `.env` si falta, `uv sync` y `alembic upgrade head` → seeds (`lecciones`: contenido; `usuarios` y `progreso`: datos demo) → arranca los 3 uvicorn → espera `/health` → arranca Vite en 5173 → imprime las URLs. Logs y PIDs en `.logs/` (`.logs/<servicio>.log`, `.logs/<servicio>.pid`).

- **Segundo plano (por defecto):** los procesos siguen vivos tras cerrar la terminal; se detienen con `dev-down`.
- **`--foreground`:** los 3 uvicorn (con `--reload`) y Vite quedan atados a la terminal. La salida de los 4 se ve en vivo con prefijo por servicio (`[usuarios]`, `[lecciones]`, `[progreso]`, `[frontend]`) y también se escribe en `.logs/`. `Ctrl+C` detiene los 4 y todos sus procesos hijos; si un servicio muere solo, avisa con su nombre y código de salida y detiene los demás. Si los puertos 8001/8002/8003/5173 ya están ocupados, aborta y sugiere `dev-down`. En macOS/Linux también responde a SIGTERM y SIGHUP; en PowerShell el `Ctrl+C` es el camino soportado (en Windows, cerrar la consola también los detiene en lo posible; si queda algo, usa `dev-down.ps1`).
- **`dev-down`** detiene por PID guardado (y su árbol de procesos) y, como respaldo, lo que escuche en 8001/8002/8003/5173 si es un proceso python/node/uv/npm. Nunca toca otros puertos.
- **uv:** si `uv` es un shim que falla dentro de los repos (por ejemplo, el de pyenv), `dev-up` busca un binario funcional.

URLs: aplicación `http://localhost:5173`; documentación de cada API en `http://localhost:8001/api/usuarios/docs` (idem 8002 `lecciones`, 8003 `progreso`). Cuenta demo: `demo@consultaya.pe` / `demo1234` (con avance); `nuevo@consultaya.pe` / `nuevo1234` (sin avance).

## Modo Docker (paridad con la EC2)

| | macOS / Linux | Windows (PowerShell) |
|---|---|---|
| Levantar (build + seeds) | `scripts/docker-local.sh up` | `scripts\docker-local.ps1 up` |
| Seeds | `scripts/docker-local.sh seed` | `scripts\docker-local.ps1 seed` |
| Estado | `scripts/docker-local.sh status` | `scripts\docker-local.ps1 status` |
| Bajar | `scripts/docker-local.sh down` | `scripts\docker-local.ps1 down` |

Opciones de `up`: `--db host|container|auto` (`-Db` en PowerShell; por defecto `auto`), `--build-front` / `-BuildFront`, `--no-seed` / `-NoSeed`. `down --volumes` / `-Volumes` borra además el volumen del plan B.

`up` genera `env/local/*.env`, compila el frontend si falta `../consultaya-frontend/dist`, comprueba que un contenedor llegue a tu PostgreSQL y levanta `docker-compose.yml` + `docker-compose.local.yml`. La aplicación queda en **http://localhost:8080** (nginx publicado solo en `127.0.0.1`). Es lo mismo que:

```bash
cd ../consultaya-frontend && npm install && npm run build && cd ../consultaya-deploy
docker compose -f docker-compose.yml -f docker-compose.local.yml up -d --build
```

Las migraciones corren al arrancar cada contenedor (`alembic upgrade head && uvicorn …`). Seeds a mano: `docker compose exec lecciones python scripts/seed.py` y `… exec usuarios|progreso python scripts/seed_demo.py` (idempotentes).

### Conexión del contenedor a tu PostgreSQL

La prueba que hace `up` equivale a:

```bash
docker run --rm -e PGPASSWORD postgres:18-alpine psql -h host.docker.internal -p <DB_PORT> -U <DB_USER> -d postgres -Atc "select 1"
```

Si falla (autenticación, permisos o `pg_hba.conf`; en Linux, que PostgreSQL no escuche en la red de Docker; en Postgres.app, que no se confirmó el diálogo de permisos), **no cambies la configuración de tu PostgreSQL**: usa el **plan B**, `docker-compose.localdb.yml`, que agrega un contenedor `postgres:18-alpine` en `127.0.0.1:55432` con las bases `consultaya_*` (usuario y contraseña `consultaya`, solo para desarrollo). Con `--db auto` el script cae solo al plan B y lo avisa.

```bash
scripts/docker-local.sh up --db container
```

## Pruebas

| Dónde | Comando |
|---|---|
| Cada microservicio | `uv run pytest` y `uv run ruff check .` (requiere las bases `_test`) |
| Frontend | `npm test` y `npm run build` |
| e2e | ver [e2e.md](e2e.md) |
