import { test, expect } from '@playwright/test';

test('shopper loads the item list', async ({ page }) => {
  await page.goto('/');
  await expect(page.getByRole('heading', { name: 'Demo shop SPA' })).toBeVisible();

  await test.step('load the item list', async () => {
    await page.getByRole('button', { name: 'Load items' }).click();
    await expect(page.getByRole('listitem')).toHaveText(['apple', 'pear']);
  });
});
