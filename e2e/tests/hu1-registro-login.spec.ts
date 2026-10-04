import { expect, test } from '@playwright/test';
import { correoUnico, DEMO, enviarLogin, enviarRegistro } from '../helpers';

// HU1 · Registro e inicio de sesión

test('HU1-E1', async ({ page }) => {
  // GIVEN no tiene cuenta · WHEN ingresa nombres, correo y contraseña y crea la cuenta
  await enviarRegistro(page, { nombres: 'Lucía Quispe', email: correoUnico() });
  // THEN mensaje de confirmación y redirección a la ruta de aprendizaje
  await expect(page.getByTestId('toast')).toContainText(/Cuenta creada/i);
  await expect(page).toHaveURL(/#\/ruta/);
});

test('HU1-E2', async ({ page }) => {
  // GIVEN un correo ya registrado (el de la cuenta demo)
  await enviarRegistro(page, { email: DEMO.email });
  // THEN mensaje: el correo ya está en uso
  await expect(page.getByTestId('form-error')).toContainText(/ya est[aá] en uso/i);
  await expect(page).toHaveURL(/#\/registro/);
});

test('HU1-E3', async ({ page }) => {
  // GIVEN tiene cuenta · WHEN ingresa correo y contraseña incorrecta
  await enviarLogin(page, DEMO.email, 'contraseña-incorrecta');
  // THEN mensaje: credenciales inválidas
  await expect(page.getByTestId('form-error')).toContainText(/Credenciales inv[aá]lidas/i);
  await expect(page).toHaveURL(/#\/login/);
});
