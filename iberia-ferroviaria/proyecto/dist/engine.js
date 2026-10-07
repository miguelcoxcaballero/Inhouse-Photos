import {MODELS,MODEL,HISTORICAL_ORDERS,PROJECTS,CITY,CITIES,POP} from './data.js';
import {ALL_ROUTES,ROUTE_DEF,makeRoute} from './network.js';
import {CHAPTERS,DECISIONS,EVENTS} from './story.js';
import * as I from './infra.js';
export const clamp=(v,a,b)=>Math.max(a,Math.min(b,v));
export const yearOf=s=>2022+Math.floor(Math.min(s.month,347)/12);
export const dateOf=(m)=>new Date(Date.UTC(2022+Math.floor(m/12),m%12,1)).toLocaleDateString('es-ES',{month:'long',year:'numeric',timeZone:'UTC'});
export const routeName=r=>r.name||r.ends.map(id=>CITY[id]?.name||id).join(' — ');
export const gameDate=s=>new Date(Date.UTC(2022+Math.floor(Math.min(s.month,347)/12),Math.min(s.month,347)%12,s.ops?.day||1)).toISOString().slice(0,10);
const copy=x=>JSON.parse(JSON.stringify(x));
// Servicios con los que arranca la campaña: fracción de la oferta publicada y material.
const START_SERVICE={'madrid-barcelona':[.25,'s112'],'madrid-valencia':[.3,'s103'],'madrid-sevilla':[.3,'s100'],'madrid-malaga':[.25,'s112'],'madrid-alicante':[.3,'s103'],'madrid-santander':[.5,'s130'],'madrid-pamplona':[.4,'s130'],'madrid-badajoz':[.35,'s730']};
export const maxFrequency=r=>r.real?r.baseFrequency:12;
/** Índice de costes: energía, personal y canon suben cada año; las tarifas, solo si las sube el jugador. */
export const costIndex=s=>1+.012*Math.max(0,yearOf(s)-2022);
export function initialState(seed=72022){
 const s={version:3,stations:{},requests:[],month:0,seed,cash:500,debt:0,reputation:50,satisfaction:58,policy:'public',started:false,ended:false,maintenance:1,chapter:0,claimed:[],decided:[],flags:{},history:[],log:[],orders:[],projects:[],refits:[],routes:copy(ALL_ROUTES),fleet:[],infra:I.initialInfra(),nextId:20,stats:{requests:0,refurbished:0,purchased:0,delivered:0,upgrades:0,built:0,passengers:0},last:{revenue:0,cost:0,subsidy:0,net:0,passengers:0},seen:[],event:null,events:[]};
 [['s100',12,56,1992],['s112',22,78,2010],['s103',16,82,2007],['s130',14,72,2008],['s730',8,74,2012],['s120',8,64,2006]].forEach(([model,qty,condition,born],i)=>s.fleet.push({id:'f'+i,model,qty,condition,born,origin:'Parque inicial'}));
 for(const r of s.routes){const st=START_SERVICE[r.id];if(!st)continue;const f=s.fleet.find(f=>f.model===st[1]);if(!routeCheck(s,r,MODEL[f.model]).ok)continue;r.active=true;r.fleet=f.id;r.frequency=Math.max(1,Math.round(maxFrequency(r)*st[0]));r.units=requiredUnits(s,r,MODEL[f.model],r.frequency);}
 historic(s);generateRequest(s,true);generateRequest(s,true);log(s,'Te sientas en el despacho','Ocho servicios funcionan a medio gas. El resto de la red espera trenes, obras o que alguien se acuerde de ella.');return s;
}
export function random(s){s.seed=(Math.imul(s.seed,1664525)+1013904223)>>>0;return s.seed/4294967296;}
export function log(s,title,body){s.log.unshift({month:Math.min(s.month,347),title,body});s.log=s.log.slice(0,100);}
// ---- Red: qué puede circular por cada relación
/** Recorrido de la relación con un modelo de tren: tiempo, kilómetros, cambios de ancho y, si no puede, qué falta. */
export function routeCheck(s,r,m){return I.plan(s,r.via,I.profileOf(m));}
/** Lo que permite la red para AVE, Alvia eléctrico y Alvia híbrido. */
export function routeOptions(s,r){return {ave:I.plan(s,r.via,I.PROFILES.ave),alvia:I.plan(s,r.via,I.PROFILES.alvia),hybrid:I.plan(s,r.via,I.PROFILES.hybrid)};}
export const canRun=(s,r,m)=>!!m&&routeCheck(s,r,m).ok;
export function isUnlocked(s,r){const o=routeOptions(s,r);return o.ave.ok||o.alvia.ok||o.hybrid.ok;}
export function product(s,r){const f=r.fleet&&s.fleet.find(f=>f.id===r.fleet);return f?MODEL[f.model].family:null;}
/** Mejor producto posible hoy: AVE si la red lo permite; si no, Alvia. */
export function bestProduct(s,r){const o=routeOptions(s,r);return o.ave.ok?'AVE':o.alvia.ok||o.hybrid.ok?'Alvia':null;}
export function requiredUnits(s,r,m,f){
 if(r.real){const p=routeCheck(s,r,m),slow=clamp((p.ok&&r.minutes?p.minutes/r.minutes:1),.8,1.35);return Math.max(1,Math.ceil(r.peak*Math.min(1,f/r.baseFrequency)*1.12*slow));}
 const p=routeCheck(s,r,m),minutes=p.ok?p.minutes:r.km/1.5,hours=15,interval=hours/Math.max(1,f-1),cycle=(minutes/60+.6)*2;
 return Math.max(2,Math.ceil(cycle/Math.max(.1,interval)));
}
export const available=(s,f,except=null)=>f.qty-s.routes.filter(r=>r.active&&r.fleet===f.id&&r.id!==except).reduce((n,r)=>n+r.units,0);
export function metrics(s,r,override={}){
 r={...r,...override};const f=s.fleet.find(f=>f.id===r.fleet),m=f&&MODEL[f.model];
 if(!r.active||!m)return {passengers:0,revenue:0,cost:0,subsidy:0,net:0,occupancy:0,share:0,punctuality:0,trainTime:0,busShare:.62,otherShare:.38};
 const p=routeCheck(s,r,m),km=r.real?r.km:(p.km||r.km),pathMin=p.ok?p.minutes:km/1.5;
 const trainTime=(r.real&&r.minutes?(r.minutes+pathMin)/2:pathMin)/60+.1,busTime=km/73+.5;
 const year=yearOf(s),season=1+.10*Math.sin(s.month/12*Math.PI*2),recovery=Math.min(1.25,.72+s.month*.009);
 const growth=1+Math.min(.55,(year-2022)*.012),ave=m.family==='AVE';
 const stationBoost=1+.06*((s.stations?.[r.ends[0]]||0)+(s.stations?.[r.ends[1]]||0));
 const on=k=>s.flags[k]>s.month,demand=r.demand*recovery*growth*season*stationBoost*(ave?1.15:1)*(on('passes')&&!ave?1.15:1)*(on('hype')&&ave?1.1:1)*(on('tourism')?1.1:1);
 const reliability=clamp(67+f.condition*.29+(s.maintenance-1)*7+r.level*2+(stationBoost-1)*12-(p.changes?.length||0)*1.5-(on('strike')?10:0)-(on('heat')?5:0),50,99);
 const rivals=ave?(s.month>=10?1.5:.7):.3;
 const busFare=Math.max(4,km*.066)*(s.flags.buswar>s.month?.78:1);
 const trainWeight=Math.exp(clamp(1.6-trainTime*.2-r.fare/35+Math.min(r.frequency,40)*.045+(reliability-80)*.018+(s.reputation-50)*.012+r.level*.12,-3,4));
 const busWeight=Math.exp(clamp(1.1-busTime*.2-busFare/35,-3,4));
 const otherWeight=.33+rivals*.3,weight=trainWeight+busWeight+otherWeight;
 const share=trainWeight/weight,capacity=m.seats*r.frequency*2*30;
 const passengers=Math.round(Math.min(capacity*.98,demand*share)),revenue=passengers*r.fare/1e6;
 // Coste por tren-km: energía (el híbrido quema gasóleo), personal, canon y mantenimiento (parámetros de juego).
 const energy=(s.flags.energy>s.month?1.22:1),trainKm=r.frequency*2*30*km,operating=trainKm*(m.energy*2.8*energy+(ave?17:12))*costIndex(s)/1e6;
 const cost=operating+r.units*.03*s.maintenance+.06+r.level*.025;
 const subsidy=ave?0:trainKm*(s.policy==='public'?2.2:1.6)/1e6+.04;
 return {passengers,revenue,cost,subsidy,net:revenue+subsidy-cost,occupancy:passengers/capacity,share,punctuality:reliability,trainTime,busShare:busWeight/weight,otherShare:otherWeight/weight};
}
export function balance(s){
 const parts=s.routes.filter(r=>r.active).map(r=>metrics(s,r));
 const sum=k=>parts.reduce((n,p)=>n+p[k],0),passengers=sum('passengers');
 const overhead=(9+s.fleet.reduce((n,f)=>n+f.qty*.035,0))*costIndex(s)+s.debt*.004;
 const subsidy=sum('subsidy')+(s.policy==='public'?3.5:2)+(s.flags.rural>s.month?6:0);
 const cost=sum('cost')+overhead,revenue=sum('revenue');
 return {passengers,revenue,cost,subsidy,net:revenue+subsidy-cost,punctuality:parts.length?sum('punctuality')/parts.length:0,share:parts.length?sum('share')/parts.length:0};
}
export function configureRoute(s,id,fleetId,frequency,fare){
 ensurePlaying(s);const r=s.routes.find(x=>x.id===id),f=s.fleet.find(x=>x.id===fleetId);
 if(!r||!f)throw Error('Elige una relación y un tren, que no es tan difícil.');
 const m=MODEL[f.model];frequency=Number(frequency);fare=Number(fare);
 if(!Number.isInteger(frequency)||frequency<1||frequency>maxFrequency(r)||!Number.isFinite(fare)||fare<1.5||fare>150)throw Error(`Entre 1 y ${maxFrequency(r)} salidas por sentido, y una tarifa de 1,5 a 150 €.`);
 const p=routeCheck(s,r,m);
 if(!p.ok)throw Error(`El ${m.family} no puede ir por ahí: ${I.faultText(s,p.faults[0]).toLowerCase()}.`);
 if(f.condition<30)throw Error('Este tren está para el desguace. Mándalo al taller antes de sacarlo.');
 const units=requiredUnits(s,r,m,frequency);
 if(available(s,f,r.id)<units)throw Error(`Necesitas ${units} trenes y en ese lote solo quedan ${available(s,f,r.id)} libres.`);
 const opening=!r.active;if(opening&&s.cash<4)throw Error('Ni para los 4 M€ de la reapertura llega la caja.');
 if(opening)s.cash-=4;Object.assign(r,{fleet:fleetId,frequency,fare,units,active:true});delete r.cut;
 if(opening)log(s,'Servicio en marcha',routeName(r)+' · '+m.family);return r;
}
export function closeRoute(s,id){ensurePlaying(s);const r=s.routes.find(r=>r.id===id);if(!r||!r.active)throw Error('Ese servicio ya está cerrado.');r.active=false;r.fleet=null;r.units=0;s.reputation=clamp(s.reputation-1,5,100);log(s,'Servicio suspendido',routeName(r));}
export function upgradeRoute(s,id){ensurePlaying(s);const r=s.routes.find(r=>r.id===id);if(!r||r.level>=3)throw Error('Ya está al máximo. Más no se puede.');if(s.projects.some(p=>p.id==='upgrade-'+id&&!p.done))throw Error('La mejora ya está en marcha.');const cost=12+12*r.level;spend(s,cost);s.projects.push({id:'upgrade-'+id,type:'upgrade',route:id,due:s.month+4,started:s.month,cost,done:false});log(s,'Mejora contratada',routeName(r)+' · información, accesibilidad y fiabilidad.');}
export function purchaseQuote(s,model,qty){
 const m=MODEL[model];qty=Number(qty);if(!m||!Number.isInteger(qty)||qty<1||qty>30)throw Error('Entre 1 y 30 unidades.');
 const price=m.price*(1+Math.max(0,yearOf(s)-2022)*.018),total=price*qty;
 const backlog=s.orders.filter(o=>!o.historical&&o.delivered<o.qty).reduce((n,o)=>n+o.qty-o.delivered,0);
 const lead=Math.max(16,m.lead+Math.floor(backlog/10)*2+(s.flags.backlog>s.month?8:0)-(s.flags.factory>s.month?6:0));
 return {total,deposit:total*.3,remaining:total*.7,lead,last:lead+Math.ceil(qty/2)-1,unit:price};
}
export function buy(s,model,qty){ensurePlaying(s);if(!MODEL[model]||yearOf(s)<MODEL[model].year)throw Error('Ese modelo todavía no se vende.');const q=purchaseQuote(s,model,qty);spend(s,q.deposit);const id='o'+s.nextId++;s.orders.push({id,model,qty:Number(qty),delivered:0,start:s.month,first:s.month+q.lead,next:s.month+q.lead,total:q.total,remaining:q.remaining,unit:q.unit,delay:0,historical:false});s.stats.purchased+=Number(qty);log(s,'Pedido firmado',`${qty} × ${MODEL[model].name}. Primera entrega: ${dateOf(s.month+q.lead)}, si el fabricante quiere.`);return id;}
export function refurbish(s,id,qty){ensurePlaying(s);const f=s.fleet.find(f=>f.id===id);qty=Number(qty);if(!f||!Number.isInteger(qty)||qty<1||available(s,f)<qty)throw Error('Solo se reforman trenes libres del lote.');spend(s,qty*MODEL[f.model].price*.12);f.qty-=qty;s.refits.push({id:'ref'+s.nextId++,model:f.model,qty,due:s.month+5,born:f.born});log(s,'Al taller',qty+' × '+MODEL[f.model].name+' · 5 meses.');}
export function sell(s,id,qty){ensurePlaying(s);const f=s.fleet.find(f=>f.id===id);qty=Number(qty);if(!f||!Number.isInteger(qty)||qty<1||available(s,f)<qty)throw Error('Solo se venden trenes libres.');const value=qty*MODEL[f.model].price*.23*(f.condition/100);s.cash+=value;f.qty-=qty;log(s,'Venta de material',qty+' × '+MODEL[f.model].name+' · '+value.toFixed(1)+' M€.');}
// ---- Obras
export function startProject(s,id){ensurePlaying(s);const p=PROJECTS.find(p=>p.id===id);if(!p)throw Error('Proyecto desconocido.');if(s.projects.some(x=>x.id===id))throw Error('Ese proyecto ya está contratado.');spend(s,p.cost);const due=Math.max(s.month+p.duration,(p.earliest-2022)*12);s.projects.push({id,type:'infrastructure',started:s.month,due,originalDue:due,cost:p.cost,done:false,delay:0});log(s,'Obra adjudicada',p.name+' · fin previsto: '+dateOf(due));}
/** ¿Usa este servicio el tramo con su tren actual? */
export function routeUses(s,r,tramo){const f=s.fleet.find(f=>f.id===r.fleet);return !!f&&routeCheck(s,r,MODEL[f.model]).tramos.some(t=>t.id===tramo);}
const worksDiscount=s=>s.flags.eufunds>s.month?.6:1;
export function workQuote(s,kind,target){
 if(kind==='changer'){if(!I.changerPossible(s,target))throw Error('Ahí no pinta nada un cambiador de ancho.');if(s.projects.some(p=>!p.done&&p.type==='changer'&&p.target===target))throw Error('Ya se está construyendo.');return {cost:Math.round(I.CHANGER_WORK.cost*worksDiscount(s)),months:I.CHANGER_WORK.months,closes:false,affected:[],label:I.CHANGER_WORK.label};}
 const w=I.tramoWorks(s,target).find(x=>x.work===kind);
 if(!w)throw Error('Esa obra no tiene sentido en este tramo.');if(w.busy)throw Error('Ya hay máquinas trabajando en este tramo.');
 const affected=w.closes?s.routes.filter(r=>r.active&&routeUses(s,r,target)):[];
 return {cost:Math.round(w.cost*worksDiscount(s)),months:w.duration,closes:!!w.closes,affected,label:w.label};
}
export function startWork(s,kind,target){
 ensurePlaying(s);const q=workQuote(s,kind,target);spend(s,q.cost);
 const id='w-'+kind+'-'+target+'-'+s.nextId++,name=kind==='changer'?'Cambiador de ancho en '+I.NODES[target].name:q.label+' · '+I.tramoDef(s,target).name;
 s.projects.push({id,type:kind==='changer'?'changer':'tramo',work:kind,target,started:s.month,due:s.month+q.months,originalDue:s.month+q.months,cost:q.cost,done:false,delay:0});
 for(const r of q.affected){r.active=false;r.fleet=null;r.units=0;r.cut=id;}
 if(q.closes)s.reputation=clamp(s.reputation-1-q.affected.length,5,100);
 s.infra.ver++;log(s,'Obra adjudicada',name+(q.affected.length?' · '+q.affected.length+' servicios cortados mientras dure':''));return id;
}
export function newLineQuote(a,b){if(!I.NODES[a]||!I.NODES[b]||a===b)throw Error('Elige dos sitios distintos.');const ca=I.NODES[a],cb=I.NODES[b],rad=Math.PI/180;const dlat=(cb.lat-ca.lat)*rad,dlon=(cb.lon-ca.lon)*rad;const hav=Math.sin(dlat/2)**2+Math.cos(ca.lat*rad)*Math.cos(cb.lat*rad)*Math.sin(dlon/2)**2;const km=Math.round(6371*2*Math.asin(Math.sqrt(hav))*1.2);return {km,cost:Math.round(km*1.1+25),duration:Math.round(42+km/10)};}
export function buildLine(s,a,b){
 ensurePlaying(s);const q=newLineQuote(a,b);
 if(I.allTramos(s).some(t=>t.kind==='lav'&&((t.a===a&&t.b===b)||(t.a===b&&t.b===a))))throw Error('Ya hay (o habrá) alta velocidad entre esos dos puntos.');
 spend(s,q.cost);const id='lav'+s.nextId++;
 s.infra.custom.push({id,a,b,km:q.km});s.infra.t[id]={g:'std',e:'25kv',v:300,b:false};s.infra.ver++;
 s.projects.push({id,type:'custom',target:id,started:s.month,due:s.month+q.duration,originalDue:s.month+q.duration,cost:q.cost,done:false,delay:0});
 if(CITIES.some(c=>c.id===a)&&CITIES.some(c=>c.id===b)&&!s.routes.some(r=>r.ends.includes(a)&&r.ends.includes(b)))s.routes.push(makeRoute('svc-'+id,[a,b],[a,b],'new',{custom:true}));
 log(s,'Línea nueva adjudicada','LAV '+I.NODES[a].name+' — '+I.NODES[b].name+' · '+q.km+' km.');return id;
}
/** Crea una relación nueva entre dos ciudades; el trazado lo decide la red. */
export function createService(s,a,b){
 ensurePlaying(s);
 if(!CITIES.some(c=>c.id===a)||!CITIES.some(c=>c.id===b)||a===b)throw Error('Elige dos ciudades distintas.');
 if(s.routes.some(r=>(r.ends[0]===a&&r.ends[1]===b)||(r.ends[0]===b&&r.ends[1]===a)))throw Error('Esa relación ya existe. Búscala en la lista.');
 if(s.routes.filter(r=>r.custom).length>=40)throw Error('Ya tienes demasiadas relaciones inventadas.');
 const r=makeRoute('svc-'+s.nextId++,[a,b],[a,b],'new',{custom:true});s.routes.push(r);log(s,'Relación nueva en estudio',routeName(r));return r.id;
}
export function loan(s,amount){ensurePlaying(s);amount=Number(amount);if(!Number.isFinite(amount)||![100,-100].includes(amount))throw Error('Operación no válida.');if(amount>0&&s.debt+amount>1500)throw Error('El banco ya no te coge el teléfono: tope de 1.500 M€.');if(amount<0&&(s.debt<100||s.cash<100))throw Error('Para amortizar 100 M€ hay que tenerlos, en la caja y en la deuda.');s.cash+=amount;s.debt+=amount;}
export function ensurePlaying(s){if(s.ended)throw Error('La campaña ha terminado. Puedes mirar las cuentas o empezar otra.');}
export function spend(s,cost){if(!Number.isFinite(cost)||cost<0)throw Error('Importe no válido.');if(s.cash<cost)throw Error('No hay dinero. Ni para eso ni para casi nada: mira Finanzas.');s.cash-=cost;}
export function pendingDecision(s){if(!s.started||s.ended)return null;return DECISIONS.find(d=>s.month>=d.at&&!s.decided.includes(d.id))||(s.event?{...EVENTS.find(e=>e.id===s.event),event:true}:null);}
/** Imprevisto del mes: sale al azar entre los que encajan con la fecha y lo que está pasando. */
function rollEvent(s){
 if(s.event||s.month<3||s.month>=346||random(s)>.32)return;
 const recent=new Set((s.events||[]).filter(e=>s.month-e.month<30).map(e=>e.id)),busy=s.projects.some(p=>!p.done&&p.type!=='upgrade');
 const pool=EVENTS.filter(e=>!recent.has(e.id)&&s.month>=(e.from||0)&&(!e.months||e.months.includes(s.month%12))&&(!e.needsWorks||busy));
 if(pool.length)s.event=pool[Math.floor(random(s)*pool.length)].id;
}
function applyEffects(s,c){
 const e=c.effects||{};if((e.cash||0)<0)spend(s,-e.cash);else s.cash+=e.cash||0;
 s.reputation=clamp(s.reputation+(e.reputation||0),5,100);s.satisfaction=clamp(s.satisfaction+(e.satisfaction||0),0,100);
 if(c.policy)s.policy=c.policy;
 if(c.flag==='fleetcare')s.fleet.forEach(f=>f.condition=clamp(f.condition+8,0,100));else if(c.flag)s.flags[c.flag]=s.month+(c.months||{passes:18,rural:60,factory:36,backlog:18}[c.flag]||12);
 if(c.fleet&&MODEL[c.fleet.model])s.fleet.push({id:'f'+s.nextId++,model:c.fleet.model,qty:c.fleet.qty,condition:c.fleet.condition||80,born:yearOf(s)-6,origin:'Segunda mano'});
 if(c.fleetDamage)s.fleet.forEach(f=>f.condition=clamp(f.condition-c.fleetDamage,15,100));
 if(c.worksDelay)for(const p of s.projects)if(!p.done&&p.type!=='upgrade'){p.due=Math.max(s.month+1,p.due+c.worksDelay);if(c.worksDelay>0)p.delay=(p.delay||0)+c.worksDelay;}
 if(c.changer&&!s.infra.c.includes(c.changer)&&I.NODES[c.changer]){s.infra.c.push(c.changer);s.infra.ver++;}
 if(c.gamble){const win=random(s)<c.gamble.chance;applyEffects(s,{effects:win?c.gamble.good:c.gamble.bad});return win;}
 return null;
}
export function decide(s,id,index){ensurePlaying(s);const d=pendingDecision(s);if(!d||d.id!==id||!d.choices[index])throw Error('Decisión no disponible.');const c=d.choices[index];
 const win=applyEffects(s,c);
 if(d.event){s.events=[...(s.events||[]),{id,month:s.month}].slice(-60);s.event=null;}else s.decided.push(id);
 log(s,d.title,c.label+(win===true?' · salió bien':win===false?' · salió mal':''));return win;}
export const dailyTrains=s=>s.routes.filter(r=>r.active).reduce((n,r)=>n+r.frequency*2,0);
/** Ciudades con un AVE en servicio que llega hasta ellas. */
export function aveCities(s){const set=new Set();for(const r of s.routes)if(r.active&&product(s,r)==='AVE')for(const c of r.ends)if(CITIES.some(x=>x.id===c))set.add(c);return set;}
export function objectiveValue(s,key){switch(key){case 'active':return s.routes.filter(r=>r.active).length;case 'trains':return dailyTrains(s);case 'requests':return s.stats.requests||0;case 'stations':return Object.values(s.stations||{}).reduce((a,b)=>a+b,0);case 'satisfaction':return Math.round(s.satisfaction);case 'solvent':return s.cash>s.debt?1:0;case 'projects':return s.projects.filter(p=>p.type==='infrastructure'&&p.done).length;case 'electrified':return Math.round(s.infra.done.elec);case 'converted':return Math.round(s.infra.done.conv);case 'changers':return s.infra.done.changers;case 'aveCities':return aveCities(s).size;case 'alvia':return s.routes.filter(r=>r.active&&product(s,r)==='Alvia').length;case 'mediterranean':{const r=s.routes.find(r=>r.id==='valencia-barcelona');return (r&&routeOptions(s,r).ave.ok?1:0)+(s.projects.some(p=>p.id==='almeria'&&p.done)?1:0);}default:return s.stats[key]||0;}}
export function chapterReady(s){const c=CHAPTERS[s.chapter];return !!c&&yearOf(s)>=c.year&&c.objectives.every(([k,target])=>objectiveValue(s,k)>=target)&&!s.claimed.includes(c.id);}
export function claimChapter(s){ensurePlaying(s);if(!chapterReady(s))throw Error('Aún faltan objetivos o no ha empezado la etapa.');const c=CHAPTERS[s.chapter];s.claimed.push(c.id);s.cash+=c.reward;s.reputation=clamp(s.reputation+5,0,100);log(s,'Capítulo completado',c.title+' · '+c.reward+' M€ de financiación.');if(s.chapter<4)s.chapter++;}
function addFleet(s,model,qty,origin){const f=s.fleet.find(f=>f.origin===origin&&f.model===model&&f.born===yearOf(s));if(f)f.qty+=qty;else s.fleet.push({id:'f'+s.nextId++,model,qty,condition:100,born:yearOf(s),origin});}
function historic(s){
 for(const h of HISTORICAL_ORDERS){if(h.signed>s.month||h.tender||!h.model)continue;let o=s.orders.find(o=>o.id===h.id);if(!o){o={id:h.id,model:h.model,qty:h.qty,delivered:0,historical:true,start:h.signed,first:h.start,next:h.start,total:0,remaining:0};s.orders.push(o);}if(s.month<h.start)continue;const target=Math.min(h.qty,1+Math.floor((s.month-h.start)*(h.qty-1)/(h.span-1)));const count=target-o.delivered;if(count>0){addFleet(s,h.model,count,'Contrato '+h.id);o.delivered+=count;if(s.month%6===0||o.delivered===h.qty)log(s,'Llegan trenes del contrato',h.name+': '+o.delivered+' de '+h.qty+'.');}}
}
/** Obras históricas de la red que ya han llegado a su fecha. */
export function advanceInfra(s){for(const [title,body] of I.applyHistoric(s,gameDate(s)))log(s,title,body);}
function finishWork(s,p){
 if(p.type==='upgrade'){const r=s.routes.find(r=>r.id===p.route);r.level++;s.stats.upgrades++;log(s,'Mejora terminada',routeName(r));return;}
 if(p.type==='tramo'){const st=s.infra.t[p.target],d=I.tramoDef(s,p.target);if(p.work==='electrify'){st.e='25kv';s.infra.done.elec+=d.km;}else{st.g=p.work==='mixed'?'mixto':'std';s.infra.done.conv+=d.km;}log(s,'Obra terminada',I.WORKS[p.work].label+' · '+d.name);}
 else if(p.type==='changer'){if(!s.infra.c.includes(p.target))s.infra.c.push(p.target);s.infra.done.changers++;log(s,'Cambiador en servicio',I.NODES[p.target].name+': los Alvia ya pueden cambiar de ancho aquí.');}
 else if(p.type==='custom'){s.infra.t[p.target].b=true;s.stats.built++;s.infra.done.lav+=I.tramoDef(s,p.target).km;log(s,'Línea nueva en servicio',I.tramoDef(s,p.target).name+'. Ahora toca ponerle trenes.');}
 else{const def=PROJECTS.find(x=>x.id===p.id);for(const t of I.TRAMOS)if(t.plan===p.id){s.infra.t[t.id].b=true;s.infra.done.lav+=t.km;}log(s,'Alta velocidad inaugurada',def.name+'. Con cinta, discurso y todo.');}
 s.infra.ver++;
 for(const r of s.routes)if(r.cut===p.id){delete r.cut;}
}
export function step(s){
 if(s.ended||!s.started||pendingDecision(s))return false;
 const b=balance(s);s.cash+=b.net;s.last=b;s.stats.passengers+=b.passengers;
 const punctuality=b.punctuality||50;const coverage=s.routes.filter(r=>r.active).length;
 const target=clamp(24+Math.min(1,coverage/40)*28+Math.min(1,dailyTrains(s)/700)*14+s.reputation*.3+(punctuality-85)*.6,15,96);s.satisfaction=s.satisfaction*.84+target*.16;
 s.fleet.forEach(f=>{if(f.qty>0){const use=f.qty-available(s,f);f.condition=clamp(f.condition-(use>0?.29:.08)+(s.maintenance-1)*.35,15,100);}});
 s.history.push({month:s.month,cash:s.cash,...b,satisfaction:s.satisfaction});s.history=s.history.slice(-348);
 s.month++;
 historic(s);advanceInfra(s);
 for(const o of s.orders.filter(o=>!o.historical&&o.delivered<o.qty&&s.month>=o.next)){
  if(!o.delayChecked){o.delayChecked=true;if(random(s)<.28){const delay=2+Math.floor(random(s)*5);o.delay=delay;o.next+=delay;log(s,'El fabricante se retrasa',MODEL[o.model].name+' · +'+delay+' meses. Qué sorpresa.');continue;}}
  const count=Math.min(2,o.qty-o.delivered),due=count*o.unit*.7;
  if(s.cash<due){if(o.blocked!==s.month-1)log(s,'Entrega retenida por impago',MODEL[o.model].name+': faltan '+due.toFixed(1)+' M€ en caja.');o.blocked=s.month;continue;}
  s.cash-=due;o.remaining=Math.max(0,o.remaining-due);o.delivered+=count;o.next=s.month+1;s.stats.delivered+=count;addFleet(s,o.model,count,'Compra '+o.id);log(s,'Trenes nuevos',count+' × '+MODEL[o.model].name+' listos para salir.');
 }
 for(const r of s.refits.filter(r=>!r.done&&s.month>=r.due)){r.done=true;s.fleet.push({id:'f'+s.nextId++,model:r.model,qty:r.qty,condition:98,born:r.born,origin:'Reforma '+r.id});s.stats.refurbished+=r.qty;log(s,'Vuelven del taller',r.qty+' unidades como nuevas. Casi.');}
 for(const p of s.projects.filter(p=>!p.done&&s.month>=p.due)){
  if(p.type!=='upgrade'&&p.type!=='changer'&&!p.delayChecked){p.delayChecked=true;if(random(s)<.22){p.delay=3+Math.floor(random(s)*7);p.due+=p.delay;log(s,'La obra se alarga','+'+p.delay+' meses. Ha aparecido algo debajo de la vía, como siempre.');continue;}}
  p.done=true;finishWork(s,p);
 }
 rollEvent(s);
 if(s.month%18===0&&s.month<340){s.flags.buswar=s.month+6;log(s,'Autocares Meseta baja precios','Seis meses de autobús a precio de chicle para robarte viajeros.');}
 if(s.month%12===0&&s.satisfaction>=70)s.reputation=clamp(s.reputation+1,0,100);
 if(s.cash<0){if(s.debt<1500){const rescue=Math.min(100,1500-s.debt);s.cash+=rescue;s.debt+=rescue;s.reputation=clamp(s.reputation-5,5,100);log(s,'Crédito puente automático',rescue+' M€ para seguir pagando nóminas. Revisa los servicios que pierden dinero.');}else if(s.cash<-100){s.ended=true;s.ending='insolvency';log(s,'Fin del mandato','Sin caja y sin crédito: Hacienda interviene la compañía.');}}
 checkRequests(s);if(s.month<346)generateRequest(s);
 if(s.month>=348){s.ended=true;s.ending='2050';log(s,'31 de diciembre de 2050','Se acabó tu mandato. Tu legado te espera en Campaña.');}
 return true;
}
// ---- Ciudades: estaciones mejorables y peticiones con plazo y recompensa (parámetros de juego).
export const STATION_LEVELS=['Apeadero','Estación renovada','Intercambiador','Gran estación'];
export function stationCost(s,city){const lv=s.stations?.[city]||0;const pop=POP[city]||60;return Math.round((4+Math.sqrt(pop)*.35)*(lv+1));}
export function upgradeStation(s,city){ensurePlaying(s);if(!CITY[city])throw Error('Ciudad desconocida.');s.stations||={};const lv=s.stations[city]||0;if(lv>=3)throw Error('Más bonita no se puede poner.');spend(s,stationCost(s,city));s.stations[city]=lv+1;s.reputation=clamp(s.reputation+1,5,100);log(s,'Estación mejorada',CITY[city].name+' · '+STATION_LEVELS[lv+1]+'.');}
export const cityRoutes=(s,city)=>s.routes.filter(r=>r.ends.includes(city));
export function requestDone(s,q){const r=s.routes.find(r=>r.id===q.route);if(!r)return false;if(q.type==='open')return r.active;if(q.type==='more')return r.active&&r.frequency>=q.target;if(q.type==='fare')return r.active&&r.fare<=q.target;if(q.type==='station')return (s.stations?.[q.city]||0)>=q.target;if(q.type==='ave')return r.active&&product(s,r)==='AVE';return false;}
export function checkRequests(s){s.requests||=[];s.stats.requests||=0;for(const q of [...s.requests]){if(requestDone(s,q)){s.cash+=q.reward;s.reputation=clamp(s.reputation+(q.type==='ave'?5:2),5,100);s.satisfaction=clamp(s.satisfaction+1,0,100);s.stats.requests++;s.requests=s.requests.filter(x=>x!==q);log(s,'Petición atendida',(CITY[q.city]?.name||q.city)+' · +'+q.reward+' M€');}else if(s.month>q.until){s.reputation=clamp(s.reputation-(q.type==='ave'?4:2),5,100);s.requests=s.requests.filter(x=>x!==q);log(s,'Petición ignorada',(CITY[q.city]?.name||q.city)+' se acordará de ti en las próximas elecciones.');}}}
export function generateRequest(s,force=false){
 s.requests||=[];if(s.requests.length>=4||(!force&&random(s)>.7))return null;
 const roll=random(s);
 // ¡Queremos AVE!: una ciudad con Alvia que reclama su AVE.
 if(!force&&roll<.22&&!s.requests.some(q=>q.type==='ave')){
  const pool=s.routes.filter(r=>r.active&&product(s,r)==='Alvia'&&r.ends.some(c=>POP[c]&&c!=='mad'&&c!=='bcn'));
  if(pool.length){const r=pool[Math.floor(random(s)*pool.length)],city=r.ends.find(c=>POP[c]&&c!=='mad'&&c!=='bcn');const q={type:'ave',id:'q'+s.nextId++,city,route:r.id,until:s.month+36,reward:Math.round(30+random(s)*25)};s.requests.push(q);return q;}
 }
 const pool=s.routes.filter(r=>isUnlocked(s,r)&&!s.requests.some(q=>q.route===r.id)&&r.ends.some(c=>POP[c]));if(!pool.length)return null;
 const r=pool[Math.floor(random(s)*pool.length)],city=r.ends.find(c=>POP[c]&&c!=='mad')||r.ends.find(c=>POP[c])||r.ends[0],max=maxFrequency(r);let q;
 if(!r.active)q={type:'open'};else if(r.frequency<max&&roll<.6)q={type:'more',target:Math.min(max,r.frequency+Math.max(1,Math.ceil(max*.2)))};else if(roll<.8&&(s.stations?.[city]||0)<3)q={type:'station',target:(s.stations?.[city]||0)+1};else q={type:'fare',target:Math.max(2,Math.round(r.fare*.85))};
 Object.assign(q,{id:'q'+s.nextId++,city,route:r.id,until:s.month+4,reward:Math.round(6+random(s)*10+Math.sqrt(r.km)*.6)});s.requests.push(q);return q;}
export const cityPopulation=id=>POP[id]||null;
export function finalScore(s){return Math.round(clamp(s.routes.filter(r=>r.active).length/45*15+dailyTrains(s)/900*10+aveCities(s).size/40*10,0,35)+s.satisfaction*.3+clamp((s.cash-s.debt)/1000*15,0,15)+s.claimed.length*4);}
function migrate(s){
 if(!s||typeof s!=='object'||!Array.isArray(s.routes))return s;
 if(s.version!==3)throw Error('Esta partida es de una versión anterior del juego, con otra red y otros trenes. Empieza una campaña nueva.');
 s.stations||={};s.requests||=[];
 const known=new Set(s.routes.map(r=>r.id));
 for(const r of s.routes){const def=ROUTE_DEF[r.id];if(!def)continue;for(const k of ['real','baseFrequency','peak','minutes','products','stations','name','via','kind'])if(def[k]!==undefined)r[k]=def[k];}
 for(const def of ALL_ROUTES)if(!known.has(def.id))s.routes.push(copy(def));
 for(const t of I.TRAMOS)if(!s.infra?.t?.[t.id])throw Error('La red guardada no coincide con la del juego.');
 return s;
}
export function validateSave(input){
 const s=migrate(copy(input));if(s.version!==3||!Number.isInteger(s.month)||s.month<0||s.month>348||!Array.isArray(s.routes)||!Array.isArray(s.fleet)||!Array.isArray(s.orders))throw Error('No es una partida válida de Iberia Ferroviaria.');
 const numeric=['cash','debt','reputation','satisfaction','seed','nextId','chapter','maintenance'];for(const k of numeric)if(!Number.isFinite(s[k]))throw Error('La partida contiene valores no válidos.');
 if(s.routes.length>400||s.fleet.length>3000||s.orders.length>3000||s.chapter<0||s.chapter>4)throw Error('Partida fuera de los límites admitidos.');
 for(const k of ['refits','projects','history','log','claimed','decided','seen','events'])if(!Array.isArray(s[k]))throw Error('Falta información de la partida.');
 if(s.event!==null&&!EVENTS.some(e=>e.id===s.event))throw Error('Imprevisto desconocido.');
 if(!s.stats||!s.flags||!s.last||s.debt<0||s.debt>1500||s.maintenance<.6||s.maintenance>1.5)throw Error('Estado económico no válido.');
 const safeId=v=>typeof v==='string'&&/^[a-zA-Z0-9-]{1,80}$/.test(v),node=v=>!!I.NODES[v]||!!CITY[v];
 const n=s.infra;if(!n||!Number.isInteger(n.ver)||typeof n.t!=='object'||!Array.isArray(n.c)||!Array.isArray(n.h)||!Array.isArray(n.custom)||!n.done)throw Error('Red no válida.');
 if(n.custom.length>40||n.custom.some(c=>!safeId(c.id)||!I.NODES[c.a]||!I.NODES[c.b]||!Number.isFinite(c.km)||c.km<=0))throw Error('Líneas propias no válidas.');
 for(const [id,st] of Object.entries(n.t)){if(!I.TRAMO[id]&&!n.custom.some(c=>c.id===id))throw Error('Tramo desconocido.');if(!['ib','std','mixto'].includes(st.g)||!['25kv','3kv','no'].includes(st.e)||!Number.isFinite(st.v)||st.v<20||st.v>400||typeof st.b!=='boolean')throw Error('Estado de vía no válido.');}
 if(n.c.some(c=>!I.NODES[c])||['elec','conv','changers','lav'].some(k=>!Number.isFinite(n.done[k])||n.done[k]<0))throw Error('Cambiadores no válidos.');
 const routeIds=new Set();
 for(const r of s.routes){if(!safeId(r.id)||routeIds.has(r.id)||!Array.isArray(r.via)||r.via.length<2||!r.via.every(node)||!Array.isArray(r.ends)||!r.ends.every(id=>CITY[id])||!Number.isFinite(r.demand)||r.demand<0||!Number.isFinite(r.level)||r.level<0||r.level>3||!Number.isFinite(r.km)||r.km<0||!Number.isFinite(r.fare)||!Number.isInteger(r.frequency)||r.frequency<1||r.frequency>maxFrequency(r)||!Number.isInteger(r.units)||r.units<0)throw Error('Relación no válida.');routeIds.add(r.id);}
 for(const k of ['refurbished','purchased','delivered','upgrades','built','passengers'])if(!Number.isFinite(s.stats[k])||s.stats[k]<0)throw Error('Estadísticas no válidas.');
 for(const o of s.orders)if(!safeId(o.id)||!MODEL[o.model]||!Number.isInteger(o.qty)||o.qty<1||!Number.isInteger(o.delivered)||o.delivered<0||o.delivered>o.qty||!Number.isFinite(o.next)||!Number.isFinite(o.remaining)||o.remaining<0||(!o.historical&&(!Number.isFinite(o.unit)||o.unit<0)))throw Error('Pedido no válido.');
 for(const p of s.projects){if(!safeId(p.id)||!['upgrade','infrastructure','custom','tramo','changer'].includes(p.type)||!Number.isFinite(p.due)||!Number.isFinite(p.started))throw Error('Obra no válida.');
  if((p.type==='infrastructure'&&!PROJECTS.some(d=>d.id===p.id))||(p.type==='upgrade'&&!routeIds.has(p.route))||(p.type==='tramo'&&(!n.t[p.target]||!I.WORKS[p.work]))||(p.type==='changer'&&!I.NODES[p.target])||(p.type==='custom'&&!n.custom.some(c=>c.id===p.target)))throw Error('Obra no válida.');}
 for(const r of s.refits)if(!safeId(r.id)||!MODEL[r.model]||!Number.isInteger(r.qty)||r.qty<1||!Number.isFinite(r.due)||!Number.isFinite(r.born))throw Error('Reforma no válida.');
 const ids=new Set();for(const f of s.fleet){if(!safeId(f.id)||ids.has(f.id)||!MODEL[f.model]||!Number.isInteger(f.qty)||f.qty<0||!Number.isFinite(f.born)||!Number.isFinite(f.condition)||f.condition<0||f.condition>100)throw Error('Flota no válida.');ids.add(f.id);}
 for(const f of s.fleet)if(available(s,f)<0)throw Error('Hay trenes asignados dos veces.');
 for(const r of s.routes.filter(r=>r.active)){const f=s.fleet.find(f=>f.id===r.fleet);if(!f||!canRun(s,r,MODEL[f.model]))throw Error('Hay un tren asignado a una línea por la que no puede circular.');}
 if(s.stations!==undefined&&(typeof s.stations!=='object'||Array.isArray(s.stations)||Object.entries(s.stations).some(([k,v])=>!CITY[k]||!Number.isInteger(v)||v<0||v>3)))throw Error('Estaciones no válidas.');
 if(s.requests!==undefined&&(!Array.isArray(s.requests)||s.requests.length>10||s.requests.some(q=>!safeId(q.id)||!routeIds.has(q.route)||!CITY[q.city]||!['open','more','fare','station','ave'].includes(q.type)||!Number.isFinite(q.reward)||q.reward<0||q.reward>100||!Number.isFinite(q.until))))throw Error('Peticiones no válidas.');
 if(s.ops){const o=s.ops;if(!Number.isInteger(o.day)||o.day<1||o.day>new Date(Date.UTC(2022+Math.floor(Math.min(s.month,347)/12),Math.min(s.month,347)%12+1,0)).getUTCDate()||!Number.isFinite(o.minute)||o.minute<0||o.minute>5000||!['planning','running','review'].includes(o.phase)||!Array.isArray(o.incidents)||!Array.isArray(o.resolved)||o.incidents.length>50||o.resolved.length>50||!['balanced','punctual'].includes(o.priority)||!Number.isInteger(o.completed)||o.completed<0)throw Error('Jornada guardada no válida.');for(const x of o.incidents)if(typeof x.trip!=='string'||!routeIds.has(x.route)||!Number.isFinite(x.at)||x.at<0||!Number.isFinite(x.delay)||x.delay<0||x.delay>500||typeof x.reason!=='string')throw Error('Incidencia inválida.');if(o.surges!==undefined&&(!Array.isArray(o.surges)||o.surges.length>10||o.surges.some(x=>!routeIds.has(x.route)||!Number.isFinite(x.need)||!Number.isFinite(x.bonus)||x.bonus>5)))throw Error('Jornada guardada no válida.');if(o.choices!==undefined&&(typeof o.choices!=='object'||Array.isArray(o.choices)||Object.values(o.choices).some(v=>!['team','bus','wait'].includes(v))))throw Error('Jornada guardada no válida.');if(o.last){if(typeof o.last.date!=='string'||['trains','late','punctuality','passengers','net','first','last','incidents','attended'].some(k=>!Number.isFinite(o.last[k])))throw Error('Resumen de jornada inválido.');}}
 return s;
}
