import { test, expect } from '@playwright/test';

test.use({
  ignoreHTTPSErrors: true
});

test('test', async ({ page }) => {
  await page.goto('/');
  await page.getByRole('button', { name: 'Load items' }).click();
});