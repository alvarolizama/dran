// Capture Dran UI screenshots with playwright-core + cached chromium.
const { chromium } = require('playwright-core');
const fs = require('fs');

const COOKIE = fs.readFileSync('/tmp/dran_cookie.txt', 'utf8').trim();
const OUT = '/Users/alvaro/Repos/dran/docs/screenshots';
const BASE = 'http://localhost:4000';

const SHOTS = [
  ['/', 'dashboard.png', 2500],
  ['/kanban', 'kanban.png', 2500],
  ['/graph', 'graph.png', 5000],
  ['/notes/curator-report-2026-07-19', 'note-detail.png', 2500],
  ['/settings', 'settings.png', 2500],
  ['/activity', 'activity.png', 2500],
  ['/docs', 'docs.png', 2500],
  ['/notes?archived=1', 'notes-archived.png', 2500],
  ['/projects/lanzar-dran-v6', 'project-detail.png', 3500],
  ['/projects', 'projects.png', 2500],
];

(async () => {
  const browser = await chromium.launch({
    executablePath: process.env.HOME + '/Library/Caches/ms-playwright/chromium_headless_shell-1228/chrome-headless-shell-mac-arm64/chrome-headless-shell',
    headless: true,
  });
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 633 } });
  await ctx.addCookies([{ name: '_dran_key', value: COOKIE, domain: 'localhost', path: '/' }]);
  const page = await ctx.newPage();

  for (const [path, file, wait] of SHOTS) {
    try {
      await page.goto(BASE + path, { waitUntil: 'networkidle', timeout: 20000 });
      await page.waitForTimeout(wait);
      await page.screenshot({ path: `${OUT}/${file}` });
      console.log('captured', file);
    } catch (e) {
      console.log('FAILED', file, e.message.slice(0, 100));
    }
  }
  await browser.close();
})();
