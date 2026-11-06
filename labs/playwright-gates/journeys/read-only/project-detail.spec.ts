import { test, expect } from './_support/guards';

test.use({ testIdAttribute: 'data-test', viewport: { width: 1280, height: 800 } });

// The team's version also clicked Track project, a write. That half moved to
// journeys/writes/ so this journey is safe against any environment.
test('project detail shows the project facts', async ({ page }) => {
  await test.step('open Envoy from the list', async () => {
    await page.goto('/#/projects');
    await page.getByRole('link', { name: 'Envoy' }).click();
    await expect(page.getByRole('heading', { name: 'Envoy' })).toBeVisible();
  });

  await test.step('read the facts', async () => {
    await expect(page.getByText('Graduated', { exact: true })).toBeVisible();
    await expect(page.getByText('envoyproxy/envoy')).toBeVisible();
    await expect(page.getByRole('button', { name: 'Track project' })).toBeVisible();
  });
});
