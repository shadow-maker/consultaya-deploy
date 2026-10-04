# consultaya-deploy

Parte de ConsultaYa (MVP para aprender SQL). La especificación completa está en el workspace: `../docs/` (léela antes de cambiar nada).

- Rol de este repo: despliegue: docker-compose, nginx, scripts locales y de EC2/RDS, env examples y tests e2e (Playwright).
- Contratos de API: `../docs/02-contratos-api.md` (no cambiar endpoints ni formatos sin aprobación del orquestador)
- Cómo correr y testear: `README.md` de este repo y `../docs/05-desarrollo-local.md`
- Convenciones y reglas de git: `../docs/08-convenciones.md`
- Puerto local: 8080 (nginx local) · Bases: — (crea las bases `consultaya_*` con `scripts/db-local-init.sh`)
- Reglas duras: solo bases `consultaya_*`; nunca `gh`; nunca commitear `.env`; sin líneas Co-Authored-By.
