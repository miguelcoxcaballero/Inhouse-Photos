// Recorrido de interfaz con Chromium (Playwright) sobre el HTML autónomo. Uso: node ui-test.mjs [ruta-a-playwright]
// Tutorial completo, mapas de anchos y electrificación, fichas de tramo, cambiador y relación, obras, páginas,
// relación nueva, jornada con parte, imprevisto con retrato y vista de móvil. Guarda capturas en investigacion/verificacion-2.0.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {fileURLToPath, pathToFileURL} from 'node:url';
const root = path.dirname(fileURLToPath(import.meta.url));
const pwPath = process.argv[2] || process.env.PLAYWRIGHT_MODULE || 'playwright';
const {chromium} = await import(pwPath.startsWith('/') ? pathToFileURL(pwPath).href : pwPath);
const html = pathToFileURL(path.join(root, '../outputs/Iberia-Ferroviaria.html')).href;
const out = path.join(root, '../investigacion/verificacion-2.0');
fs.mkdirSync(out, {recursive: true});
const browser = await chromium.launch({args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--autoplay-policy=no-user-gesture-required']});
const errors = [], done = [];
const page = await browser.newPage({viewport: {width: 1440, height: 900}});
page.on('pageerror', e => errors.push(e.message));
page.on('console', m => { if (m.type() === 'error') errors.push(m.text()); });
const shot = name => page.screenshot({path: path.join(out, name + '.png')});
const game = (fn, arg) => page.evaluate(fn, arg);
const step = () => page.evaluate(() => document.getElementById('coach')?.dataset.step ?? 'none');
const wait = ms => page.waitForTimeout(ms);

await page.goto(html); await wait(1500);
assert.equal(await page.title(), 'Iberia Ferroviaria · Renfe 2022–2050');
assert.equal(await page.locator('a[href^="http"]').count(), 0, 'sin enlaces a webs externas');
await shot('01-portada');
// Decisión inaugural con retrato propio de la ministra.
await page.click('[data-action=begin]'); await wait(400);
const portrait = await page.locator('#modal .art.portrait').getAttribute('style');
assert(/data:image\/svg\+xml/.test(portrait), 'la decisión lleva el retrato ilustrado');
assert.equal(await page.locator('#modal .plate b').textContent(), 'Raquel Sanz');
await shot('02-decision');
await page.click('.choice >> nth=0'); await page.waitForSelector('#coach');
done.push('Portada y decisión inaugural con retrato de la ministra.');

// Tutorial completo, paso a paso, con lo que pide cada paso.
const act = async (fn, expect) => { await fn(); await wait(350); if (expect !== undefined) assert.equal(await step(), String(expect), 'paso del tutorial ' + expect); };
await act(() => page.click('[data-action=tutorial-next]'), 1);
await act(() => game(() => window.railwayGame.pick({type: 'city', id: 'mad'})), 2);
await act(() => page.click('[data-action=tutorial-next]'), 3);
await act(() => page.click('[data-action=freq-up][data-id=madrid-valencia]'), 4);
await act(() => page.click('[data-action=open-route][data-id=madrid-salamanca]'), 5);
await shot('03-tutorial-anchos');
await act(() => page.click('[data-layer=gauge]'), 6);
await act(() => page.click('[data-layer=power]'), 7);
await act(() => page.click('[data-action=tutorial-next]'), 8);
await act(() => page.click('[data-action=tutorial-next]'), 9);
await act(() => page.click('[data-action=day-start]'), 10);
await act(() => page.click('[data-action=speed] >> nth=2'), 11);
// el reloj corre de verdad (las llegadas cuentan en «Hoy»); las incidencias se atienden al saltar
await game(() => window.railwayGame.setMinute(9 * 60));
for (let k = 0; k < 160 && Number(await step()) < 13; k++) {
  const pill = await page.$('.alert-pill button');
  if (pill) { await pill.click().catch(() => {}); await wait(250); const r = await page.$('[data-action=respond]'); if (r) await r.click().catch(() => {}); }
  else await game(() => window.railwayGame.play());
  await wait(300);
}
assert(Number(await step()) >= 12, 'el tutorial pasa por la jornada');
while (Number(await step()) < 14) await act(() => page.click('[data-action=tutorial-next]'));
await act(() => page.click('[data-action=day-end]'), 15);
await shot('04-tutorial-parte');
await act(() => page.click('#modal [data-action=day-next]'));
if (await game(() => document.getElementById('modal').open)) await page.click('.choice >> nth=0');
await wait(300);
assert.equal(await step(), '16');
await act(() => page.click('[data-screen=fleet]'), 17);
await act(() => page.click('[data-action=tutorial-next]'), 'none');
assert.equal(await game(() => window.railwayGame.state().tutorial.done), true);
done.push('Tutorial de 18 pasos completo: cada paso avanza al hacer lo que pide.');

// Mapas de anchos y electrificación, fichas de tramo y de cambiador.
await page.click('[data-action=close-drawer]').catch(() => {});
await game(() => window.railwayGame.setLayer('gauge')); await wait(500);
assert(/Ancho estándar/.test(await page.locator('#legend').textContent()), 'leyenda de anchos');
await game(() => window.railwayGame.pick({type: 'tramo', id: 'trb-sor'})); await wait(300);
assert.equal(await page.locator('#inspector [data-action=work]').count(), 3, 'tres obras posibles en Torralba — Soria');
await shot('05-tramo');
await game(() => window.railwayGame.setLayer('power')); await wait(500);
assert(/25 kV/.test(await page.locator('#legend').textContent()), 'leyenda de electrificación');
await page.click('#inspector [data-action=work][data-work=electrify]'); await wait(300);
assert(/Electrificar/i.test(await page.locator('#modal .kicker').textContent()));
await page.click('[data-action=confirm-work]'); await wait(300);
assert(await game(() => window.railwayGame.state().projects.some(p => p.work === 'electrify' && p.target === 'trb-sor')), 'obra adjudicada');
await game(() => window.railwayGame.pick({type: 'node', id: 'vlc'})); await wait(300);
assert.equal(await page.locator('#inspector [data-work=changer]').count(), 1, 'se puede construir un cambiador en València');
await shot('06-cambiador');
await game(() => window.railwayGame.selectRoute('madrid-gijon')); await wait(300);
assert.equal(await page.locator('#inspector .option.no').count() >= 1 && await page.locator('#inspector .option.ok').count() >= 1, true, 'qué puede circular hacia Gijón');
done.push('Mapas de anchos y electrificación; obra de catenaria adjudicada; cambiador y relación con lo que falta.');

// Páginas: Red, Trenes, Obras y Despacho, con sus pestañas.
for (const [screen, tabAction, n] of [['network', 'net-view', 2], ['fleet', 'fleet-tab', 3], ['works', 'works-tab', 4], ['story', 'office-tab', 3]]) {
  await game(s => window.railwayGame.navigate(s), screen); await wait(300);
  if (await game(() => document.getElementById('drawer').classList.contains('hidden'))) { await game(s => window.railwayGame.navigate(s), screen); await wait(300); }
  const tabs = page.locator(`#drawer [data-action=${tabAction}]`);
  assert.equal(await tabs.count(), n, 'pestañas de ' + screen);
  for (let i = 0; i < n; i++) { await tabs.nth(i).click(); await wait(200); }
  await shot('07-' + screen);
}
done.push('Cuatro páginas con pocas pestañas: Red (2), Trenes (3), Obras (4) y Despacho (3).');

// Relación nueva entre dos ciudades.
await game(() => window.railwayGame.navigate('network')); await wait(200);
if (await game(() => document.getElementById('drawer').classList.contains('hidden'))) await game(() => window.railwayGame.navigate('network'));
await page.click('[data-action=net-view][data-id=routes]'); await page.click('[data-action=new-service]'); await wait(300);
await page.selectOption('#svcA', 'tol'); await page.selectOption('#svcB', 'bcn'); await wait(300);
assert(await page.locator('#svcPreview .option').count() === 3, 'vista previa de AVE, Alvia e híbrido');
const before = await game(() => window.railwayGame.state().routes.length);
await page.click('[data-action=confirm-service]'); await wait(300);
assert.equal(await game(() => window.railwayGame.state().routes.length), before + 1, 'relación Toledo — Barcelona creada');
done.push('Relación nueva Toledo — Barcelona con vista previa por producto.');

// Jornada completa e imprevisto con retrato.
await page.keyboard.press('Escape'); await game(() => window.railwayGame.navigate('ops')); await wait(200);
await page.click('[data-action=day-start]'); await game(() => window.railwayGame.setMinute(600)); await wait(400);
await shot('08-jornada');
await page.click('[data-action=day-end]'); await wait(500);
await game(() => { window.railwayGame.state().event = 'cows'; });
await page.click('#modal [data-action=day-next]'); await wait(500);
assert(/Imprevisto/.test(await page.locator('#modal .kicker').textContent()), 'imprevisto con su ventana');
assert(/data:image\/svg/.test(await page.locator('#modal .art.portrait').getAttribute('style')), 'el imprevisto lleva retrato');
await shot('09-imprevisto');
await page.click('.choice >> nth=0'); await wait(300);
assert.equal(await game(() => window.railwayGame.state().event), null);
done.push('Jornada con parte del día e imprevisto con retrato del personaje.');

// Móvil.
const phone = await browser.newPage({viewport: {width: 390, height: 844}, deviceScaleFactor: 2, isMobile: true, hasTouch: true});
phone.on('pageerror', e => errors.push('móvil: ' + e.message));
await phone.goto(html); await phone.waitForTimeout(1200);
await phone.click('[data-action=begin]'); await phone.waitForTimeout(300); await phone.click('.choice >> nth=0'); await phone.waitForTimeout(300);
await phone.click('[data-action=tutorial-skip]').catch(() => {});
await phone.evaluate(() => window.railwayGame.pick({type: 'city', id: 'bcn'})); await phone.waitForTimeout(400);
assert(await phone.evaluate(() => document.scrollingElement.scrollWidth <= innerWidth + 1), 'sin desplazamiento horizontal en móvil');
await phone.screenshot({path: path.join(out, '10-movil.png')});
done.push('Vista de móvil sin desplazamiento horizontal.');

assert.deepEqual(errors, [], 'sin errores de JavaScript');
console.log(done.map(x => '✓ ' + x).join('\n'));
await browser.close();
