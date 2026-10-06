# Despliegue en AWS (AWS Academy Learner Lab)

> **Estado de la verificación:** todo lo de esta guía que se puede probar sin AWS está **verificado en local**: las 3 imágenes se construyen, `docker compose` con el PostgreSQL de la máquina (y con el plan B en contenedor) levanta los 4 contenedores sanos, nginx solo expone `/api/*` y `/health`, los seeds corren dentro de los contenedores y los 12 e2e pasan contra `http://localhost:8080` (`scripts/docker-local.sh up`). `scripts/init-rds.sql` se probó contra un PostgreSQL 18 desechable. **No** se probó en una EC2 ni en RDS reales.
>
> **Alcance de este repo:** deja listos el compose de producción, nginx, `env/*.env.example`, `bootstrap-ec2.sh`, `init-rds.sql` y `deploy-backend.sh`. El despliegue en AWS (crear recursos en la consola) lo ejecuta una persona del equipo siguiendo esta guía; ningún script de este repo crea recursos en AWS.
>
> **Windows:** `bootstrap-ec2.sh`, `deploy-backend.sh` e `init-rds.sql` corren **dentro de la EC2** (Linux), así que no necesitan PowerShell: conéctate por SSH (OpenSSH viene con Windows 10/11: `ssh -i labsuser.pem ec2-user@<elastic-ip>`) y ejecútalos allí. Lo que sí se hace en tu máquina (publicar el frontend, `scp`/`git archive`) funciona igual desde PowerShell con el AWS CLI.

## Arquitectura objetivo

- **Frontend:** build de React en **S3 privado**, servido por **CloudFront** con OAC.
- **Backend:** **1 EC2** (`t3.small`, Amazon Linux 2023) con **Elastic IP**, Docker Compose: `nginx:80` → `usuarios`, `lecciones`, `progreso` (cada uno en 8000, red interna).
- **Base de datos:** **RDS PostgreSQL** `db.t3.micro`, privada, con 3 bases y 3 usuarios.
- **CloudFront** con dos orígenes: S3 (default) y la EC2 (`/api/*`). Un solo dominio `https://dxxxx.cloudfront.net`.

## Restricciones de Learner Lab a tener en cuenta

- Trabajar en **`us-east-1`**.
- No se pueden crear roles IAM: usar **`LabInstanceProfile`** (rol `LabRole`) en la EC2 y el key pair **`vockey`** (descargar `labsuser.pem` desde "AWS Details").
- Al terminar la sesión del lab, **la EC2 se detiene**. Con Elastic IP la dirección no cambia y `restart: unless-stopped` + `systemctl enable docker` levantan todo al volver.
- **RDS consume créditos aunque no se use**: detenerla cuando no se necesite. AWS la vuelve a encender sola a los 7 días.
- Las credenciales de la CLI vencen en cada sesión: copiarlas de "AWS Details → AWS CLI" a `~/.aws/credentials` cada vez que se use la CLI desde tu máquina.
- Costo aproximado con todo encendido: EC2 t3.small ~US$0.021/h + RDS t3.micro ~US$0.018/h + Elastic IP ~US$0.005/h ≈ **US$1.1 por día**. S3 y CloudFront: centavos.
- **Límites de RDS en el lab** (documento "AWS Academy Learner Lab – Foundation Services"):
  - Instancias nano, micro, small y medium; motores Aurora, MySQL, PostgreSQL y MariaDB.
  - Volúmenes EBS de hasta 100 GB, tipo General Purpose SSD (**gp2**).
  - Solo clases de instancia **On-Demand** (no Serverless).
  - **Multi-AZ no soportado**: elige la plantilla Dev/Test o Free tier y no crees una instancia standby.
  - **Enhanced monitoring no soportado**: hay que desmarcarlo (viene activado por defecto).
- **EC2:** el lab admite volúmenes gp2 y gp3 (la guía usa gp3 para la EC2).
- Verificar al inicio que el lab permite **CloudFront**. Plan B si no: S3 *static website hosting* público + CORS en nginx para el origen del sitio, y el frontend usando la URL de la EC2.

## Paso 0 — Preparar valores

Generar y guardar (fuera de git):
- `JWT_SECRET`: `openssl rand -hex 48`.
- Contraseña maestra de RDS y una contraseña por servicio: `openssl rand -base64 24 | tr -d '/+='`.

## Paso 1 — Security groups (VPC por defecto)

| SG | Entrada | Desde |
|---|---|---|
| `consultaya-ec2-sg` | TCP 80 | **Prefix list administrada** `com.amazonaws.global.cloudfront.origin-facing` |
| | TCP 22 | Tu IP pública (`/32`) |
| `consultaya-rds-sg` | TCP 5432 | `consultaya-ec2-sg` (por ID de SG) |

> Mientras pruebas sin CloudFront, puedes abrir temporalmente el 80 a tu IP. **Ciérralo** al terminar.

## Paso 2 — RDS PostgreSQL

> **Cuidado con la tarjeta "Create with express configuration".** La consola de RDS la muestra arriba y crea **Aurora PostgreSQL Serverless**. **No la uses**: Serverless no es una clase de instancia On-Demand (el lab solo admite esas) y es más cara para el presupuesto del lab.

Consola RDS → **Databases → Create database** → **Standard create / Full configuration**:
- Engine: **PostgreSQL** (no "Aurora (PostgreSQL Compatible)"), versión 16 o 17.
- Plantilla **Free tier** o **Dev/Test**, **sin instancia standby** (Multi-AZ no está soportado en el lab; si la consola lo ofrece, elige "Do not create a standby instance").
- Clase **`db.t3.micro`** (On-Demand). Almacenamiento **General Purpose SSD (gp2)**, 20 GB (el lab admite hasta 100 GB), sin autoscaling.
- Identificador `consultaya-db`, usuario maestro `postgres_admin`, contraseña del paso 0.
- VPC por defecto, **Public access: No**, SG `consultaya-rds-sg`.
- Initial database name: (vacío). Backups: 1 día.
- **Desmarca "Enable Enhanced monitoring"** (viene marcado por defecto y el lab no lo soporta). Desactiva también Performance Insights.
- Anotar el **endpoint** (`consultaya-db.xxxx.us-east-1.rds.amazonaws.com`).

## Paso 3 — EC2

Consola EC2 → Launch instance:
- Nombre `consultaya-api`, **Amazon Linux 2023**, **`t3.small`**, key pair **`vockey`**.
- VPC por defecto, subred pública, auto-assign public IP, SG `consultaya-ec2-sg`.
- Almacenamiento 20 GB gp3.
- Advanced → IAM instance profile **`LabInstanceProfile`**.
- **User data:** pegar el contenido de `consultaya-deploy/scripts/bootstrap-ec2.sh`. Instala docker, git y el cliente de postgres (`postgresql16`, o `postgresql15` si no existe). Como Amazon Linux 2023 no trae los plugins de Docker, también instala **compose v2.29.7** y **buildx v0.17.1** como binarios fijados (se pueden cambiar con `COMPOSE_VERSION` / `BUILDX_VERSION`). Además hace `systemctl enable --now docker`, agrega `ec2-user` al grupo docker y crea `/opt/consultaya` con dueño `ec2-user`. Para comprobar que terminó: `sudo cat /var/log/cloud-init-output.log` y `docker compose version`.
- Luego: EC2 → Elastic IPs → Allocate → Associate a `consultaya-api`.
- Anotar el **Public IPv4 DNS** (`ec2-X-X-X-X.compute-1.amazonaws.com`), que corresponde a la Elastic IP.

## Paso 4 — Código y configuración en la EC2

```bash
ssh -i labsuser.pem ec2-user@<elastic-ip>
sudo mkdir -p /opt/consultaya && sudo chown ec2-user /opt/consultaya && cd /opt/consultaya
```

Los repos son **privados**. Para clonar, crear en GitHub un **fine-grained personal access token** de solo lectura (Contents: Read) para los 4 repos de backend y deploy, y usarlo **una sola vez**. No dejarlo en la máquina más allá de `~/.git-credentials` con `chmod 600`, y revocarlo al terminar el curso:

```bash
git config --global credential.helper store
for r in consultaya-deploy consultaya-usuarios consultaya-lecciones consultaya-progreso; do
  git clone https://github.com/shadow-maker/$r.git
done
```

> Alternativa sin token en la EC2: en tu máquina, `git archive` de cada repo → `scp` → descomprimir en `/opt/consultaya`.

Crear las bases y los usuarios (se puede repetir sin riesgo: si el rol existe se actualiza su contraseña y si la base existe no se toca; falla con un mensaje claro si quedó algún marcador `<PASSWORD_...>`):
```bash
cd /opt/consultaya/consultaya-deploy
cp scripts/init-rds.sql /tmp/init.sql
# Editar /tmp/init.sql reemplazando las 3 contraseñas <PASSWORD_...>
psql "host=<endpoint-rds> user=postgres_admin dbname=postgres sslmode=require" -f /tmp/init.sql
rm /tmp/init.sql
```

`init-rds.sql` (en el repo, con marcadores) hace, para cada servicio `X` ∈ {usuarios, lecciones, progreso}:
```sql
CREATE ROLE consultaya_X LOGIN PASSWORD '<PASSWORD_X>';
CREATE DATABASE consultaya_X OWNER consultaya_X;
REVOKE ALL ON DATABASE consultaya_X FROM PUBLIC;
```

Antes del `CREATE DATABASE … OWNER`, el script hace `GRANT consultaya_X TO CURRENT_USER`. En RDS con PostgreSQL 16 o superior, el usuario maestro lo necesita para crear una base cuyo dueño es otro rol.

Variables de entorno:
```bash
cd /opt/consultaya/consultaya-deploy
cp env/usuarios.env.example env/usuarios.env    # idem lecciones y progreso
chmod 600 env/*.env
```

Contenido (producción):
```dotenv
# env/usuarios.env
DATABASE_URL=postgresql+psycopg://consultaya_usuarios:<PASSWORD_USUARIOS>@<endpoint-rds>:5432/consultaya_usuarios?sslmode=require
JWT_SECRET=<JWT_SECRET>
JWT_EXP_HORAS=24
LOG_LEVEL=INFO
# env/lecciones.env
DATABASE_URL=postgresql+psycopg://consultaya_lecciones:<PASSWORD_LECCIONES>@<endpoint-rds>:5432/consultaya_lecciones?sslmode=require
JWT_SECRET=<JWT_SECRET>
LOG_LEVEL=INFO
# env/progreso.env
DATABASE_URL=postgresql+psycopg://consultaya_progreso:<PASSWORD_PROGRESO>@<endpoint-rds>:5432/consultaya_progreso?sslmode=require
JWT_SECRET=<JWT_SECRET>
LECCIONES_URL=http://lecciones:8000
ESTRUCTURA_CACHE_SEG=60
LOG_LEVEL=INFO
```

## Paso 5 — Levantar el backend

```bash
cd /opt/consultaya/consultaya-deploy
docker compose up -d --build
docker compose ps
curl -s localhost/health
curl -s localhost/api/usuarios/health
curl -s localhost/api/lecciones/health
curl -s localhost/api/progreso/health
docker compose exec lecciones python scripts/seed.py           # contenido (obligatorio)
docker compose exec usuarios python scripts/seed_demo.py       # opcional: cuentas demo
docker compose exec progreso python scripts/seed_demo.py       # opcional: avance demo
```

Desplegar **un solo** microservicio tras un cambio:
```bash
./scripts/deploy-backend.sh progreso    # git pull --ff-only en ../consultaya-progreso + up -d --build progreso + espera /health + prune
./scripts/deploy-backend.sh todos       # los 3 servicios
./scripts/deploy-backend.sh lecciones --no-pull   # reconstruir sin hacer git pull
```

> `curl localhost/health` lo responde el propio nginx (`{"status":"ok","servicio":"gateway"}`). Cualquier ruta no expuesta (incluida `/interno/*`) devuelve 404 con el formato de error estándar. nginx resuelve los contenedores con el DNS interno de Docker, así que arranca aunque un servicio esté caído y sigue funcionando cuando `deploy-backend.sh` recrea uno.

## Paso 6 — S3 para el frontend

- Crear el bucket `consultaya-frontend-<sufijo-único>` en `us-east-1`, con **Block all public access activado**. No habilitar *static website hosting*.

## Paso 7 — CloudFront

Create distribution:
- **Origen 1 (default):** el bucket S3 (endpoint REST, no el de website), **Origin access control (OAC)** → crear OAC. Al finalizar, copiar la **bucket policy** que propone la consola y pegarla en el bucket.
- **Comportamiento por defecto:**
  - Viewer protocol: Redirect HTTP to HTTPS.
  - Métodos: GET, HEAD.
  - Cache policy: `CachingOptimized`.
  - Default root object: `index.html`.
- **Origen 2:** dominio = **Public IPv4 DNS de la EC2** (no la IP). Protocol: **HTTP only**, puerto 80.
- **Comportamiento `/api/*`** → origen EC2:
  - Viewer: Redirect to HTTPS.
  - Métodos: GET, HEAD, OPTIONS, PUT, POST, PATCH, DELETE.
  - Cache policy: **`CachingDisabled`**.
  - Origin request policy: **`AllViewerExceptHostHeader`** (para que llegue `Authorization`).
- **No** configurar "custom error responses": afectarían también los 404 del API. La SPA usa `HashRouter`.
- Esperar a que termine el despliegue (5–15 minutos) y anotar el **Distribution ID** y el dominio `dxxxx.cloudfront.net`.

## Paso 8 — Publicar el frontend (desde tu máquina)

Con las credenciales de la sesión del lab en `~/.aws/credentials`:
```bash
cd consultaya-frontend
./scripts/deploy-s3.sh consultaya-frontend-<sufijo> <DISTRIBUTION_ID>
```

## Paso 9 — Verificación

Abrir `https://dxxxx.cloudfront.net`:
1. Home carga con estilos (no hay errores 403 de assets ni del `.wasm`).
2. Registro → redirige a la ruta (HU1-E1). Login con contraseña incorrecta → "Credenciales inválidas" (HU1-E3).
3. Ruta con estados → lección con ejemplos → ejercicio: Ejecutar, Enviar (correcto/incorrecto), DML bloqueado (HU2–HU4).
4. Mi progreso muestra el avance (HU5).
5. Opcional: correr los e2e contra producción: `BASE_URL=https://dxxxx.cloudfront.net npm test` (crea usuarios `e2e+…`).

## Operación diaria y apagado

- **Al iniciar una sesión del lab:** la EC2 arranca y los contenedores se levantan solos. Si RDS estaba detenida, encenderla y esperar a que esté *Available*.
- **Al terminar:** detener RDS si no se usará en días.
- **Logs:** `docker compose logs -f <servicio>`.
- **Reinicio:** `docker compose restart <servicio>`.
- **Fin del curso:**
  1. Borrar la distribución de CloudFront (primero desactivarla).
  2. Vaciar y borrar el bucket.
  3. Terminar la EC2 y liberar la Elastic IP.
  4. Borrar RDS (sin snapshot final, si ya no se necesita).
  5. Revocar el token de GitHub.

## Problemas comunes

| Síntoma | Causa probable | Solución |
|---|---|---|
| `/api/*` responde 502/504 en CloudFront | EC2 detenida, SG sin la prefix list de CloudFront, o nginx caído | Verificar la EC2, el SG y `docker compose ps` |
| 401 en todos los endpoints de progreso | `JWT_SECRET` distinto entre servicios | Igualar `JWT_SECRET` en los 3 `.env` y `docker compose up -d` |
| `progreso` responde 503 | `lecciones` caído o `LECCIONES_URL` mal | `docker compose logs lecciones`; debe ser `http://lecciones:8000` |
| Contenedor reinicia en bucle | RDS inaccesible o credenciales mal | `docker compose logs <svc>`; probar `psql` desde la EC2 |
| Pantalla en blanco tras deploy del front | Caché de `index.html` | Re-ejecutar la invalidación `/index.html` |
| Error al cargar `sql-wasm.wasm` | `Content-Type` incorrecto en S3 | Volver a subirlo con `--content-type application/wasm` |
| Ruta "no encontrada" al recargar | Se usó BrowserRouter | Debe ser HashRouter (`/#/ruta`) |
