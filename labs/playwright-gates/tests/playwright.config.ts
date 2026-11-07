// The team's Playwright setup, as it was before the browser-journey-tests skill
// ported it. `npx playwright test -c tests` still runs it.
import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  testDir: '.',
  retries: process.env.CI ? 2 : 0,
  use: {
    baseURL: process.env.BASE_URL ?? 'http://localhost:3000',
    testIdAttribute: 'data-test',
    viewport: { width: 1280, height: 800 },
    trace: 'on-first-retry',
  },
  webServer: [
    { command: 'node ../app/serve-site.js', port: 3000, reuseExistingServer: true },
    { command: 'node ../app/api/server.js', port: 8082, reuseExistingServer: true },
  ],
  projects: [
    { name: 'chromium', use: { ...devices['Desktop Chrome'] } },
    { name: 'firefox', use: { ...devices['Desktop Firefox'] } },
  ],
});
