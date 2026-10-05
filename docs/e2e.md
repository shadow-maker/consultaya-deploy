# Pruebas e2e (Playwright)

Las pruebas viven en `e2e/` (Playwright + TypeScript). Hay **un test por escenario Gherkin** y su nombre es el ID del escenario (`HU1-E1` … `HU5-E2`), así que `-g HU4-E2` ejecuta uno solo.

## Cómo correrlas

```bash
cd e2e
npm install
npx playwright install chromium          # una sola vez (descarga el navegador)
npm test                                  # contra http://localhost:5173 (modo nativo)
BASE_URL=http://localhost:8080 npm test   # modo Docker (nginx)
BASE_URL=https://dxxxx.cloudfront.net npm test   # producción (crea usuarios e2e+...)
npx playwright test -g HU4-E2             # un solo escenario
npm run test:list                         # lista los 12 escenarios
```

En PowerShell: `$env:BASE_URL = 'http://localhost:8080'; npm test`.

Requisitos: el sistema corriendo (`scripts/dev-up.*` o `scripts/docker-local.*`) con las bases **sembradas** (cuenta demo `demo@consultaya.pe` / `demo1234`, con el avance de Ana). Un `globalSetup` hace un *warm-up* (espera a que la app y `/api/lecciones/health` respondan y carga las pantallas de registro e inicio de sesión), y la configuración permite un reintento, para que la primera corrida en frío no sea frágil. Los tests corren en serie (`workers: 1`) porque comparten base de datos. Las cuentas nuevas usan correos únicos `e2e+<timestamp>@consultaya.pe`.

## Escenarios

| ID | Pasos clave | Verificación |
|---|---|---|
| HU1-E1 | Registro con correo único | Toast de confirmación; URL `#/ruta` |
| HU1-E2 | Registro con `demo@consultaya.pe` | Mensaje "ya está en uso" |
| HU1-E3 | Login con `demo@consultaya.pe` y contraseña incorrecta | Mensaje "Credenciales inválidas" |
| HU2-E1 | Login como demo → `#/ruta` | 3 módulos (Básico, Intermedio, Avanzado); cada lección con estado y botón |
| HU3-E1 | Abrir una lección | Explicación, ≥1 ejemplo con tabla de resultado, botón "Ir a los ejercicios" |
| HU4-E1 | Ejercicio `where-1`: escribir consulta → Ejecutar | Tabla de resultados visible |
| HU4-E2 | Solución correcta → Enviar (usuario nuevo) | "¡Respuesta correcta!" y ejercicio completado (también en Mi progreso) |
| HU4-E3 | Filtro equivocado → Enviar | Mensaje de diferencia (filas, columnas o valores); el editor sigue editable |
| HU4-E4 | `SELEC * FROM productos` → Ejecutar | Error de sintaxis en español |
| HU4-E5 | `DELETE FROM productos` → Ejecutar | "Solo se permiten consultas SELECT" |
| HU5-E1 | Usuario recién registrado → `#/progreso` | "Aún no tienes avance" + botón para empezar |
| HU5-E2 | Demo → `#/progreso` | % por módulo y lista de ejercicios completados con fecha |

## `data-testid` que usan las pruebas

El frontend los expone y las pruebas dependen de ellos; si se renombra uno, hay que actualizar ambos lados.

`registro-nombres`, `registro-email`, `registro-password`, `registro-submit`, `login-email`, `login-password`, `login-submit`, `form-error`, `toast`, `modulo-<slug>`, `leccion-<slug>`, `leccion-estado-<slug>`, `leccion-abrir-<slug>`, `seccion`, `ejemplo-resultado`, `ir-ejercicios`, `editor`, `ejecutar`, `enviar`, `resultado`, `feedback-ok`, `feedback-error`, `sql-error`, `ex-tab-<id>`, `progreso-vacio`, `progreso-empezar`, `progreso-modulo-<slug>`, `progreso-completado-<ejercicio_id>`.

El editor es un `<textarea>` dentro de `[data-testid=editor]`; las pruebas escriben con `fill()` sobre ese textarea. Los slugs de módulo son `basico`, `intermedio` y `avanzado`.

## Archivos

| Archivo | Contenido |
|---|---|
| `e2e/playwright.config.ts` | `BASE_URL`, serie, un reintento, `globalSetup` |
| `e2e/global-setup.ts` | Warm-up en frío |
| `e2e/helpers.ts` | Registro, login, apertura de ejercicios, cuenta demo |
| `e2e/tests/hu1-…hu5-*.spec.ts` | Un test por escenario |
