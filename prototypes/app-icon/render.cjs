// Usage: node render.cjs <page url> <out dir>   Screenshots the comparison page (phone + desktop) and exports every icon as a 1024 PNG.
const { chromium } = require(process.env.HOME + '/Projects/Sotto/node_modules/playwright');
(async () => { const [url, out] = process.argv.slice(2); const b = await chromium.launch({ executablePath:'/usr/bin/chromium' }); const errs=[];
  const ph = await b.newPage({ viewport:{ width:390, height:844 }, deviceScaleFactor:2, isMobile:true }); ph.on('pageerror', e => errs.push(e.message));
  await ph.goto(url); await ph.waitForTimeout(300); await ph.screenshot({ path:`${out}/page-phone.png`, fullPage:true });
  const dk = await b.newPage({ viewport:{ width:1100, height:900 } }); await dk.goto(url); await dk.waitForTimeout(300); await dk.screenshot({ path:`${out}/page-desktop.png`, fullPage:true });
  const ex = await b.newPage({ viewport:{ width:1024, height:1024 } });
  for (const k of ['A','B','C']) for (const kind of ['light','dark','tinted']) { await ex.goto(`${url}?export=${k}&kind=${kind}`); await ex.waitForTimeout(100); await ex.locator('#exp').screenshot({ path:`${out}/${k}-${kind}.png` }); }
  console.log(JSON.stringify({ errs })); await b.close(); })();
