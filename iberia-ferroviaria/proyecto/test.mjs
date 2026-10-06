import assert from 'node:assert/strict';
import fs from 'node:fs';
import {MODEL,PROJECTS,HISTORICAL_ORDERS} from './dist/data.js';
import * as E from './dist/engine.js';
function start(){const s=E.initialState();s.started=true;E.decide(s,'inaugural',0);return s;}
function tick(s){let d;while(d=E.pendingDecision(s)){const ix=d.choices.findIndex(c=>s.cash>=-(c.effects.cash||0));E.decide(s,d.id,ix<0?0:ix);}return E.step(s);}
const summary=[];
{
 const s=start(),other=E.initialState();s.routes[0].fare=99;assert.notEqual(other.routes[0].fare,99);summary.push('Partidas independientes y copia de datos base.');
 const r=s.routes.find(r=>r.id==='murcia-cartagena');assert.throws(()=>E.configureRoute(s,r.id,'f4',2,8),/compatibles/);E.configureRoute(s,r.id,'f2',2,8);assert.equal(r.active,true);assert.equal(r.units,E.requiredUnits(r,MODEL.s599,2));assert(r.units>=1);assert.throws(()=>E.configureRoute(s,'bilbao-santander','f2',2,8),/compatibles/);summary.push('Anchos y electrificación impiden asignaciones incompatibles.');
 const f=s.fleet.find(f=>f.id==='f2');assert.throws(()=>E.refurbish(s,f.id,f.qty),/libres/);const cash=s.cash;E.refurbish(s,f.id,2);assert(s.cash<cash);assert.equal(s.stats.refurbished,0);for(let i=0;i<5;i++)tick(s);assert.equal(s.stats.refurbished,2);summary.push('Reforma retira unidades disponibles durante 5 meses sin duplicarlas.');
 assert.throws(()=>E.configureRoute(s,r.id,'f2',100,8),/1–\d+ salidas/);assert.throws(()=>E.buy(s,'s599',-1),/1 y 30/);const before=s.cash;assert.throws(()=>E.buy(s,'s106f',2),/disponible/);assert.equal(s.cash,before);summary.push('Entradas inválidas y modelos futuros no alteran tesorería.');
}
{
 const s=start(),q=E.purchaseQuote(s,'s599',4);const before=s.cash;const id=E.buy(s,'s599',4);assert(Math.abs(s.cash-(before-q.deposit))<1e-8);for(let i=0;i<q.lead-1;i++)tick(s);assert.equal(s.orders.find(o=>o.id===id).delivered,0);for(let i=0;i<20;i++)tick(s);const order=s.orders.find(o=>o.id===id);assert.equal(order.delivered,4);assert(Math.abs(order.remaining)<1e-8);assert.equal(s.stats.delivered,4);const total=s.fleet.filter(f=>f.origin==='Compra '+id).reduce((n,f)=>n+f.qty,0);assert.equal(total,4);summary.push('Anticipo 30%, lotes de entrega, saldo 70% y recepción única.');
 const bad=structuredClone(s);bad.routes[0].units=999;assert.throws(()=>E.validateSave(bad));assert.equal(E.validateSave(JSON.parse(JSON.stringify(s))).month,s.month);summary.push('Guardado exportado recuperable; asignaciones duplicadas rechazadas.');
}
{
 const s=start();E.startProject(s,'almeria');assert.throws(()=>E.startProject(s,'almeria'),/ya/);assert(!E.isUnlocked(s,s.routes.find(r=>r.id==='murcia-almeria')));for(let i=0;i<90&&!s.ended;i++)tick(s);assert(s.projects.find(p=>p.id==='almeria').done);assert(E.isUnlocked(s,s.routes.find(r=>r.id==='murcia-almeria')));summary.push('Infraestructura bloqueada hasta terminar obra; los retrasos son acotados.');
}
// End-to-end strategy uses real player actions and engine ticks, without injecting money or bypassing objectives.
{
 const s=start();E.refurbish(s,'f2',2);E.buy(s,'s599',4);
 const projects=['encina','almeria','teruel','loja'];let custom=false;
 for(let month=0;month<348&&!s.ended;month++){
  for(const r of s.routes.filter(r=>!r.active&&E.isUnlocked(s,r))){const want=Math.max(1,Math.round((r.real?r.baseFrequency:4)*.75));const f=s.fleet.find(f=>f.qty&&f.condition>=30&&E.compatible(r,MODEL[f.model])&&E.available(s,f)>=E.requiredUnits(r,MODEL[f.model],want));if(f&&s.cash>100&&E.metrics(s,r,{active:true,fleet:f.id,frequency:want,units:E.requiredUnits(r,MODEL[f.model],want)}).net>-.3)E.configureRoute(s,r.id,f.id,want,r.fare);}
  if(s.month%12===6&&s.cash>300)for(const m of [s.month>=72?'s480':'s449','s599','s112','s130'])try{E.buy(s,m,10)}catch{}
  for(const q of [...(s.requests||[])]){const r=s.routes.find(r=>r.id===q.route);try{if(q.type==='station')E.upgradeStation(s,q.city);else if(r.active&&q.type==='fare')E.configureRoute(s,r.id,r.fleet,r.frequency,q.target);else if(r.active&&q.type==='more'&&E.available(s,s.fleet.find(f=>f.id===r.fleet),r.id)>=E.requiredUnits(r,MODEL[s.fleet.find(f=>f.id===r.fleet).model],q.target))E.configureRoute(s,r.id,r.fleet,q.target,r.fare);}catch{}}
  if(s.cash>350){const c=['mad','bcn','vlc','sev','zar','mal','bil','vll','ali','cor'].find(c=>(s.stations[c]||0)<3);if(c)E.upgradeStation(s,c);}
  if(s.month>12&&s.cash>250){const id=projects.find(id=>!s.projects.some(p=>p.id===id));if(id)E.startProject(s,id);}
  if(s.stats.upgrades+s.projects.filter(p=>p.type==='upgrade'&&!p.done).length<3&&s.cash>150){const r=s.routes.find(r=>r.active&&!s.projects.some(p=>p.id==='upgrade-'+r.id));if(r)E.upgradeRoute(s,r.id);}
  if(!custom&&s.month>140&&s.cash>400){E.buildLine(s,'mur','vlc','regional');custom=true;}
  s.maintenance=1.2;
  if(E.chapterReady(s))E.claimChapter(s);
  tick(s);
 }
 assert.equal(s.month,348);assert.equal(s.ended,true);assert.equal(s.ending,'2050');assert.equal(s.claimed.length,5);assert(s.routes.filter(r=>r.active).length>=55);assert(E.dailyTrains(s)>=900);assert(s.stats.requests>=25);assert(s.projects.some(p=>p.type==='custom'&&p.done));assert(E.finalScore(s)>=80);assert.equal(E.step(s),false);assert.throws(()=>E.buy(s,'s599',1),/terminado/);
 const tender=HISTORICAL_ORDERS.find(o=>o.tender);assert(!s.orders.some(o=>o.id===tender.id));
 for(const h of HISTORICAL_ORDERS.filter(o=>o.model&&MODEL[o.model].category!=='Cercanías')){assert.equal(s.orders.find(o=>o.id===h.id).delivered,h.qty);}
 summary.push('Campaña completa por acciones legales: 5 capítulos, obras, línea nueva y cierre de 2050.');
 summary.push('Licitación 2026 sin entregas automáticas; pedidos históricos sin duplicar.');
 fs.mkdirSync('../work',{recursive:true});fs.writeFileSync('../work/end-state.json',JSON.stringify({month:s.month,cash:s.cash,score:E.finalScore(s),chapters:s.claimed,active:s.routes.filter(r=>r.active).length,passengers:s.stats.passengers},null,2));
}
console.log(summary.map(x=>'✓ '+x).join('\n'));

