import { test, expect } from '@playwright/test';

// Changes data, so it runs only against environments that allow writes (here:
// your own machine). It tracks a project and puts it back afterwards.
const api = 'http://api.localtest.me:8082';
const project = 'envoy';

test.afterEach(async ({ request }) => {
  await request.delete(`${api}/v1/projects/${project}/track`);
});

test('track a project from its detail page', async ({ page }) => {
  await page.goto(`/#/projects/${project}`);
  await expect(page.getByRole('heading', { name: 'Envoy' })).toBeVisible();

  await test.step('track it', async () => {
    await page.getByRole('button', { name: 'Track project' }).click();
    await expect(page.locator('#track-status')).toHaveText('Tracking');
  });
});
