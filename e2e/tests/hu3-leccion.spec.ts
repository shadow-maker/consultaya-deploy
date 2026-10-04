import { expect, test } from '@playwright/test';
import { irA, iniciarSesionDemo } from '../helpers';

// HU3 · Ver lección

test('HU3-E1', async ({ page }) => {
  await iniciarSesionDemo(page);
  await irA(page, '/ruta');

  // WHEN selecciona una lección
  await page.getByTestId('leccion-abrir-where').first().click();
  await expect(page).toHaveURL(/#\/leccion\/where/);

  // THEN explicación en español
  const secciones = page.getByTestId('seccion');
  await expect(secciones.first()).toBeVisible();
  expect(((await secciones.first().innerText()) ?? '').trim().length).toBeGreaterThan(20);

  // AND al menos una consulta de ejemplo con su resultado (tabla)
  const ejemplo = page.getByTestId('ejemplo-resultado').first();
  await expect(ejemplo).toBeVisible();
  await expect(ejemplo.locator('table')).toBeVisible();

  // AND botón para ir a los ejercicios
  await expect(page.getByTestId('ir-ejercicios')).toBeVisible();
});
