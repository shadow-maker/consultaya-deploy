# consultaya-deploy

Despliegue de **ConsultaYa** (plataforma web para aprender SQL practicando, en español): `docker-compose`, nginx, scripts locales y de AWS (EC2/RDS) y pruebas e2e con Playwright.

La especificación completa vive en el workspace (`../docs/`). Este README resume lo esencial para correr el sistema en local y desplegar el backend en AWS; el detalle paso a paso está en `../docs/06-despliegue-aws.md`.

## Contenido

| Ruta | Para qué |
|---|---|
| `docker-compose.yml` | Producción (EC2): `nginx:80` + `usuarios`, `lecciones`, `progreso` (puerto 8000 interno) |
| `docker-compose.local.yml` | Override local: nginx en `8080`, sirve `../consultaya-frontend/dist`, Postgres del host |
| `docker-compose.localdb.yml` | Plan B local: Postgres en contenedor (puerto `55432`) |
| `nginx/default.conf` · `nginx/local.conf` | Gateway. Solo expone `/api/{usuarios,lecciones,progreso}/` y `/health`. **Nunca** `/interno` |
| `env/*.env.example` · `env/local/*.env.example` | Variables de producción y de Docker local (los `.env` reales no se commitean) |
| `scripts/` | Orquestación local, bootstrap de EC2, SQL de RDS, deploy por servicio |
| `e2e/` | Playwright + TypeScript: un test por escenario Gherkin (HU1-E1 … HU5-E2) |

## Modo nativo (desarrollo diario)

Requisitos: Postgres local (`localhost:5432`, usuario `ca`, sin password), `uv`, Node.

```bash
scripts/dev-up.sh          # bases → migraciones → seeds → 3 servicios → Vite
scripts/dev-status.sh      # /health de cada servicio
scripts/dev-down.sh        # detiene lo que arrancó dev-up.sh
```

`dev-up.sh` resuelve `uv` solo: si el shim de pyenv falla dentro de los repos (`pyenv: uv: command not found`), usa `~/.pyenv/versions/*/bin/uv`.

Abre http://localhost:5173 (cuenta demo `demo@consultaya.pe` / `demo1234`). Logs y PIDs en `.logs/`. `dev-up.sh --no-seed` omite los seeds y `--no-front` no arranca Vite.

`scripts/db-local-init.sh` crea (solo si no existen) las 6 bases `consultaya_{usuarios,lecciones,progreso}` y sus `_test`. Nunca borra nada ni toca otras bases.

## Modo Docker (paridad con la EC2)

```bash
scripts/docker-local.sh up        # http://localhost:8080
scripts/docker-local.sh status
scripts/docker-local.sh seed      # solo si se omitió con --no-seed
scripts/docker-local.sh down
```

`up` copia `env/local/*.env.example` a `env/local/*.env`, compila el frontend si falta `dist/`, comprueba que un contenedor llegue al Postgres del host y levanta todo. Equivale a:

```bash
cd ../consultaya-frontend && npm run build && cd ../consultaya-deploy
docker compose -f docker-compose.yml -f docker-compose.local.yml up -d --build
```

Prueba de conexión contenedor → Postgres del host:

```bash
docker run --rm postgres:18-alpine psql -h host.docker.internal -U ca -d postgres -Atc "select 1"
```

Si falla (por ejemplo, Postgres.app pide confirmar el permiso de conexión: *"You did not confirm the permission dialog"*), **no se cambia la configuración de Postgres**: confirma el diálogo de Postgres.app o usa el plan B (`--db container`, que agrega `docker-compose.localdb.yml` con un Postgres propio en `localhost:55432`). Con `--db auto` (por defecto) el script cae solo al plan B y lo avisa.

## Pruebas e2e

```bash
cd e2e
npm install
npx playwright install chromium      # una sola vez
BASE_URL=http://localhost:5173 npm test     # nativo (por defecto)
BASE_URL=http://localhost:8080 npm test     # Docker
npx playwright test -g HU4-E2        # un escenario
npm run test:list                    # lista los 12 escenarios
```

Cada test se llama como su escenario (`HU1-E1` … `HU5-E2`). Las cuentas nuevas usan correos únicos `e2e+<timestamp>@consultaya.pe`. Requieren el sistema corriendo y las bases sembradas (cuenta demo con avance). Los `data-testid` que usan están acordados en `../docs/07-plan-implementacion.md`.

## Despliegue en AWS (lo ejecuta Carlos)

Resumen; ver `../docs/06-despliegue-aws.md` para cada paso de consola (región `us-east-1`, AWS Academy Learner Lab).

1. **Valores** (fuera de git): `JWT_SECRET` (`openssl rand -hex 48`) y una contraseña por servicio y para RDS (`openssl rand -base64 24 | tr -d '/+='`).
2. **Security groups**: EC2 con TCP 80 solo desde la prefix list de CloudFront (`com.amazonaws.global.cloudfront.origin-facing`) y 22 desde tu IP; RDS con 5432 solo desde el SG de la EC2.
3. **RDS PostgreSQL** `db.t3.micro`, privada.
4. **EC2** `t3.small` Amazon Linux 2023, `LabInstanceProfile`, user data = `scripts/bootstrap-ec2.sh`, Elastic IP.
5. **Código en la EC2** (`/opt/consultaya`): clonar `consultaya-deploy`, `consultaya-usuarios`, `consultaya-lecciones`, `consultaya-progreso` en la misma carpeta.
6. **Bases y usuarios** (una vez): copiar `scripts/init-rds.sql` a `/tmp/init.sql`, reemplazar las 3 `<PASSWORD_...>` y ejecutar `psql "host=<endpoint-rds> user=postgres_admin dbname=postgres sslmode=require" -f /tmp/init.sql`. Después borrar el archivo.
7. **Variables**: `cp env/<servicio>.env.example env/<servicio>.env` (los 3), completar los marcadores `<...>` (mismo `JWT_SECRET` en los 3) y `chmod 600 env/*.env`.
8. **Levantar**:
   ```bash
   docker compose up -d --build
   curl -s localhost/health && curl -s localhost/api/usuarios/health
   docker compose exec lecciones python scripts/seed.py        # contenido (obligatorio)
   docker compose exec usuarios python scripts/seed_demo.py    # opcional
   docker compose exec progreso python scripts/seed_demo.py    # opcional
   ```
9. **Frontend**: S3 privado + CloudFront (origen 2 = DNS público de la EC2, comportamiento `/api/*` con `CachingDisabled` y `AllViewerExceptHostHeader`); publicar con `consultaya-frontend/scripts/deploy-s3.sh`.
10. Verificar abriendo `https://dxxxx.cloudfront.net`; opcionalmente, `BASE_URL=https://dxxxx.cloudfront.net npm test` en `e2e/`.

Actualizar **un** microservicio tras un cambio:

```bash
scripts/deploy-backend.sh progreso      # git pull + docker compose up -d --build + espera /health
scripts/deploy-backend.sh todos
```

Operación: `docker compose logs -f <servicio>`, `docker compose restart <servicio>`. Al volver a iniciar la sesión del lab, la EC2 y los contenedores se levantan solos (`restart: unless-stopped`); si RDS estaba detenida, enciéndela y espera a que esté *Available*.

## Scripts

Todos usan `set -euo pipefail` y aceptan `--help`.

| Script | Función |
|---|---|
| `db-local-init.sh` | Crea las 6 bases `consultaya_*` que falten |
| `dev-up.sh` / `dev-down.sh` / `dev-status.sh` | Modo nativo |
| `docker-local.sh` | Modo Docker local (`up`, `seed`, `status`, `down`) |
| `bootstrap-ec2.sh` | User data de la EC2: docker, compose, buildx, git, psql |
| `init-rds.sql` | Roles y bases por servicio en RDS (con marcadores `<PASSWORD_...>`) |
| `deploy-backend.sh` | Actualiza y reconstruye uno o todos los servicios |
| `localdb-init.sql` | Bases del contenedor Postgres del plan B |

## Reglas

Solo se crean y usan bases `consultaya_*`; nunca se commitean `env/*.env` ni `.env`; sin CI/CD ni recursos de AWS creados desde este repo.
