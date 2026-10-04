import { expect, test } from '@playwright/test';
import { irA, iniciarSesionDemo } from '../helpers';

// HU2 · Ver ruta de aprendizaje

test('HU2-E1', async ({ page }) => {
  await iniciarSesionDemo(page);
  await irA(page, '/ruta');
  await expect(page).toHaveURL(/#\/ruta/);

  // Tres módulos: Básico, Intermedio, Avanzado
  const modulos: Array<[string, RegExp]> = [
    ['basico', /B[aá]sico/i],
    ['intermedio', /Intermedio/i],
    ['avanzado', /Avanzado/i],
  ];
  for (const [slug, nombre] of modulos) {
    const modulo = page.getByTestId(`modulo-${slug}`);
    await expect(modulo).toBeVisible();
    await expect(modulo).toContainText(nombre);
    // Cada módulo muestra lecciones, y cada lección tiene estado y botón para abrirla
    const abrir = modulo.locator('[data-testid^="leccion-abrir-"]');
    const estado = modulo.locator('[data-testid^="leccion-estado-"]');
    expect(await abrir.count()).toBeGreaterThan(0);
    expect(await estado.count()).toBe(await abrir.count());
    for (let i = 0; i < (await estado.count()); i++) {
      await expect(estado.nth(i)).toContainText(/pendiente|en curso|completad/i);
    }
  }

  // Ejemplo concreto: la primera lección tiene estado y botón
  await expect(page.getByTestId('leccion-select-from')).toBeVisible();
  await expect(page.getByTestId('leccion-estado-select-from').first()).toContainText(
    /pendiente|en curso|completad/i,
  );
  await expect(page.getByTestId('leccion-abrir-select-from').first()).toBeVisible();
});
