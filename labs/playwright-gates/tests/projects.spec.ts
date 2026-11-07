import { test, expect } from '@playwright/test';

const term = process.env.SEARCH_TERM ?? 'prom';

test('search narrows the project list', async ({ page }) => {
  await page.goto('/#/projects');
  await page.getByLabel('Search projects').fill(term);
  await page.waitForTimeout(500); // the search box debounces for 300ms
  await expect(page.getByTestId('project-table').getByRole('row')).toHaveCount(2);
  await expect(page.getByRole('link', { name: 'Prometheus' })).toBeVisible();
});

test('maturity filter shows only sandbox projects', async ({ page }) => {
  await page.goto('/#/projects');
  await page.getByLabel('Maturity').selectOption('Sandbox');
  await expect(page.getByRole('status')).toHaveText(/\d+ projects?/);
  for (const cell of await page.getByTestId('project-table').locator('tbody td:nth-child(2)').all()) {
    await expect(cell).toHaveText('Sandbox');
  }
});
