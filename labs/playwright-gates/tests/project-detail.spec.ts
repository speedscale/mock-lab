import { test, expect } from '@playwright/test';

test('track a project from its detail page', async ({ page }) => {
  await page.goto('/#/projects/envoy');
  await expect(page.getByRole('heading', { name: 'Envoy' })).toBeVisible();
  await page.getByRole('button', { name: 'Track project' }).click();
  await expect(page.locator('#track-status')).toHaveText('Tracking');
});
