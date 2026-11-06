import { test, expect } from '@playwright/test';

test.use({ viewport: { width: 1280, height: 800 } });

// The runner runs each journey once, so the pages whose speed matters are
// registered several times to give the p95 more than one sample each.
const samples = [1, 2, 3, 4, 5];

for (const i of samples) {
  test(`overview renders #${i}`, async ({ page }) => {
    await page.goto('/#/');
    await expect(page.getByText('Most starred')).toBeVisible();
  });

  test(`project list renders #${i}`, async ({ page }) => {
    await page.goto('/#/projects');
    await expect(page.getByRole('status')).toHaveText('24 projects');
  });

  test(`project detail renders #${i}`, async ({ page }) => {
    await page.goto('/#/projects/kubernetes');
    await expect(page.getByRole('heading', { name: 'Kubernetes' })).toBeVisible();
  });
}
