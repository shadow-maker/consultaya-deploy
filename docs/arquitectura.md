# Arquitectura (vista rápida)

ConsultaYa enseña SQL practicando: el SQL del estudiante se ejecuta **en el navegador** (sql.js, SQLite en WebAssembly); el backend solo guarda cuentas, contenido y avance. Los diagramas están en el [README](../README.md#arquitectura-e-infraestructura).

## Piezas y puertos

| Pieza | Repo | Puerto local nativo | Dentro de Docker | Base de datos |
|---|---|---|---|---|
| Frontend (React + Vite) | `consultaya-frontend` | 5173 | build estático servido por nginx | — |
| `usuarios` (registro, login, JWT) | `consultaya-usuarios` | 8001 | 8000 | `consultaya_usuarios` |
| `lecciones` (módulos, ejercicios, datasets) | `consultaya-lecciones` | 8002 | 8000 | `consultaya_lecciones` |
| `progreso` (avance, ruta, resumen) | `consultaya-progreso` | 8003 | 8000 | `consultaya_progreso` |
| nginx (gateway) | este repo | — | 80 en la EC2, 8080 en local | — |

Cada servicio tiene además su base `_test` para sus pruebas. Una instancia de PostgreSQL con **una base por servicio** (en AWS, RDS).

## Quién llama a quién

- El navegador llama siempre a rutas relativas `/api/<servicio>/...` (mismo origen, sin CORS).
- nginx solo publica `/api/usuarios/`, `/api/lecciones/`, `/api/progreso/` y `/health`. Todo lo demás, incluido `/interno/*`, responde 404.
- Única dependencia entre servicios: `progreso` → `lecciones` `GET /interno/estructura` (red interna de Docker o localhost), con caché en memoria. Si `lecciones` no responde y no hay caché, `progreso` responde `503 SERVICIO_NO_DISPONIBLE`.
- `usuarios` emite un JWT (HS256); `lecciones` y `progreso` lo validan con el **mismo** `JWT_SECRET`.
- El navegador descarga el dataset `.sqlite` desde `GET /api/lecciones/datasets/{slug}/archivo` y ejecuta el SQL localmente.

## Variables de entorno

| Variable | Servicios | Notas |
|---|---|---|
| `DATABASE_URL` | los 3 | En local la genera `dev-up` desde `consultaya-deploy/.env`; en Docker local usa `host.docker.internal`; en AWS apunta a RDS con el usuario propio de cada servicio |
| `TEST_DATABASE_URL` | los 3 | Solo para las pruebas (base `consultaya_<svc>_test`) |
| `JWT_SECRET` | los 3 | El mismo valor en los 3. En AWS: aleatorio de 64+ caracteres |
| `JWT_EXP_HORAS` | usuarios | Duración del token (24) |
| `LECCIONES_URL` | progreso | `http://localhost:8002` en nativo, `http://lecciones:8000` en Docker |
| `ESTRUCTURA_CACHE_SEG` | progreso | TTL de la caché de estructura (60) |
| `LOG_LEVEL` | los 3 | `INFO` |
