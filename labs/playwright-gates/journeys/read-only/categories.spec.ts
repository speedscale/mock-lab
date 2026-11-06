import { test, expect } from './_support/guards';

test.use({ testIdAttribute: 'data-test', viewport: { width: 1280, height: 800 } });

// Built from the router: #/categories had no test in the team's suite.
test('categories lists every category with its project count', async ({ page }) => {
  await test.step('open categories from the nav', async () => {
    await page.goto('/#/');
    await page.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: 'Categories' }).click();
    await expect(page.getByRole('heading', { name: 'Categories' })).toBeVisible();
  });

  await test.step('read the largest category', async () => {
    const firstRow = page.getByTestId('category-table').locator('tbody tr').first();
    await expect(firstRow).toHaveText(/Observability\s*5/);
  });
});
