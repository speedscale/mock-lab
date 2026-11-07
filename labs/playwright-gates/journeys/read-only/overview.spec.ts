import { test, expect } from './_support/guards';
import { maturityCounts, mostStarred } from './_support/expected';

test.use({ testIdAttribute: 'data-test', viewport: { width: 1280, height: 800 } });

test('overview counts projects by maturity', async ({ page }) => {
  await test.step('open the overview', async () => {
    await page.goto('/#/');
    await expect(page.getByRole('heading', { name: 'Overview' })).toBeVisible();
  });

  await test.step('read the maturity cards', async () => {
    await expect(page.getByTestId('maturity-graduated')).toContainText(String(maturityCounts.Graduated));
    await expect(page.getByTestId('maturity-incubating')).toContainText(String(maturityCounts.Incubating));
    await expect(page.getByTestId('maturity-sandbox')).toContainText(String(maturityCounts.Sandbox));
    await expect(page.getByTestId('top-projects').getByRole('listitem').first()).toContainText(mostStarred);
  });
});
