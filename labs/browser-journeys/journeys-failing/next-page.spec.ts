import { test, expect } from '@playwright/test';

// The recording never loaded page 2, so with mocks on this call is a miss.
test('shopper pages through the items', async ({ page }) => {
  await page.goto('/');

  await test.step('load the item list', async () => {
    await page.getByRole('button', { name: 'Load items' }).click();
    await expect(page.getByRole('listitem')).toHaveText(['apple', 'pear']);
  });

  await test.step('load the next page', async () => {
    await page.getByRole('button', { name: 'Next page' }).click();
    await expect(page.getByRole('listitem')).toHaveText(['plum', 'quince'], { timeout: 3000 });
  });
});
