import { defineConfig, devices } from '@playwright/test';

// URL base configurable:
//   nativo (Vite)  -> BASE_URL=http://localhost:5173 (por defecto)
//   Docker (nginx) -> BASE_URL=http://localhost:8080
//   producción     -> BASE_URL=https://dxxxx.cloudfront.net
const baseURL = (process.env.BASE_URL ?? 'http://localhost:5173').replace(/\/+$/, '');

export default defineConfig({
  testDir: './tests',
  globalSetup: './global-setup.ts',
  // Los escenarios son independientes, pero comparten base de datos: se corren en serie
  // para que los resultados sean repetibles.
  fullyParallel: false,
  workers: 1,
  retries: 1,
  timeout: 60_000,
  expect: { timeout: 15_000 },
  reporter: [['list'], ['html', { open: 'never' }]],
  use: {
    baseURL,
    locale: 'es-PE',
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    video: 'off',
  },
  projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],
});
