import {MODELS,MODEL,HISTORICAL_ORDERS,PROJECTS,CITY} from './data.js';
import {ALL_ROUTES,ROUTE_DEF} from './network.js';
import {CHAPTERS,DECISIONS} from './story.js';
export const clamp=(v,a,b)=>Math.max(a,Math.min(b,v));
export const yearOf=s=>2022+Math.floor(Math.min(s.month,347)/12);
export const dateOf=(m)=>new Date(Date.UTC(2022+Math.floor(m/12),m%12,1)).toLocaleDateString('es-ES',{month:'long',year:'numeric',timeZone:'UTC'});
export const routeName=r=>r.name||r.ends.map(id=>CITY[id]?.name||id).join(' — ');
const copy=x=>JSON.parse(JSON.stringify(x));
// Servicios con los que arranca la campaña (fracción de la oferta publicada).
const START_SERVICE={'madrid-barcelona':.1,'madrid-valencia':.18,'madrid-sevilla':.15,'c-madrid-c1':.5,'c-madrid-c3':.4,'c-madrid-c4a':.35,'c-madrid-c4b':.35,'c-madrid-c5':.4,'c-madrid-c10':.35,'madrid-guadalajara':.35,'c-rodalies-r1':.3,'c-rodalies-r2s':.3,'c-rodalies-r3':.2,'c-rodalies-r4':.25};
export const maxFrequency=r=>r.real?r.baseFrequency:r.kind==='commuter'?64:16;
export function initialState(seed=72022){
 const s={version:2,month:0,seed,cash:500,debt:0,reputation:52,satisfaction:60,policy:'public',started:false,ended:false,maintenance:1,chapter:0,claimed:[],decided:[],flags:{},history:[],log:[],orders:[],projects:[],refits:[],routes:copy(ALL_ROUTES),fleet:[],nextId:20,stats:{refurbished:0,purchased:0,delivered:0,upgrades:0,built:0,passengers:0},last:{revenue:0,cost:0,subsidy:0,net:0,passengers:0},seen:[]};
 [['s112',26,76,2010],['s130',16,72,2008],['s599',28,64,2009],['s449',26,71,2010],['civia',90,69,2007],['metric',18,57,1996]].forEach(([model,qty,condition,born],i)=>s.fleet.push({id:'f'+i,model,qty,condition,born,origin:'Parque inicial ficticio'}));
 for(const r of s.routes){const share=START_SERVICE[r.id];if(!share)continue;const f=r.kind==='commuter'?s.fleet.find(f=>f.model==='civia'):s.fleet.find(f=>f.model==='s112');r.active=true;r.fleet=f.id;r.frequency=Math.max(1,Math.round((r.real?r.baseFrequency:r.frequency)*share));r.units=requiredUnits(r,MODEL[f.model],r.frequency);}
 historic(s);log(s,'Tu mandato comienza','Tres corredores de alta velocidad y los núcleos de Madrid y Barcelona funcionan con servicios mínimos. El resto de la red necesita material, una decisión de reapertura o terminar sus obras.');return s;
}
export function random(s){s.seed=(Math.imul(s.seed,1664525)+1013904223)>>>0;return s.seed/4294967296;}
export function log(s,title,body){s.log.unshift({month:Math.min(s.month,347),title,body});s.log=s.log.slice(0,100);}
export function requiredUnits(r,m,f){if(r.real){const slow=Math.max(1,Math.min(1.35,(r.speed||120)/Math.max(60,m.speed)));return Math.max(1,Math.ceil(r.peak*Math.min(1,f/r.baseFrequency)*1.12*slow));}const hours=((r.last??(r.kind==='commuter'?1410:1260))-(r.first??(r.kind==='commuter'?330:360)))/60,interval=hours/Math.max(1,f-1),cycle=(r.km/Math.max(35,Math.min(r.speed,m.speed)*.78)+.3)*(r.circular?1:2);return Math.max(r.circular?1:2,Math.ceil(cycle/Math.max(.1,interval)));}
export const available=(s,f,except=null)=>f.qty-s.routes.filter(r=>r.active&&r.fleet===f.id&&r.id!==except).reduce((n,r)=>n+r.units,0);
export const compatible=(r,m)=>(r.gauge==='mixed'?m.gauge!=='metric':m.gauge===r.gauge||(m.gauge==='variable'&&r.gauge!=='metric'))&&(r.power==='electric'||m.power!=='electric');
export function isUnlocked(s,r){const date=new Date(Date.UTC(2022+Math.floor(s.month/12),s.month%12,s.ops?.day||1)).toISOString().slice(0,10);return s.month>=r.unlock&&(!r.availableFrom||date>=r.availableFrom)&&(!r.project||s.projects.some(p=>p.id===r.project&&p.done));}
export function metrics(s,r,override={}){
 r={...r,...override};const f=s.fleet.find(f=>f.id===r.fleet),m=f&&MODEL[f.model];
 if(!r.active||!m)return {passengers:0,revenue:0,cost:0,subsidy:0,net:0,occupancy:0,share:0,punctuality:0,trainTime:0,busShare:.62,otherShare:.38};
 const speed=Math.min(r.speed,m.speed),trainTime=r.real&&r.minutes?r.minutes/60*Math.max(1,r.speed/Math.max(60,m.speed))**.35:r.km/(speed*.78)+.3,busTime=r.km/73+.5;
 const year=yearOf(s),season=1+.10*Math.sin(s.month/12*Math.PI*2),recovery=Math.min(1.25,.72+s.month*.009);
 const growth=1+Math.min(.55,(year-2022)*.012),discounted=s.flags.passes>s.month&&r.kind!=='av';
 const demand=r.demand*recovery*growth*season*(discounted?1.18:1);
 const reliability=clamp(67+f.condition*.29+(s.maintenance-1)*7+r.level*2,50,99);
 const rivals=(r.kind==='av'&&s.month>=10)?1.5:(r.kind==='av'?.7:.08);
 const busFare=Math.max(4,r.km*.066)*(s.flags.buswar>s.month?.78:1);
 const trainWeight=Math.exp(clamp(1.6-trainTime*.2-r.fare/35+Math.min(r.frequency,40)*.045+(reliability-80)*.018+(s.reputation-50)*.012+r.level*.12,-3,4));
 const busWeight=Math.exp(clamp(1.1-busTime*.2-busFare/35,-3,4));
 const otherWeight=.33+rivals*.3,weight=trainWeight+busWeight+otherWeight;
 const share=trainWeight/weight,capacity=m.seats*r.frequency*(r.circular?1:2)*30*(r.capacity||(r.real&&r.kind==='commuter'?1.6:1));
 const passengers=Math.round(Math.min(capacity*.98,demand*share)),revenue=passengers*r.fare/1e6;
 // Coste por tren-km: energía, personal, canon de infraestructura y mantenimiento (parámetros de juego).
 const energy=(s.flags.energy>s.month?1.22:1),trainKm=r.frequency*(r.circular?1:2)*30*r.km,operating=trainKm*(m.energy*2.8*energy+(r.kind==='av'?17:r.kind==='commuter'?10:8))/1e6;
 const cost=operating+r.units*.03*s.maintenance+.06+r.level*.025;
 // Obligación de servicio público: compensación por tren-km en Cercanías y Media Distancia.
 const subsidy=r.kind==='av'?0:trainKm*(s.policy==='public'?4.4:3.2)/1e6+.08;
 return {passengers,revenue,cost,subsidy,net:revenue+subsidy-cost,occupancy:passengers/capacity,share,punctuality:reliability,trainTime,busShare:busWeight/weight,otherShare:otherWeight/weight};
}
export function balance(s){
 const parts=s.routes.filter(r=>r.active).map(r=>metrics(s,r));
 const sum=k=>parts.reduce((n,p)=>n+p[k],0),passengers=sum('passengers');
 // Estructura: estaciones, venta, sede y mantenimiento pesado del parque (parámetros de juego).
 const overhead=9+s.fleet.reduce((n,f)=>n+f.qty*.035,0)+s.debt*.004;
 const subsidy=sum('subsidy')+(s.policy==='public'?3.5:2)+(s.flags.rural>s.month?6:0);
 const cost=sum('cost')+overhead,revenue=sum('revenue');
 return {passengers,revenue,cost,subsidy,net:revenue+subsidy-cost,punctuality:parts.length?sum('punctuality')/parts.length:0,share:parts.length?sum('share')/parts.length:0};
}
export function configureRoute(s,id,fleetId,frequency,fare,first=null,last=null){
 ensurePlaying(s);if(s.ops?.phase==='running')throw Error('Termina la jornada antes de modificar el plan de circulación.');const r=s.routes.find(x=>x.id===id),f=s.fleet.find(x=>x.id===fleetId);
 if(!r||!f)throw Error('Selecciona una línea y material disponible.');
 if(!isUnlocked(s,r))throw Error('La infraestructura todavía no está disponible.');
 const m=MODEL[f.model];frequency=Number(frequency);fare=Number(fare);
 if(!Number.isInteger(frequency)||frequency<1||frequency>maxFrequency(r)||!Number.isFinite(fare)||fare<1.5||fare>150)throw Error(`Usa 1–${maxFrequency(r)} salidas por sentido y una tarifa de 1,5–150 €.`);
 if(r.real){first=null;last=null;}
 if(first!==null&&(!Number.isInteger(first)||first<240||first>1320||!Number.isInteger(last)||last<=first||last>1439))throw Error('La primera salida debe estar entre04:00y22:00y preceder a la última.');
 if(!compatible(r,m))throw Error('El ancho de vía o la tracción no son compatibles.');
 if(f.condition<30)throw Error('Este material necesita una reforma antes de volver al servicio.');
 const units=requiredUnits({...r,first:first??r.first,last:last??r.last},m,frequency);
 if(available(s,f,r.id)<units)throw Error(`Necesitas ${units} trenes; este lote tiene ${available(s,f,r.id)} libres.`);
 const opening=!r.active;if(opening&&s.cash<4)throw Error('Necesitas 4 M€ para preparar la reapertura.');
 if(opening)s.cash-=4;Object.assign(r,{fleet:fleetId,frequency,fare,units,active:true});if(first!==null)Object.assign(r,{first,last});
 if(opening)log(s,'Servicio recuperado',routeName(r));return r;
}
export function closeRoute(s,id){ensurePlaying(s);if(s.ops?.phase==='running')throw Error('Termina la jornada antes de suspender un servicio.');const r=s.routes.find(r=>r.id===id);if(!r||!r.active)throw Error('El servicio ya está cerrado.');r.active=false;r.fleet=null;r.units=0;s.reputation=clamp(s.reputation-1,5,100);log(s,'Servicio suspendido',routeName(r));}
export function upgradeRoute(s,id){ensurePlaying(s);const r=s.routes.find(r=>r.id===id);if(!r||r.level>=3)throw Error('La línea ya tiene el nivel máximo.');if(s.projects.some(p=>p.id==='upgrade-'+id&&!p.done))throw Error('La mejora ya está en curso.');const cost=12+12*r.level;spend(s,cost);s.projects.push({id:'upgrade-'+id,type:'upgrade',route:id,due:s.month+4,started:s.month,cost,done:false});log(s,'Mejora contratada',routeName(r)+' · información, accesibilidad y fiabilidad.');}
export function purchaseQuote(s,model,qty){
 const m=MODEL[model];qty=Number(qty);if(!m||!Number.isInteger(qty)||qty<1||qty>30)throw Error('Selecciona entre 1 y 30 unidades.');
 const price=m.price*(1+Math.max(0,yearOf(s)-2022)*.018),total=price*qty;
 const backlog=s.orders.filter(o=>!o.historical&&o.delivered<o.qty).reduce((n,o)=>n+o.qty-o.delivered,0);
 const lead=Math.max(16,m.lead+Math.floor(backlog/10)*2+(s.flags.backlog>s.month?8:0)-(s.flags.factory>s.month?6:0));
 return {total,deposit:total*.3,remaining:total*.7,lead,last:lead+Math.ceil(qty/2)-1,unit:price};
}
export function buy(s,model,qty){ensurePlaying(s);if(yearOf(s)<MODEL[model]?.year)throw Error('Este modelo todavía no está disponible.');const q=purchaseQuote(s,model,qty);spend(s,q.deposit);const id='o'+s.nextId++;s.orders.push({id,model,qty:Number(qty),delivered:0,start:s.month,first:s.month+q.lead,next:s.month+q.lead,total:q.total,remaining:q.remaining,unit:q.unit,delay:0,historical:false});s.stats.purchased+=Number(qty);log(s,'Pedido confirmado',`${qty} × ${MODEL[model].name}. Primera entrega prevista: ${dateOf(s.month+q.lead)}; posible retraso de hasta 6 meses.`);return id;}
export function refurbish(s,id,qty){ensurePlaying(s);const f=s.fleet.find(f=>f.id===id);qty=Number(qty);if(!f||!Number.isInteger(qty)||qty<1||available(s,f)<qty)throw Error('Solo puedes reformar unidades libres del lote.');spend(s,qty*MODEL[f.model].price*.12);f.qty-=qty;s.refits.push({id:'ref'+s.nextId++,model:f.model,qty,due:s.month+5,born:f.born});log(s,'Entrada al taller',qty+' × '+MODEL[f.model].name+' · 5 meses.');}
export function sell(s,id,qty){ensurePlaying(s);const f=s.fleet.find(f=>f.id===id);qty=Number(qty);if(!f||!Number.isInteger(qty)||qty<1||available(s,f)<qty)throw Error('Solo puedes vender unidades libres.');const value=qty*MODEL[f.model].price*.23*(f.condition/100);s.cash+=value;f.qty-=qty;log(s,'Venta de material',qty+' × '+MODEL[f.model].name+' · '+value.toFixed(1)+' M€.');}
export function startProject(s,id){ensurePlaying(s);const p=PROJECTS.find(p=>p.id===id);if(!p)throw Error('Proyecto desconocido.');if(s.projects.some(x=>x.id===id))throw Error('Este proyecto ya está contratado.');spend(s,p.cost);const due=Math.max(s.month+p.duration,(p.earliest-2022)*12);s.projects.push({id,type:'infrastructure',started:s.month,due,originalDue:due,cost:p.cost,done:false,delay:0});log(s,'Acuerdo con Adif',p.name+' · previsión de juego: '+dateOf(due));}
export function newLineQuote(a,b,type){if(!CITY[a]||!CITY[b]||a===b)throw Error('Selecciona dos ciudades diferentes.');if(!['regional','av'].includes(type))throw Error('Tipo de línea no válido.');const ca=CITY[a],cb=CITY[b],rad=Math.PI/180;const dlat=(cb.lat-ca.lat)*rad,dlon=(cb.lon-ca.lon)*rad;const hav=Math.sin(dlat/2)**2+Math.cos(ca.lat*rad)*Math.cos(cb.lat*rad)*Math.sin(dlon/2)**2;const km=Math.round(6371*2*Math.asin(Math.sqrt(hav))*1.22);return {km,cost:Math.round(km*(type==='av'?1.1:.6)+25),duration:Math.round(24+km/10+(type==='av'?18:0))};}
export function buildLine(s,a,b,type){ensurePlaying(s);if(s.routes.some(r=>r.ends.includes(a)&&r.ends.includes(b)))throw Error('Ya existe una relación entre esas ciudades.');const q=newLineQuote(a,b,type);spend(s,q.cost);const id='custom-'+s.nextId++;s.routes.push({id,ends:[a,b],via:[a,b],km:q.km,gauge:type==='av'?'uic':'iberian',power:type==='av'?'electric':'diesel',speed:type==='av'?250:120,demand:Math.round(18000+q.km*130),fare:Math.max(6,Math.round(q.km*.10)),active:false,kind:type==='av'?'av':'regional',unlock:s.month+q.duration,project:id,level:0,frequency:2,units:0,fleet:null,custom:true});s.projects.push({id,type:'custom',route:id,started:s.month,due:s.month+q.duration,originalDue:s.month+q.duration,cost:q.cost,done:false,delay:0});log(s,'Estudio y obra contratados',routeName(s.routes.at(-1))+'. Conexión hipotética; el trazado en el mapa es conceptual.');return id;}
export function loan(s,amount){ensurePlaying(s);amount=Number(amount);if(!Number.isFinite(amount)||![100,-100].includes(amount))throw Error('Operación no válida.');if(amount>0&&s.debt+amount>1500)throw Error('Has alcanzado el límite de deuda de 1.500 M€.');if(amount<0&&(s.debt<100||s.cash<100))throw Error('Necesitas 100 M€ de deuda y de caja para amortizar.');s.cash+=amount;s.debt+=amount;}
export function ensurePlaying(s){if(s.ended)throw Error('La campaña ha terminado. Puedes revisar las cuentas o iniciar una nueva partida.');}
export function spend(s,cost){if(!Number.isFinite(cost)||cost<0)throw Error('Importe no válido.');if(s.cash<cost)throw Error('No hay tesorería suficiente. Revisa Finanzas o solicita financiación.');s.cash-=cost;}
export function pendingDecision(s){if(!s.started||s.ended)return null;return DECISIONS.find(d=>s.month>=d.at&&!s.decided.includes(d.id))||null;}
export function decide(s,id,index){ensurePlaying(s);const d=pendingDecision(s);if(!d||d.id!==id||!d.choices[index])throw Error('Decisión no disponible.');const c=d.choices[index];if((c.effects.cash||0)<0)spend(s,-c.effects.cash);else s.cash+=c.effects.cash||0;s.reputation=clamp(s.reputation+(c.effects.reputation||0),5,100);if(c.policy)s.policy=c.policy;if(c.flag==='fleetcare')s.fleet.forEach(f=>f.condition=clamp(f.condition+8,0,100));else if(c.flag)s.flags[c.flag]=s.month+({passes:18,rural:60,factory:36,backlog:18}[c.flag]||12);s.decided.push(id);log(s,d.title,c.label);}
export const dailyTrains=s=>s.routes.filter(r=>r.active).reduce((n,r)=>n+r.frequency*(r.circular?1:2),0);
export function objectiveValue(s,key){switch(key){case 'active':return s.routes.filter(r=>r.active).length;case 'trains':return dailyTrains(s);case 'satisfaction':return Math.round(s.satisfaction);case 'solvent':return s.cash>s.debt?1:0;case 'projects':return s.projects.filter(p=>p.type==='infrastructure'&&p.done).length;case 'mediterranean':return s.projects.filter(p=>['encina','almeria'].includes(p.id)&&p.done).length;default:return s.stats[key]||0;}}
export function chapterReady(s){const c=CHAPTERS[s.chapter];return !!c&&yearOf(s)>=c.year&&c.objectives.every(([k,target])=>objectiveValue(s,k)>=target)&&!s.claimed.includes(c.id);}
export function claimChapter(s){ensurePlaying(s);if(!chapterReady(s))throw Error('Aún quedan objetivos o no ha empezado la etapa.');const c=CHAPTERS[s.chapter];s.claimed.push(c.id);s.cash+=c.reward;s.reputation=clamp(s.reputation+5,0,100);log(s,'Capítulo completado',c.title+' · '+c.reward+' M€ de financiación adicional.');if(s.chapter<4)s.chapter++;}
function addFleet(s,model,qty,origin){const f=s.fleet.find(f=>f.origin===origin&&f.model===model&&f.born===yearOf(s));if(f)f.qty+=qty;else s.fleet.push({id:'f'+s.nextId++,model,qty,condition:100,born:yearOf(s),origin});}
function historic(s){
 for(const h of HISTORICAL_ORDERS){if(h.signed>s.month||h.tender||!h.model)continue;let o=s.orders.find(o=>o.id===h.id);if(!o){o={id:h.id,model:h.model,qty:h.qty,delivered:0,historical:true,start:h.signed,first:h.start,next:h.start,total:0,remaining:0};s.orders.push(o);if(h.signed===s.month)log(s,'Contrato histórico registrado',h.name+' · '+h.qty+' unidades. Financiación externa al presupuesto de campaña.');}if(s.month<h.start)continue;const target=Math.min(h.qty,1+Math.floor((s.month-h.start)*(h.qty-1)/(h.span-1)));const count=target-o.delivered;if(count>0){addFleet(s,h.model,count,'Contrato histórico '+h.id);o.delivered+=count;if(s.month%6===0||o.delivered===h.qty)log(s,'Material del plan de renovación',h.name+': '+o.delivered+' / '+h.qty+' entregados en la simulación.');}}
}
export function step(s){
 if(s.ended||!s.started||pendingDecision(s))return false;
 const b=balance(s);s.cash+=b.net;s.last=b;s.stats.passengers+=b.passengers;
 const punctuality=b.punctuality||50;const coverage=s.routes.filter(r=>r.active).length;
 const target=clamp(24+coverage/s.routes.length*28+Math.min(1,dailyTrains(s)/6000)*14+s.reputation*.3+(punctuality-85)*.6,15,96);s.satisfaction=s.satisfaction*.84+target*.16;
 s.fleet.forEach(f=>{if(f.qty>0){const use=f.qty-available(s,f);f.condition=clamp(f.condition-(use>0?.29:.08)+(s.maintenance-1)*.35,15,100);}});
 s.history.push({month:s.month,cash:s.cash,...b,satisfaction:s.satisfaction});s.history=s.history.slice(-348);
 s.month++;
 if(s.month===23){const r=s.routes.find(r=>r.id==='leon-oviedo');r.speed=200;log(s,'Pajares, nueva capacidad','La variante histórica mejora el corredor León–Oviedo.');const ex=s.routes.find(r=>r.id==='plasencia-badajoz');ex.power='electric';}
 historic(s);
 for(const o of s.orders.filter(o=>!o.historical&&o.delivered<o.qty&&s.month>=o.next)){
  if(!o.delayChecked){o.delayChecked=true;if(random(s)<.28){const delay=2+Math.floor(random(s)*5);o.delay=delay;o.next+=delay;log(s,'Retraso de fabricación',MODEL[o.model].name+' · +'+delay+' meses. Nueva previsión: '+dateOf(o.next));continue;}}
  const count=Math.min(2,o.qty-o.delivered),due=count*o.unit*.7;
  if(s.cash<due){if(o.blocked!==s.month-1)log(s,'Entrega retenida por pago',MODEL[o.model].name+' necesita '+due.toFixed(1)+' M€ de saldo.');o.blocked=s.month;continue;}
  s.cash-=due;o.remaining=Math.max(0,o.remaining-due);o.delivered+=count;o.next=s.month+1;s.stats.delivered+=count;addFleet(s,o.model,count,'Compra '+o.id);log(s,'Nuevo material recibido',count+' × '+MODEL[o.model].name+' listos para asignar.');
 }
 for(const r of s.refits.filter(r=>!r.done&&s.month>=r.due)){r.done=true;s.fleet.push({id:'f'+s.nextId++,model:r.model,qty:r.qty,condition:98,born:r.born,origin:'Reforma '+r.id});s.stats.refurbished+=r.qty;log(s,'Material reformado',r.qty+' unidades vuelven al parque.');}
 for(const p of s.projects.filter(p=>!p.done&&s.month>=p.due)){
  if(p.type!=='upgrade'&&!p.delayChecked){p.delayChecked=true;if(random(s)<.22){p.delay=3+Math.floor(random(s)*7);p.due+=p.delay;log(s,'La obra necesita más tiempo','Incidencia técnica simulada: +'+p.delay+' meses.');continue;}}
  p.done=true;
  if(p.type==='upgrade'){const r=s.routes.find(r=>r.id===p.route);r.level++;s.stats.upgrades++;log(s,'Mejora terminada',routeName(r));}
  else if(p.type==='custom'){s.routes.find(r=>r.id===p.route).unlock=s.month;s.stats.built++;log(s,'Nueva línea disponible','Asigna material para inaugurar el servicio.');}
  else {const def=PROJECTS.find(x=>x.id===p.id);for(const id of def.routes){const r=s.routes.find(r=>r.id===id);Object.assign(r,def.effect);if(r.project===p.id)r.unlock=s.month;}log(s,'Infraestructura disponible',def.name+' · ya puedes preparar la explotación.');}
 }
 // Route compatibility can change with upgrades; diesel trains remain compatible with electrified track.
 if(s.month%18===0&&s.month<340){s.flags.buswar=s.month+6;log(s,'Alsa refuerza sus ofertas','Evento simulado: presión en precios de autobús durante seis meses.');}
 if(s.month%12===0&&s.satisfaction>=70)s.reputation=clamp(s.reputation+1,0,100);
 if(s.cash<0){if(s.debt<1500){const rescue=Math.min(100,1500-s.debt);s.cash+=rescue;s.debt+=rescue;s.reputation=clamp(s.reputation-5,5,100);log(s,'Crédito puente automático',rescue+' M€ para mantener la operación. Revisa los servicios deficitarios.');}else if(s.cash<-100){s.ended=true;s.ending='insolvency';log(s,'Fin del mandato','La deuda y la falta de liquidez obligan a intervenir la compañía.');}}
 if(s.month>=348){s.ended=true;s.ending='2050';log(s,'31 de diciembre de 2050','Tu mandato ha concluido. Consulta tu legado en Campaña.');}
 return true;
}
export function finalScore(s){return Math.round(clamp(s.routes.filter(r=>r.active).length/60*20+dailyTrains(s)/5000*15,0,35)+s.satisfaction*.3+clamp((s.cash-s.debt)/1000*15,0,15)+s.claimed.length*4);}
// Partidas v0.2 (version 1): se añaden las relaciones del horario oficial y se actualizan sus datos de referencia.
function migrate(s){
 if(!s||typeof s!=='object'||!Array.isArray(s.routes))return s;
 const legacy=s.version===1;
 if(legacy)s.version=2;
 if(s.version!==2)return s;
 const known=new Set(s.routes.map(r=>r.id));
 for(const r of s.routes){const def=ROUTE_DEF[r.id];if(!def)continue;for(const k of ['real','baseFrequency','peak','minutes','net','code','color','products','stations','generated','name'])if(def[k]!==undefined)r[k]=def[k];else delete r[k];
  // Solo las partidas v0.2 se adaptan al horario oficial; en una partida actual, unidades incoherentes se rechazan.
  if(legacy&&r.real&&r.frequency>r.baseFrequency)r.frequency=r.baseFrequency;if(legacy&&r.active&&r.real){const f=s.fleet.find(f=>f.id===r.fleet);if(f&&MODEL[f.model])r.units=requiredUnits(r,MODEL[f.model],r.frequency);}}
 for(const def of ALL_ROUTES)if(!known.has(def.id))s.routes.push(copy(def));
 return s;
}
export function validateSave(input){
 const s=migrate(copy(input));if(s.version!==2||!Number.isInteger(s.month)||s.month<0||s.month>348||!Array.isArray(s.routes)||!Array.isArray(s.fleet)||!Array.isArray(s.orders))throw Error('No es una partida válida de Iberia Ferroviaria.');
 const numeric=['cash','debt','reputation','satisfaction','seed','nextId','chapter','maintenance'];for(const k of numeric)if(!Number.isFinite(s[k]))throw Error('La partida contiene valores no válidos.');
 if(s.routes.length>900||s.fleet.length>3000||s.orders.length>3000||s.chapter<0||s.chapter>4)throw Error('Partida fuera de los límites admitidos.');
 for(const k of ['refits','projects','history','log','claimed','decided','seen'])if(!Array.isArray(s[k]))throw Error('Falta información de la partida.');
 if(!s.stats||!s.flags||!s.last||s.debt<0||s.debt>1500||s.maintenance<.6||s.maintenance>1.5)throw Error('Estado económico no válido.');
 const safeId=v=>typeof v==='string'&&/^[a-zA-Z0-9-]{1,80}$/.test(v);const routeIds=new Set();
 for(const r of s.routes){if(!safeId(r.id)||routeIds.has(r.id)||!['uic','iberian','metric','mixed'].includes(r.gauge)||!['electric','diesel'].includes(r.power)||!Number.isFinite(r.speed)||r.speed<1||!Number.isFinite(r.demand)||r.demand<0||!Number.isFinite(r.level)||r.level<0||r.level>3||!Number.isFinite(r.unlock))throw Error('Datos de red no válidos.');if(r.availableFrom&&!/^\d{4}-\d{2}-\d{2}$/.test(r.availableFrom))throw Error('Fecha de servicio inválida.');if(r.first!==undefined&&(!Number.isInteger(r.first)||r.first<240||r.first>1320||!Number.isInteger(r.last)||r.last<=r.first||r.last>1439))throw Error('Ventana de circulación inválida.');routeIds.add(r.id);}
 for(const k of ['refurbished','purchased','delivered','upgrades','built','passengers'])if(!Number.isFinite(s.stats[k])||s.stats[k]<0)throw Error('Estadísticas no válidas.');
 for(const o of s.orders)if(!safeId(o.id)||!MODEL[o.model]||!Number.isInteger(o.qty)||o.qty<1||!Number.isInteger(o.delivered)||o.delivered<0||o.delivered>o.qty||!Number.isFinite(o.next)||!Number.isFinite(o.remaining)||o.remaining<0||(!o.historical&&(!Number.isFinite(o.unit)||o.unit<0)))throw Error('Pedido no válido.');
 for(const p of s.projects)if(!safeId(p.id)||!['upgrade','infrastructure','custom'].includes(p.type)||!Number.isFinite(p.due)||!Number.isFinite(p.started)||(p.type==='infrastructure'&&!PROJECTS.some(d=>d.id===p.id))||(p.type!=='infrastructure'&&!routeIds.has(p.route)))throw Error('Obra no válida.');
 for(const r of s.refits)if(!safeId(r.id)||!MODEL[r.model]||!Number.isInteger(r.qty)||r.qty<1||!Number.isFinite(r.due)||!Number.isFinite(r.born))throw Error('Reforma no válida.');
 for(const r of s.routes)if(!r.ends?.every(id=>CITY[id])||!r.via?.every(id=>CITY[id])||!Number.isFinite(r.km)||r.km<0||!Number.isFinite(r.fare)||!Number.isInteger(r.frequency)||r.frequency<1||r.frequency>maxFrequency(r)||!Number.isInteger(r.units)||r.units<0)throw Error('Línea no válida.');
 const ids=new Set();for(const f of s.fleet){if(!safeId(f.id)||ids.has(f.id)||!MODEL[f.model]||!Number.isInteger(f.qty)||f.qty<0||!Number.isFinite(f.born)||!Number.isFinite(f.condition)||f.condition<0||f.condition>100)throw Error('Flota no válida.');ids.add(f.id);}
 for(const f of s.fleet)if(available(s,f)<0)throw Error('Hay trenes asignados más de una vez.');
 for(const r of s.routes.filter(r=>r.active)){const f=s.fleet.find(f=>f.id===r.fleet);if(!f||!compatible(r,MODEL[f.model]))throw Error('Asignación de material incompatible.');}
 if(s.ops){const o=s.ops;if(!Number.isInteger(o.day)||o.day<1||o.day>new Date(Date.UTC(2022+Math.floor(Math.min(s.month,347)/12),Math.min(s.month,347)%12+1,0)).getUTCDate()||!Number.isFinite(o.minute)||o.minute<0||o.minute>5000||!['planning','running','review'].includes(o.phase)||!Array.isArray(o.incidents)||!Array.isArray(o.resolved)||o.incidents.length>50||o.resolved.length>50||!['balanced','punctual'].includes(o.priority)||!Number.isInteger(o.completed)||o.completed<0)throw Error('Jornada guardada no válida.');for(const x of o.incidents)if(typeof x.trip!=='string'||!routeIds.has(x.route)||!Number.isFinite(x.at)||x.at<0||!Number.isFinite(x.delay)||x.delay<0||x.delay>500||typeof x.reason!=='string')throw Error('Incidencia inválida.');if(o.choices!==undefined&&(typeof o.choices!=='object'||Array.isArray(o.choices)||Object.values(o.choices).some(v=>!['team','bus','wait'].includes(v))))throw Error('Jornada guardada no válida.');if(o.last){if(typeof o.last.date!=='string'||['trains','late','punctuality','passengers','net','first','last','incidents','attended'].some(k=>!Number.isFinite(o.last[k])))throw Error('Resumen de jornada inválido.');}}
 return s;
}
