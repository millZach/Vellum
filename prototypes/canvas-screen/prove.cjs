// Usage: node prove.cjs <url to index.html, without ?variant>   Drives all three variants in headless Chromium; screenshots to /tmp/vellum-proof/shots.
const { chromium } = require(process.env.HOME + '/Projects/Sotto/node_modules/playwright');
(async () => {
  const b = await chromium.launch({ executablePath: '/usr/bin/chromium' });
  const p = await b.newPage({ viewport: { width: 951, height: 709 }, deviceScaleFactor: 2 });
  const errs = []; p.on('pageerror', e => errs.push(e.message)); p.on('console', m => { if (m.type() === 'error') errs.push(m.text()); });
  const url = process.argv[2].startsWith('http') ? process.argv[2] : 'file://' + process.argv[2];
  for (const v of ['A','B','C']) { await p.goto(url + '?variant=' + v); await p.waitForTimeout(300); await p.screenshot({ path: `/tmp/vellum-proof/shots/${v}.png` }); }
  // drive variant A: draw a stroke, measure, dimension, place a sheet, send a redline job
  await p.goto(url + '?variant=A'); await p.waitForTimeout(200);
  const box = await p.locator('#cv').boundingBox(); const at = (x,y) => [box.x + x*box.width/951, box.y + y*box.height/669];
  await p.mouse.move(...at(300,300)); await p.mouse.down(); for (let i=0;i<20;i++) await p.mouse.move(...at(300+i*8, 300+Math.sin(i/3)*20)); await p.mouse.up();
  await p.click('[data-t="measure"]'); await p.mouse.click(...at(200,200)); await p.mouse.move(...at(400,250)); await p.mouse.click(...at(400,250));
  const toast1 = await p.locator('.toast').allTextContents();
  await p.click('[data-t="dim"]'); await p.mouse.click(...at(250,420)); await p.mouse.click(...at(500,420));
  await p.screenshot({ path: '/tmp/vellum-proof/shots/A-drawn.png' });
  await p.click('[data-act="add"]'); await p.fill('[data-act="q"]', 'steam'); await p.waitForTimeout(100);
  await p.screenshot({ path: '/tmp/vellum-proof/shots/A-add.png' });
  await p.click('[data-act="pick"][data-num="P-102"]'); await p.waitForTimeout(100);
  await p.screenshot({ path: '/tmp/vellum-proof/shots/A-scale.png' });
  await p.click('[data-act="pickscale"][data-k="64"]'); await p.click('[data-act="place"]'); await p.waitForTimeout(300);
  const toast2 = await p.locator('.toast').allTextContents();
  await p.click('[data-act="extents"]'); await p.click('[data-act="send"]'); await p.click('[data-act="kind"][data-k="redline"]');
  await p.screenshot({ path: '/tmp/vellum-proof/shots/A-send.png' });
  await p.click('[data-act="dosend"]'); await p.waitForTimeout(4000);
  await p.screenshot({ path: '/tmp/vellum-proof/shots/A-job.png' });
  await p.click('[data-act="jobans"][data-i="0"]'); await p.waitForTimeout(2300); await p.click('[data-act="jobplace"]'); await p.waitForTimeout(300);
  await p.screenshot({ path: '/tmp/vellum-proof/shots/A-result.png' });
  // variant B: window select popover, more tools; variant C: ribbon tabs
  await p.goto(url + '?variant=B'); await p.waitForTimeout(200);
  await p.click('[data-act="more"]'); await p.click('[data-t="window"]');
  await p.mouse.move(...at(200,150)); await p.mouse.down(); await p.mouse.move(...at(450,350), { steps: 6 }); await p.mouse.up();
  await p.click('[data-act="rec"]'); await p.waitForTimeout(1200);
  await p.screenshot({ path: '/tmp/vellum-proof/shots/B-window.png' });
  await p.goto(url + '?variant=C'); await p.waitForTimeout(200);
  await p.click('[data-act="rtab"][data-t="Sheets"]'); await p.click('[data-t="frame"]'); await p.mouse.click(...at(600,400));
  await p.screenshot({ path: '/tmp/vellum-proof/shots/C-frame.png' });
  // keyboard switcher
  await p.keyboard.press('ArrowRight'); const lbl = await p.locator('#vlabel').textContent();
  // phone-ish viewport scaling check (Duo landscape)
  await p.setViewportSize({ width: 951, height: 669 }); await p.waitForTimeout(200); await p.screenshot({ path: '/tmp/vellum-proof/shots/duo-fit.png' });
  console.log(JSON.stringify({ toast1, toast2, lbl, url: p.url(), errs }, null, 1));
  await b.close();
})();
