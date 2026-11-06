// Read-only journeys run against shared environments, so the rule is enforced,
// not trusted: any call to the API that is not a read is aborted and fails the
// journey that made it.
import { test as base, expect } from '@playwright/test';

export const test = base.extend<{ readOnly: void }>({
  readOnly: [async ({ page }, use) => {
    const writes: string[] = [];
    await page.route('**/v1/**', (route) => {
      const method = route.request().method();
      if (method === 'GET' || method === 'HEAD') return route.fallback();
      writes.push(`${method} ${route.request().url()}`);
      return route.abort('blockedbyclient');
    });
    await use();
    expect(writes, 'a read-only journey tried to write').toEqual([]);
  }, { auto: true }],
});

export { expect };
