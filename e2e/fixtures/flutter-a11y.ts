import { Page } from '@playwright/test';

export async function waitForFlutter(page: Page): Promise<void> {
  await page.waitForSelector('flt-glass-pane', { state: 'attached', timeout: 30_000 });
  await page.evaluate(() => {
    const btn = document.querySelector('[aria-label="Enable accessibility"]') as HTMLElement | null;
    if (btn) btn.click();
  });
  await page.waitForTimeout(500);
}
