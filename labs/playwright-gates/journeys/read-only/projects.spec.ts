import { test, expect } from './_support/guards';
import { searchTerm } from './_support/expected';

test.use({ testIdAttribute: 'data-test', viewport: { width: 1280, height: 800 } });

test('search narrows the project list', async ({ page }) => {
  await test.step('open the project list', async () => {
    await page.goto('/#/projects');
    await expect(page.getByRole('status')).toHaveText('24 projects');
  });

  await test.step('search for a project', async () => {
    await page.getByLabel('Search projects').fill(searchTerm);
    // A web-first assertion waits out the 300ms debounce; a fixed sleep would
    // also land in every performance number.
    await expect(page.getByRole('status')).toHaveText('1 project');
    await expect(page.getByRole('link', { name: 'Prometheus' })).toBeVisible();
  });
});

test('maturity filter shows only sandbox projects', async ({ page }) => {
  await page.goto('/#/projects');

  await test.step('filter to sandbox', async () => {
    await page.getByLabel('Maturity').selectOption('Sandbox');
    await expect(page.getByRole('status')).toHaveText('3 projects');
    await expect(page.getByTestId('project-table').locator('tbody td:nth-child(2)')).toHaveText(['Sandbox', 'Sandbox', 'Sandbox']);
  });
});
