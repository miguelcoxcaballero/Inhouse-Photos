// Recorrido de interfaz con Chromium (Playwright). Uso: node ui-v3-test.mjs [ruta-a-playwright]
// Abre el HTML autónomo, juega una jornada, abre paneles, visita una obra y comprueba el móvil.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {fileURLToPath, pathToFileURL} from 'node:url';
const root = path.dirname(fileURLToPath(import.meta.url));
const pwPath = process.argv[2] || process.env.PLAYWRIGHT_MODULE || 'playwright';
const {chromium} = await import(pwPath.startsWith('/') ? pathToFileURL(pwPath).href : pwPath);
const html = pathToFileURL(path.join(root, '../outputs/Iberia-Ferroviaria.html')).href;
const out = path.join(root, '../investigacion/verificacion-v0.3');
fs.mkdirSync(out, {recursive: true});
const shot = (page, name) => page.screenshot({path: path.join(out, name + '.png')});
const browser = await chromium.launch({executablePath: fs.existsSync('/opt/pw-browsers/chromium') ? undefined : undefined});
const errors = [], done = [];
const page = await browser.newPage({viewport: {width: 1500, height: 940}});
page.on('pageerror', e => errors.push(e.message));
page.on('console', m => { if (m.type() === 'error') errors.push(m.text()); });
await page.goto(html);
await page.waitForTimeout(1800);
await shot(page, '01-portada');
await page.click('[data-action=begin]');
await page.click('.choice >> nth=0');
done.push('Portada y primera decisión.');
// Día laborable de primavera
await page.evaluate(() => { const g = window.railwayGame, s = g.state(), E = g.engine; s.month = 4; s.ops.day = 11; for (let d; (d = E.pendingDecision(s));) E.decide(s, d.id, 0); document.getElementById('modal').close(); g.render(); });
await page.click('[data-action=day-start]');
const first = await page.evaluate(() => window.railwayGame.minute());
const plan = await page.evaluate(() => window.railwayGame.plan());
assert(Math.abs(first - Math.min(...plan.map(t => t.dep))) < 2, "la jornada empieza con la primera salida");
assert(plan.filter(t => t.real).length > 500);
await page.evaluate(() => window.railwayGame.setMinute(8 * 60 + 20));
await page.waitForTimeout(1200);
await shot(page, '02-mapa-dia');
done.push(`Jornada iniciada en la primera salida (${plan.length} circulaciones reales).`);
// Zoom a Madrid y selección de un tren por el mapa
await page.evaluate(() => window.railwayGame.map.focusAt(-3.69, 40.41, 60));
await page.waitForTimeout(1200);
const picked = await page.evaluate(() => { const m = window.railwayGame.map, p = m.trainPoints?.[0]; if (!p) return null; window.railwayGame.pick({type: 'train', id: p.id}); return p.id; });
assert(picked, 'hay trenes visibles en Madrid');
await page.waitForTimeout(800);
await shot(page, '03-madrid-tren');
done.push('Zoom sobre Madrid y ficha de un tren con sus paradas.');
// Estación
await page.evaluate(() => { const S = window.railwayGame.schedule, st = S.STATIONS.find(s => s.id === '18000'); window.railwayGame.pick({type: 'station', id: st.i}); });
await page.waitForTimeout(600);
assert(await page.locator('#inspector .board .row').count() > 3);
await shot(page, '04-estacion-atocha');
done.push('Panel de salidas de Madrid-Atocha Cercanías.');
// Línea: plan de servicio
await page.evaluate(() => { window.railwayGame.map.reset(); window.railwayGame.selectRoute('c-madrid-c4a'); });
await page.waitForTimeout(1200);
await page.fill('#frequency', '40');
await page.dispatchEvent('#frequency', 'input');
assert.match(await page.textContent('#routePreview'), /unidad/);
await shot(page, '05-linea-c4a');
done.push('Ficha de línea con histograma de salidas y previsión.');
// Paneles
for (const [screen, name] of [['ops', '06-jornada'], ['network', '07-red'], ['timetables', '08-horarios'], ['fleet', '09-flota'], ['market', '10-compras'], ['works', '11-obras'], ['finance', '12-finanzas'], ['story', '13-historia'], ['archive', '14-archivo']]) {
  await page.evaluate(s => window.railwayGame.navigate(s), screen);
  await page.waitForTimeout(400);
  assert(await page.locator('#drawer h1').count() === 1, 'panel ' + screen);
  await shot(page, name);
}
await page.evaluate(() => window.railwayGame.navigate('timetables'));
await page.fill('#ttStation', 'bilbao-abando');
await page.waitForTimeout(600);
assert(await page.locator('#drawer .board .row').count() > 5, 'panel de salidas de Abando');
await shot(page, '08b-horarios-abando');
done.push('Nueve paneles abiertos sin errores.');
// Obra con zoom
await page.evaluate(() => { const g = window.railwayGame, s = g.state(), E = g.engine; E.startProject(s, 'encina'); for (let i = 0; i < 12; i++) { for (let d; (d = E.pendingDecision(s));) E.decide(s, d.id, 0); E.step(s); } for (let d; (d = E.pendingDecision(s));) E.decide(s, d.id, 0); document.getElementById('modal').close(); g.render(); g.navigate('works'); });
await page.waitForTimeout(400);
await page.click('[data-action=visit-work][data-id=encina]');
await page.waitForTimeout(1300);
await shot(page, '15-obra-encina');
done.push('Visita de obra con fases sobre el trazado.');
// Noche y cierre
await page.evaluate(() => { const g = window.railwayGame; g.setLayer('network'); g.map.focusAt(2.12, 41.4, 12); });
if (await page.locator('[data-action=day-start]').count()) await page.click('[data-action=day-start]');
await page.evaluate(() => window.railwayGame.setMinute(22 * 60 + 10));
await page.waitForTimeout(1300);
assert.equal(await page.evaluate(() => document.body.dataset.sky), 'night');
await shot(page, '16-noche-barcelona');
await page.click('[data-action=day-end]');
await page.waitForTimeout(600);
await shot(page, '17-parte-del-dia');
await page.click('[data-action=day-next]');
done.push('Noche con luces y parte de la jornada.');
// Horario real completo
await page.evaluate(() => { const g = window.railwayGame; g.map.reset(); g.setLayer('real'); g.setMinute(8 * 60); });
await page.waitForTimeout(1300);
await shot(page, '18-horario-real');
done.push('Capa de horario real con todas las circulaciones.');
// Móvil
const m = await browser.newPage({viewport: {width: 390, height: 844}, deviceScaleFactor: 2});
m.on('pageerror', e => errors.push('móvil: ' + e.message));
await m.goto(html);
await m.waitForTimeout(1500);
await m.click('[data-action=begin]');
await m.click('.choice >> nth=0');
await m.click('[data-action=day-start]');
await m.evaluate(() => window.railwayGame.setMinute(9 * 60));
await m.waitForTimeout(1000);
await shot(m, '20-movil-mapa');
await m.evaluate(() => window.railwayGame.selectRoute('c-madrid-c5'));
await m.waitForTimeout(900);
await shot(m, '21-movil-linea');
assert.equal(await m.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
done.push('Móvil 390 × 844 sin desbordamiento horizontal.');
await browser.close();
assert.deepEqual(errors, []);
console.log(done.map(x => '✓ ' + x).join('\n'));
