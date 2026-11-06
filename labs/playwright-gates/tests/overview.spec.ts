import { test, expect } from '@playwright/test';
import { maturityCount, mostStarred } from './helpers/data';

test('overview counts projects by maturity', async ({ page }) => {
  await page.goto('http://localhost:3000/#/');
  await expect(page.getByTestId('maturity-graduated')).toContainText(String(maturityCount('Graduated')));
  await expect(page.getByTestId('maturity-incubating')).toContainText(String(maturityCount('Incubating')));
  await expect(page.getByTestId('top-projects').getByRole('listitem').first()).toContainText(mostStarred.name);
});
