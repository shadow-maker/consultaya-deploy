import { chromium, type FullConfig } from '@playwright/test';

/**
 * Warm-up: antes de la primera prueba, carga la app en un navegador y espera a que
 * responda (Vite en frío recarga dependencias; nginx/CloudFront pueden tardar al inicio).
 * Así la primera corrida tras dev-up.sh o docker-local.sh up no depende del arranque.
 */
export default async function globalSetup(config: FullConfig): Promise<void> {
  const baseURL = config.projects[0].use.baseURL as string;
  const limite = Date.now() + 90_000;

  // 1) Esperar a que la app y la API respondan.
  let ultimoError = '';
  for (;;) {
    try {
      const app = await fetch(baseURL);
      const api = await fetch(`${baseURL}/api/lecciones/health`);
      if (app.ok && api.ok) break;
      ultimoError = `app ${app.status}, api ${api.status}`;
    } catch (e) {
      ultimoError = String(e);
    }
    if (Date.now() > limite) {
      throw new Error(`BASE_URL ${baseURL} no responde tras 90 s (${ultimoError}).`);
    }
    await new Promise((r) => setTimeout(r, 1000));
  }

  // 2) Cargar la SPA en un navegador (fuerza la optimización/recarga en frío de Vite).
  const browser = await chromium.launch();
  try {
    const page = await browser.newPage();
    for (const ruta of ['/#/registro', '/#/login']) {
      await page.goto(`${baseURL}${ruta}`, { waitUntil: 'networkidle', timeout: 60_000 });
      await page.getByTestId(ruta.includes('registro') ? 'registro-submit' : 'login-submit')
        .waitFor({ timeout: 60_000 });
    }
  } finally {
    await browser.close();
  }
}
