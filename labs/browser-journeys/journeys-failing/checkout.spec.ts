import { test, expect } from '@playwright/test';

// The page has no Checkout button. Every call this journey makes is a hit, so
// the failure is the frontend's, not the API's.
test('shopper sees a checkout button', async ({ page }) => {
  await page.goto('/');

  await test.step('load the item list', async () => {
    await page.getByRole('button', { name: 'Load items' }).click();
    await expect(page.getByRole('listitem').first()).toHaveText('apple');
  });

  await test.step('go to checkout', async () => {
    await expect(page.getByRole('button', { name: 'Checkout' })).toBeVisible({ timeout: 3000 });
  });
});
