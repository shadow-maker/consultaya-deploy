import { expect, test } from '@playwright/test';
import {
  abrirEjercicioYEscribir,
  irA,
  iniciarSesionDemo,
  registrarUsuarioNuevo,
  SQL_WHERE_1_CORRECTO,
} from '../helpers';

// HU4 · Resolver ejercicio SQL (ejercicio where-1: productos de la categoría Bebidas)

test('HU4-E1', async ({ page }) => {
  await iniciarSesionDemo(page);
  await abrirEjercicioYEscribir(page, 'where-1', SQL_WHERE_1_CORRECTO);
  await page.getByTestId('ejecutar').click();
  // THEN tabla de resultados
  await expect(page.getByTestId('resultado').locator('table')).toBeVisible();
  expect(await page.getByTestId('resultado').locator('tbody tr').count()).toBeGreaterThan(0);
});

test('HU4-E2', async ({ page }) => {
  // Usuario nuevo: el ejercicio se completa por primera vez.
  await registrarUsuarioNuevo(page);
  await abrirEjercicioYEscribir(page, 'where-1', SQL_WHERE_1_CORRECTO);
  await page.getByTestId('ejecutar').click();
  await expect(page.getByTestId('resultado').locator('table')).toBeVisible();
  await page.getByTestId('enviar').click();

  // THEN respuesta correcta y ejercicio marcado como completado
  await expect(page.getByTestId('feedback-ok')).toContainText('¡Respuesta correcta!');
  await expect(page.getByTestId('feedback-ok')).toContainText(/completado/i);
  // ... visible también en la pestaña del ejercicio y en Mi progreso
  await expect(page.getByTestId('ex-tab-where-1')).toBeVisible();
  await irA(page, '/progreso');
  await expect(page.getByTestId('progreso-completado-where-1')).toBeVisible();
});

test('HU4-E3', async ({ page }) => {
  await iniciarSesionDemo(page);
  // Filtro equivocado: Snacks en vez de Bebidas
  await abrirEjercicioYEscribir(
    page,
    'where-1',
    "SELECT nombre, precio FROM productos WHERE categoria = 'Snacks'",
  );
  await page.getByTestId('ejecutar').click();
  await expect(page.getByTestId('resultado')).toBeVisible();
  await page.getByTestId('enviar').click();

  // THEN mensaje en español con la diferencia (columnas, filas o valores)
  const error = page.getByTestId('feedback-error');
  await expect(error).toBeVisible();
  await expect(error).toContainText(/columna|fila|valores/i);
  // AND puede editar y volver a intentar
  const campo = page.getByTestId('editor').locator('textarea');
  await expect(campo).toBeEditable();
  await campo.fill(SQL_WHERE_1_CORRECTO);
  await expect(campo).toHaveValue(SQL_WHERE_1_CORRECTO);
});

test('HU4-E4', async ({ page }) => {
  await iniciarSesionDemo(page);
  await abrirEjercicioYEscribir(page, 'where-1', 'SELEC * FROM productos');
  await page.getByTestId('ejecutar').click();
  // THEN error de sintaxis explicado en español
  const error = page.getByTestId('sql-error');
  await expect(error).toBeVisible();
  await expect(error).toContainText(/sintaxis/i);
});

test('HU4-E5', async ({ page }) => {
  await iniciarSesionDemo(page);
  await abrirEjercicioYEscribir(page, 'where-1', 'DELETE FROM productos');
  await page.getByTestId('ejecutar').click();
  // THEN solo se permiten consultas SELECT
  await expect(page.getByText('Solo se permiten consultas SELECT').first()).toBeVisible();
});
