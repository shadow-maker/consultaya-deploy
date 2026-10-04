import { expect, type Locator, type Page } from '@playwright/test';

/** Cuenta demo sembrada por consultaya-usuarios (scripts/seed_demo.py). Ana tiene avance. */
export const DEMO = { email: 'demo@consultaya.pe', password: 'demo1234' } as const;

/** Contraseña de las cuentas que crean los e2e (mínimo 8 caracteres). */
export const PASSWORD_E2E = 'e2e12345';

/** Correo único por ejecución: e2e+<timestamp>@consultaya.pe. */
export function correoUnico(): string {
  const sufijo = Math.floor(Math.random() * 1000).toString().padStart(3, '0');
  return `e2e+${Date.now()}${sufijo}@consultaya.pe`;
}

export async function irA(page: Page, rutaHash: string): Promise<void> {
  await page.goto(`/#${rutaHash}`);
}

/** Envía el formulario de registro (sin esperar el resultado). */
export async function enviarRegistro(
  page: Page,
  datos: { nombres?: string; email: string; password?: string },
): Promise<void> {
  await irA(page, '/registro');
  await page.getByTestId('registro-nombres').fill(datos.nombres ?? 'Persona E2E');
  await page.getByTestId('registro-email').fill(datos.email);
  await page.getByTestId('registro-password').fill(datos.password ?? PASSWORD_E2E);
  await page.getByTestId('registro-submit').click();
}

/** Registra una cuenta nueva y deja la sesión iniciada. Devuelve el correo usado. */
export async function registrarUsuarioNuevo(page: Page): Promise<string> {
  const email = correoUnico();
  await enviarRegistro(page, { email });
  await expect(page).toHaveURL(/#\/ruta/);
  return email;
}

/** Envía el formulario de login (sin esperar el resultado). */
export async function enviarLogin(page: Page, email: string, password: string): Promise<void> {
  await irA(page, '/login');
  await page.getByTestId('login-email').fill(email);
  await page.getByTestId('login-password').fill(password);
  await page.getByTestId('login-submit').click();
}

/** Inicia sesión como demo@consultaya.pe y espera salir de la pantalla de login. */
export async function iniciarSesionDemo(page: Page): Promise<void> {
  await enviarLogin(page, DEMO.email, DEMO.password);
  await expect(page).not.toHaveURL(/#\/login/);
}

/** El editor es un <textarea> dentro de [data-testid=editor]. */
export function editor(page: Page): Locator {
  return page.getByTestId('editor').locator('textarea');
}

/** Abre un ejercicio (con sesión iniciada), espera el editor y escribe la consulta. */
export async function abrirEjercicioYEscribir(
  page: Page,
  ejercicioId: string,
  sql: string,
): Promise<void> {
  await irA(page, `/ejercicio/${ejercicioId}`);
  await expect(page.getByTestId('editor')).toBeVisible();
  await editor(page).fill(sql);
}

/** Solución oficial de where-1 (ver docs/04-contenido.md). */
export const SQL_WHERE_1_CORRECTO =
  "SELECT nombre, precio FROM productos WHERE categoria = 'Bebidas'";
