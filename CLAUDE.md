# consultaya-deploy

Parte de ConsultaYa (MVP para aprender SQL). Este repo es autosuficiente: su documentación está dentro de él.

- Rol de este repo: despliegue: docker-compose, nginx, scripts locales (bash y PowerShell) y de EC2/RDS, env examples y tests e2e (Playwright).
- Documentación (léela primero): `README.md` (primeros pasos, arquitectura con diagramas, scripts), `docs/desarrollo-local.md`, `docs/despliegue-aws.md`, `docs/e2e.md`, `docs/arquitectura.md`.
- Referencia opcional: si existe la carpeta `../docs/` (especificación del workspace de ConsultaYa), contiene los contratos de API (`02-contratos-api.md`), convenciones (`08-convenciones.md`) y el plan de implementación. No es necesaria para trabajar aquí.
- Contratos de API: no cambiar endpoints ni formatos sin aprobación; nginx solo expone `/api/{usuarios,lecciones,progreso}/` y `/health`, nunca `/interno`.
- Configuración local: `consultaya-deploy/.env` (copiar de `.env.example`; Git lo ignora). Nada commiteado debe contener datos de una persona o máquina concreta (usuarios, contraseñas, rutas absolutas).
- Puerto local: 8080 (nginx local) · Bases: solo `consultaya_*` (las crea `scripts/db-local-init.*`).
- Scripts: cada `.sh` tiene su `.ps1` equivalente (Windows PowerShell 5.1 / 7); los de EC2 (`bootstrap-ec2.sh`, `deploy-backend.sh`, `init-rds.sql`) son solo bash. `.gitattributes` fija LF para `.sh` y CRLF para `.ps1` (con BOM UTF-8).
- Reglas duras: solo bases `consultaya_*`; nunca `gh`; nunca commitear `.env` ni `env/*.env`; sin líneas Co-Authored-By; sin CI/CD ni recursos de AWS creados desde este repo.
