import {INFRA} from './assets/infra.js';
// Ciudades del mapa (centro urbano). Los nodos de la red (estaciones y bifurcaciones) están en assets/infra.js.
export const CITIES = [
 ['mad','Madrid',-3.7038,40.4168],['bcn','Barcelona',2.1734,41.3851],['vlc','València',-0.3763,39.4699],['ali','Alicante',-0.4907,38.3452],['elx','Elche',-0.6983,38.2669],['mur','Murcia',-1.1307,37.9922],['car','Cartagena',-0.9845,37.605],['lor','Lorca',-1.700,37.671],['alm','Almería',-2.464,36.834],['gra','Granada',-3.5986,37.1773],['mal','Málaga',-4.4214,36.7213],['sev','Sevilla',-5.9845,37.3891],['cor','Córdoba',-4.7794,37.8882],['cad','Cádiz',-6.2886,36.5271],['jer','Jerez',-6.1372,36.6850],['hue','Huelva',-6.9447,37.2614],['alg','Algeciras',-5.4537,36.1408],['ron','Ronda',-5.167,36.746],['ant','Antequera',-4.561,37.019],['jae','Jaén',-3.790,37.779],['lin','Linares',-3.636,38.095],['cic','Ciudad Real',-3.929,38.986],['pue','Puertollano',-4.112,38.688],['cue','Cuenca',-2.1374,40.0704],['req','Requena',-1.100,39.488],['alb','Albacete',-1.8585,38.9943],['xat','Xàtiva',-0.518,38.989],['enc','La Encina',-0.955,38.765],['cas','Castelló',-0.051,39.986],['tar','Tarragona',1.2445,41.1189],['gir','Girona',2.8214,41.9794],['fig','Figueres',2.961,42.267],['zar','Zaragoza',-0.8891,41.6488],['lle','Lleida',0.620,41.6176],['huc','Huesca',-0.4089,42.14],['ter','Teruel',-1.106,40.345],['sag','Sagunt',-0.278,39.680],['pam','Pamplona',-1.644,42.813],['log','Logroño',-2.4457,42.4627],['bil','Bilbao',-2.935,43.263],['vit','Vitoria',-2.673,42.847],['don','Donostia',-1.981,43.318],['iru','Irún',-1.789,43.338],['san','Santander',-3.8098,43.4623],['bur','Burgos',-3.6969,42.3439],['mir','Miranda de Ebro',-2.947,42.686],['pal','Palencia',-4.527,42.010],['vll','Valladolid',-4.7245,41.6523],['seg','Segovia',-4.118,40.949],['leo','León',-5.5671,42.5987],['ppf','Ponferrada',-6.598,42.546],['ovi','Oviedo',-5.8494,43.3614],['gij','Gijón',-5.6615,43.5322],['avl','Avilés',-5.924,43.556],['fer','Ferrol',-8.232,43.484],['aco','A Coruña',-8.4115,43.3623],['scq','Santiago',-8.5448,42.8782],['vig','Vigo',-8.7207,42.2406],['pon','Pontevedra',-8.645,42.431],['our','Ourense',-7.8639,42.3358],['lug','Lugo',-7.5558,43.0097],['zam','Zamora',-5.7446,41.5034],['sal','Salamanca',-5.6635,40.9701],['avi','Ávila',-4.699,40.656],['tal','Talavera',-4.830,39.963],['pla','Plasencia',-6.089,40.030],['cac','Cáceres',-6.3708,39.4753],['mer','Mérida',-6.338,38.916],['bad','Badajoz',-6.9707,38.8794],['tol','Toledo',-4.0273,39.8628],['gua','Guadalajara',-3.166,40.633],['cal','Calatayud',-1.644,41.354],['sor','Soria',-2.468,41.764],['alc','Alcázar de S. Juan',-3.209,39.390],['med','Medina del Campo',-4.914,41.308]
].map(([id,name,lon,lat])=>({id,name,lon,lat}));
const NODE_ONLY = INFRA.nodes.filter(n=>!CITIES.some(c=>c.id===n.id)).map(n=>[n.id,{id:n.id,name:n.name,lon:n.lon,lat:n.lat,junction:true}]);
// Las estaciones del horario (ids 'st…') se añaden en network.js.
export const CITY = Object.fromEntries([...NODE_ONLY,...CITIES.map(c=>[c.id,c])]);
// Corredores de la campaña: [id, extremos, nodos de paso, producto en 2026 ('av' AVE, 'alvia' Alvia, 'new' sin tren)].
// El trazado y lo que puede circular se calculan sobre la red de assets/infra.js; la demanda y la tarifa, en network.js.
export const ROUTES = [
 ['madrid-barcelona','mad bcn','mad gua cal zar lle tar bcn','av'],
 ['madrid-figueres','mad fig','mad gua cal zar lle tar bcn gir fig','av'],
 ['madrid-huesca','mad huc','mad gua cal zar tdn huc','av'],
 ['madrid-valencia','mad vlc','mad cue mot req vlc','av'],
 ['madrid-castellon','mad cas','mad cue mot req vlc sag cas','av'],
 ['madrid-alicante','mad ali','mad cue mot alb mnc ali','av'],
 ['madrid-murcia','mad mur','mad cue mot alb mnc elx mur','av'],
 ['madrid-sevilla','mad sev','mad cic pue cor sev','av'],
 ['madrid-malaga','mad mal','mad cic pue cor ant mal','av'],
 ['madrid-granada','mad gra','mad cic pue cor ant gra','av'],
 ['madrid-valladolid','mad vll','mad seg olm vll','av'],
 ['madrid-leon','mad leo','mad seg olm vll vdb pal leo','av'],
 ['madrid-burgos','mad bur','mad seg olm vll vdb bur','av'],
 ['madrid-ourense','mad our','mad seg olm med zam our','av'],
 ['madrid-coruna','mad aco','mad seg olm med zam our scq aco','av'],
 ['madrid-vigo','mad vig','mad seg olm med zam our scq pon vig','av'],
 ['madrid-gijon','mad gij','mad seg olm vll vdb pal leo pol ovi gij','av'],
 ['madrid-santander','mad san','mad seg olm vll vdb pal san','alvia'],
 ['madrid-bilbao','mad bil','mad seg olm vll vdb bur mir bil','alvia'],
 ['madrid-irun','mad iru','mad seg olm vll vdb bur mir vit alt don iru','alvia'],
 ['madrid-pamplona','mad pam','mad gua cal zar cst pam','alvia'],
 ['madrid-logrono','mad log','mad gua cal zar cst log','alvia'],
 ['madrid-salamanca','mad sal','mad seg olm med sal','alvia'],
 ['madrid-badajoz','mad bad','mad tal pla cac mer bad','alvia'],
 ['madrid-cadiz','mad cad','mad cic pue cor sev utr jer cad','alvia'],
 ['madrid-huelva','mad hue','mad cic pue cor sev hue','alvia'],
 ['madrid-algeciras','mad alg','mad cic pue cor ant ron alg','alvia'],
 ['madrid-almeria','mad alm','mad cic pue cor ant gra mor alm','alvia'],
 ['madrid-lugo','mad lug','mad seg olm med zam our mfl lug','alvia'],
 ['madrid-toledo','mad tol','mad tol','new'],
 ['madrid-avila','mad avi','mad avi','new'],
 ['madrid-soria','mad sor','mad gua trb sor','new'],
 ['madrid-jaen','mad jae','mad alc lin jae','new'],
 ['madrid-cartagena','mad car','mad cue mot alb mur car','new'],
 ['madrid-ferrol','mad fer','mad seg olm med zam our scq aco bet fer','new'],
 ['madrid-ponferrada','mad ppf','mad seg olm vll vdb pal leo ppf','new'],
 ['madrid-vitoria','mad vit','mad seg olm vll vdb bur vit','new'],
 ['valencia-zaragoza','vlc zar','vlc sag ter zar','new'],
 ['valencia-barcelona','vlc bcn','vlc sag cas tar bcn','new'],
 ['valencia-alicante','vlc ali','vlc xat enc ali','new'],
 ['murcia-almeria','mur alm','mur lor alm','new'],
 ['granada-almeria','gra alm','gra mor alm','new'],
 ['bilbao-donostia','bil don','bil ber don','new'],
].map(([id,ends,via,kind])=>({id,ends:ends.split(' '),via:via.split(' '),kind}));
// Material: AVE (ancho estándar fijo) y Alvia (ancho variable; el híbrido no necesita catenaria).
export const MODELS = [
 {id:'s100',name:'S100 · AVE',family:'AVE',maker:'Alstom',gauge:'uic',power:'electric',speed:300,seats:329,price:16,lead:30,year:2099,energy:.78,desc:'El abuelo de la familia: llegó en 1992 y todavía se cree joven.'},
 {id:'s112',name:'S112 · AVE «Pato»',family:'AVE',maker:'Talgo',gauge:'uic',power:'electric',speed:330,seats:365,price:25,lead:30,year:2022,energy:.62,desc:'El morro de pato más famoso de la Meseta. Rápido, cómodo y fotogénico de perfil.'},
 {id:'s103',name:'S103 · AVE Velaro',family:'AVE',maker:'Siemens',gauge:'uic',power:'electric',speed:350,seats:404,price:33,lead:34,year:2022,energy:.66,desc:'El más rápido del catálogo. Solo sale de las vías de ancho estándar, como algunos ministros de su despacho.'},
 {id:'s106f',name:'S106 · AVE Avril',family:'AVE',maker:'Talgo',gauge:'uic',power:'electric',speed:330,seats:521,price:29,lead:36,year:2024,energy:.58,desc:'Mucho tren por poco dinero, si llega. Ancho estándar fijo.'},
 {id:'av2030',name:'AV 2030 · Nueva generación',family:'AVE',maker:'Licitación de Renfe',gauge:'uic',power:'electric',speed:350,seats:540,price:36,lead:42,year:2026,energy:.48,desc:'La flota del futuro. Promete, que ya es más de lo que hacen muchos.'},
 {id:'s120',name:'S120 · Alvia',family:'Alvia',maker:'CAF',gauge:'variable',power:'electric',speed:250,seats:238,price:18,lead:26,year:2022,energy:.6,desc:'Ancho variable y catenaria obligatoria. Pasa por los cambiadores sin despeinarse.'},
 {id:'s130',name:'S130 · Alvia «Patito»',family:'Alvia',maker:'Talgo',gauge:'variable',power:'electric',speed:250,seats:299,price:21,lead:28,year:2022,energy:.62,desc:'Ancho variable y doble tensión. Necesita catenaria todo el camino.'},
 {id:'s730',name:'S730 · Alvia híbrido',family:'Alvia',maker:'Talgo',gauge:'variable',power:'hybrid',speed:250,seats:265,price:24,lead:30,year:2022,energy:.8,desc:'Lleva su propia central diésel: va donde no llega la catenaria, aunque sin prisas.'},
 {id:'s106v',name:'S106 · Avril variable',family:'Alvia',maker:'Talgo',gauge:'variable',power:'electric',speed:330,seats:507,price:31,lead:38,year:2024,energy:.6,desc:'Velocidad de AVE y bogies de Alvia: cambia de ancho y no pide perdón.'},
];
export const MODEL=Object.fromEntries(MODELS.map(m=>[m.id,m]));
export const HISTORICAL_ORDERS = [
 {id:'h106f',name:'S106 · ancho fijo',model:'s106f',qty:15,signed:-60,start:28,span:18},
 {id:'h106v',name:'S106 · ancho variable',model:'s106v',qty:15,signed:-60,start:28,span:18},
 {id:'h2030',name:'Licitación AV 2026',model:null,qty:30,optional:10,signed:50,start:null,span:0,tender:true},
];
// Grandes obras: líneas de alta velocidad nuevas. Los tramos están en assets/infra.js (campo plan).
export const PROJECTS = [
 {id:'almeria',name:'LAV Murcia — Almería',region:'Región de Murcia y Andalucía',cost:190,duration:48,earliest:2027,desc:'Murcia, Lorca y Almería en alta velocidad. Almería lleva esperando desde que se inventó la espera.'},
 {id:'basque',name:'Y vasca',region:'Euskadi',cost:230,duration:60,earliest:2028,desc:'Vitoria, Bilbao y Donostia unidas en ancho estándar. Las obras más largas desde las pirámides.'},
 {id:'burgosvitoria',name:'LAV Burgos — Vitoria',region:'Castilla y León y Euskadi',cost:150,duration:54,earliest:2029,desc:'El eslabón que falta para que el AVE llegue al País Vasco sin cambiar de ancho.'},
 {id:'navarra',name:'Corredor navarro',region:'Aragón y Navarra',cost:200,duration:60,earliest:2029,desc:'Zaragoza, Castejón y Pamplona en ancho estándar.'},
 {id:'extremadura',name:'LAV Madrid — Extremadura',region:'Castilla-La Mancha y Extremadura',cost:260,duration:72,earliest:2030,desc:'Madrid, Talavera y Plasencia en alta velocidad. Extremadura ya no aceptará otro tren de museo.'},
 {id:'cartagena',name:'LAV Murcia — Cartagena',region:'Región de Murcia',cost:90,duration:42,earliest:2028,desc:'Ancho estándar y catenaria hasta el puerto.'},
 {id:'cantabria',name:'LAV Palencia — Santander',region:'Castilla y León y Cantabria',cost:280,duration:84,earliest:2032,desc:'Alta velocidad hasta el Cantábrico, con todos los túneles que la cordillera exija.'},
 {id:'huelva',name:'LAV Sevilla — Huelva',region:'Andalucía',cost:120,duration:48,earliest:2030,desc:'Huelva deja de ser la última en enterarse.'},
 {id:'cerdedo',name:'Variante de Cerdedo',region:'Galicia',cost:150,duration:60,earliest:2031,desc:'Ourense — Pontevedra directo: Vigo, a menos de cuatro horas de Madrid.'},
];
// Población aproximada del área urbana (miles): demanda, peticiones y luces nocturnas.
export const POP = {mad:6700,bcn:5600,vlc:1600,ali:760,elx:235,mur:700,car:215,lor:95,alm:200,gra:530,mal:1000,sev:1500,cor:320,cad:400,jer:213,hue:145,alg:260,ron:34,ant:41,jae:112,lin:57,cic:75,pue:47,cue:54,req:20,alb:173,xat:30,enc:2,cas:300,tar:300,gir:200,fig:47,zar:760,lle:140,huc:53,ter:36,sag:68,pam:370,log:150,bil:1000,vit:255,don:440,iru:62,san:300,bur:175,mir:35,pal:78,vll:420,seg:52,leo:200,ppf:64,ovi:220,gij:270,avl:76,fer:65,aco:420,scq:98,vig:480,pon:83,our:105,lug:98,zam:60,sal:150,avi:57,tal:83,pla:40,cac:96,mer:60,bad:150,tol:85,gua:87,cal:20,sor:40,alc:30,med:20};
export const GAUGES = {uic:'Ancho estándar fijo',variable:'Ancho variable',std:'Estándar · 1.435 mm',ib:'Ibérico · 1.668 mm',mixto:'Mixto · tercer carril'};
export const POWERS = {electric:'Eléctrico',hybrid:'Híbrido · sin catenaria'};
export const ELECS = {'25kv':'25 kV alterna','3kv':'3 kV continua',no:'Sin electrificar'};
