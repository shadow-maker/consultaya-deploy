import { expect, test } from '@playwright/test';
import { irA, iniciarSesionDemo, registrarUsuarioNuevo } from '../helpers';

// HU5 · Ver mi progreso

test('HU5-E1', async ({ page }) => {
  // Usuario recién registrado: sin ejercicios completados
  await registrarUsuarioNuevo(page);
  await irA(page, '/progreso');
  // THEN mensaje de que aún no tiene avance
  await expect(page.getByTestId('progreso-vacio')).toContainText(/A[uú]n no tienes avance/i);
  // AND botón para empezar la primera lección
  await expect(page.getByTestId('progreso-empezar')).toBeVisible();
});

test('HU5-E2', async ({ page }) => {
  // Cuenta demo (Ana): 5 ejercicios completados por el seed
  await iniciarSesionDemo(page);
  await irA(page, '/progreso');
  // THEN porcentaje de avance por módulo
  for (const slug of ['basico', 'intermedio', 'avanzado']) {
    await expect(page.getByTestId(`progreso-modulo-${slug}`)).toContainText('%');
  }
  // AND listado de ejercicios completados con su fecha
  const completado = page.getByTestId('progreso-completado-select-from-1');
  await expect(completado).toBeVisible();
  await expect(completado).toContainText(/\d{1,2}\s*(de\s*)?(sep|set)|2026|\d{1,2}\/\d{1,2}\/\d{4}/i);
  await expect(page.getByTestId('progreso-completado-where-1')).toBeVisible();
  await expect(page.getByTestId('progreso-vacio')).toHaveCount(0);
});
