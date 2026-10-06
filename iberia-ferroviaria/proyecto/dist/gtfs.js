// Native ZIP + streaming CSV. No scripts from feeds are executed.
export const GTFS_LINKS=[{name:'Cercanías · horarios y trazados',url:'https://ssl.renfe.com/ftransit/Fichero_CER_FOMENTO/fomento_transit.zip'},{name:'AVE, Larga y Media Distancia',url:'https://ssl.renfe.com/gtransit/Fichero_AV_LD/google_transit.zip'}];
export async function* csvRecords(chunks){
 let columns=null,row=[],field='',quoted=false,afterQuote=false,skipLF=false;
 for await(const chunk of chunks){for(const ch of chunk){
  if(skipLF){skipLF=false;if(ch==='\n')continue;}
  if(quoted){if(ch==='"'){quoted=false;afterQuote=true;}else field+=ch;continue;}
  if(afterQuote&&ch==='"'){field+='"';quoted=true;afterQuote=false;continue;}afterQuote=false;
  if(ch==='"'&&!field){quoted=true;continue;}
  if(ch===','||ch==='\n'||ch==='\r'){row.push(field);field='';if(ch!==','){if(ch==='\r')skipLF=true;if(!columns)columns=row.map(x=>x.replace(/^\uFEFF/,''));else if(row.some(Boolean)){const out={};columns.forEach((key,i)=>out[key]=row[i]||'');yield out;}row=[];}}
  else field+=ch;
 }}
 if(quoted)throw Error('CSV con una comilla sin cerrar.');if(field||row.length){row.push(field);if(columns){const out={};columns.forEach((key,i)=>out[key]=row[i]||'');yield out;}}
}
export function gtfsMinutes(t){if(!/^\d{1,2}:\d{2}:\d{2}$/.test(t))return NaN;const [h,m,s]=t.split(':').map(Number);return m<60&&s<60?h*60+m+s/60:NaN;}
export async function zipEntries(file){
 if(file.size>80e6)throw Error('El ZIP supera 80 MB.');const end=new Uint8Array(await file.slice(Math.max(0,file.size-65557)).arrayBuffer());const view=new DataView(end.buffer);let eocd=-1;
 for(let i=end.length-22;i>=0;i--)if(view.getUint32(i,true)===0x06054b50){eocd=i;break;}
 if(eocd<0)throw Error('No es un ZIP GTFS válido.');const count=view.getUint16(eocd+10,true),centralOffset=view.getUint32(eocd+16,true),centralSize=view.getUint32(eocd+12,true);if(count>100||centralSize>1e6)throw Error('Demasiados archivos en el ZIP.');
 const data=new DataView(await file.slice(centralOffset,centralOffset+centralSize).arrayBuffer()),names=new Map();let offset=0,total=0;
 for(let i=0;i<count;i++){if(offset+46>data.byteLength||data.getUint32(offset,true)!==0x02014b50)throw Error('Directorio ZIP dañado.');const flags=data.getUint16(offset+8,true),method=data.getUint16(offset+10,true),size=data.getUint32(offset+20,true),plain=data.getUint32(offset+24,true),len=data.getUint16(offset+28,true),extra=data.getUint16(offset+30,true),comment=data.getUint16(offset+32,true),local=data.getUint32(offset+42,true);const name=new TextDecoder().decode(new Uint8Array(data.buffer,offset+46,len)).split('/').at(-1).toLowerCase();offset+=46+len+extra+comment;total+=plain;
  if(flags&1||![0,8].includes(method)||plain>420e6||total>650e6)throw Error('Formato ZIP o tamaño descomprimido no admitido.');
  if(/^(stops|routes|trips|stop_times|calendar|calendar_dates|shapes|feed_info|agency|frequencies)\.txt$/.test(name))names.set(name,{size,plain,method,local});
 }
 for(const required of ['stops.txt','routes.txt','trips.txt','stop_times.txt'])if(!names.has(required))throw Error('Falta '+required+' en el GTFS.');
 async function* chunks(name){const entry=names.get(name);if(!entry)return;const header=new DataView(await file.slice(entry.local,entry.local+30).arrayBuffer());if(header.getUint32(0,true)!==0x04034b50)throw Error('Cabecera ZIP inválida.');const begin=entry.local+30+header.getUint16(26,true)+header.getUint16(28,true);let stream=file.slice(begin,begin+entry.size).stream();if(entry.method===8)stream=stream.pipeThrough(new DecompressionStream('deflate-raw'));let consumed=0;stream=stream.pipeThrough(new TransformStream({transform(chunk,controller){consumed+=chunk.byteLength;if(consumed>entry.plain)throw Error('Tamaño de archivo inconsistente.');controller.enqueue(chunk);}}));const reader=stream.pipeThrough(new TextDecoderStream()).getReader();
  try{while(true){const {value,done}=await reader.read();if(done){if(consumed!==entry.plain)throw Error('Tamaño de archivo inconsistente.');break;}yield value;}}finally{await reader.cancel().catch(()=>{});reader.releaseLock();}
 }
 return {names,rows:name=>csvRecords(chunks(name))};
}
export async function importGTFS(file,progress=()=>{}){
 const zip=await zipEntries(file),feed={version:1,name:file.name,imported:new Date().toISOString().slice(0,10),stops:Object.create(null),routes:Object.create(null),trips:Object.create(null),calendar:[],exceptions:[],shapes:Object.create(null),dateStart:null,dateEnd:null};let count=0;
 const tables=['stops','routes','trips','stop_times','calendar','calendar_dates','shapes','feed_info','frequencies'];
 for(const table of tables){progress('Leyendo '+table+'.txt…');count=0;
  for await(const r of zip.rows(table+'.txt')){count++;if(count%50000===0){progress(table+': '+count.toLocaleString('es-ES')+' filas');await new Promise(resolve=>setTimeout(resolve,0));}
   if(table==='stops'){const lon=+r.stop_lon,lat=+r.stop_lat;if(r.stop_id&&Number.isFinite(lon)&&Number.isFinite(lat)&&Math.abs(lon)<=180&&Math.abs(lat)<=90)feed.stops[r.stop_id]={id:r.stop_id,name:r.stop_name,lon,lat};}
   if(table==='routes'&&([0,2].includes(+r.route_type)||(+r.route_type>=100&&+r.route_type<200)))feed.routes[r.route_id]={id:r.route_id,name:r.route_short_name||r.route_long_name||r.route_id,long:r.route_long_name,color:/^[0-9a-f]{6}$/i.test(r.route_color)?'#'+r.route_color:'#a52863',agency:r.agency_id};
   if(table==='trips')feed.trips[r.trip_id]={id:r.trip_id,route:r.route_id,service:r.service_id,shape:r.shape_id,headsign:r.trip_headsign,direction:+r.direction_id||0,times:[]};
   if(table==='stop_times'){const t=feed.trips[r.trip_id],arr=gtfsMinutes(r.arrival_time),dep=gtfsMinutes(r.departure_time);if((r.arrival_time&&!Number.isFinite(arr))||(r.departure_time&&!Number.isFinite(dep)))throw Error('Hora GTFS inválida.');if(t&&feed.stops[r.stop_id])t.times.push([+r.stop_sequence,r.stop_id,Number.isFinite(arr)?arr:null,Number.isFinite(dep)?dep:null]);}
   if(table==='frequencies'){const t=feed.trips[r.trip_id],start=gtfsMinutes(r.start_time),end=gtfsMinutes(r.end_time),headway=+r.headway_secs/60;if(t&&Number.isFinite(start)&&Number.isFinite(end)&&end>start&&headway>0)(t.frequencies||=[]).push({start,end,headway,exact:r.exact_times==='1'});}
   if(table==='calendar')feed.calendar.push(r);
   if(table==='calendar_dates')feed.exceptions.push([r.service_id,r.date,+r.exception_type]);
   if(table==='shapes'&&Number.isFinite(+r.shape_pt_lon)&&Number.isFinite(+r.shape_pt_lat))(feed.shapes[r.shape_id]||=([])).push([+r.shape_pt_sequence,+r.shape_pt_lon,+r.shape_pt_lat]);
   if(table==='feed_info'){feed.publisher=r.feed_publisher_name;feed.dateStart=/^\d{8}$/.test(r.feed_start_date)?r.feed_start_date:null;feed.dateEnd=/^\d{8}$/.test(r.feed_end_date)?r.feed_end_date:null;}
   if(count>2500000)throw Error('El GTFS supera el límite de filas por tabla.');
  }
 }
 for(const t of Object.values(feed.trips))t.times.sort((a,b)=>a[0]-b[0]);
 for(const [id,points] of Object.entries(feed.shapes))feed.shapes[id]=points.sort((a,b)=>a[0]-b[0]).map(p=>[p[1],p[2]]);
 const dates=[...feed.calendar.flatMap(c=>[c.start_date,c.end_date]),...feed.exceptions.map(e=>e[1])].filter(d=>/^\d{8}$/.test(d)).sort();feed.dateStart=feed.dateStart||dates[0];feed.dateEnd=feed.dateEnd||dates.at(-1);
 if(!/^\d{8}$/.test(feed.dateStart)||!/^\d{8}$/.test(feed.dateEnd)||!Object.keys(feed.trips).length)throw Error('El GTFS no contiene viajes y calendario utilizables.');
 progress('Horario importado.');return feed;
}
export function dateISO(d){return /^\d{8}$/.test(d)?`${d.slice(0,4)}-${d.slice(4,6)}-${d.slice(6,8)}`:d;}
export function scheduleFor(feed,date){
 if(feed?.feeds)return feed.feeds.flatMap((f,i)=>scheduleFor(f,date).map(t=>({...t,id:i+':'+t.id,route:i+':'+t.route}))).sort((a,b)=>a.dep-b.dep);
 if(!feed)return [];const key=date.replaceAll('-',''),weekday=['sunday','monday','tuesday','wednesday','thursday','friday','saturday'][new Date(date+'T12:00:00Z').getUTCDay()],services=new Set();
 for(const c of feed.calendar)if(key>=c.start_date&&key<=c.end_date&&c[weekday]==='1')services.add(c.service_id);
 for(const [id,d,type] of feed.exceptions)if(d===key){if(type===1)services.add(id);else if(type===2)services.delete(id);}
 const result=[];
 for(const t of Object.values(feed.trips)){if(!services.has(t.service)||t.times.length<2||!feed.routes[t.route])continue;const first=t.times[0],last=t.times.at(-1),route=feed.routes[t.route];if(first[3]===null||last[2]===null)continue;
  const base={id:t.id,route:t.route,name:route.name,headsign:t.headsign,dep:first[3],arrival:last[2],scheduled:last[2],duration:last[2]-first[3],direction:t.direction,delay:0,real:true,model:'Material no publicado en GTFS',times:t.times,stops:t.times.map(x=>feed.stops[x[1]]),coords:feed.shapes[t.shape]||t.times.map(x=>{const p=feed.stops[x[1]];return [p.lon,p.lat];}),geometryReal:!!feed.shapes[t.shape],color:route.color};if(base.arrival<base.dep)continue;
  if(!t.frequencies?.length)result.push(base);else for(const [j,f]of t.frequencies.entries()){if(!f.exact){result.push({...base,id:t.id+'-headway-'+j,dep:f.start,arrival:f.end,approximate:true,frequency:f,note:'Servicio por frecuencia; no hay salidas individuales exactas. No se dibuja un vehículo concreto.'});continue;}for(let dep=f.start,i=0;dep<f.end;i++,dep=f.start+i*f.headway){if(i>10000)throw Error('Frecuencia GTFS fuera de límites.');const delta=dep-base.dep;result.push({...base,id:t.id+'-frequency-'+j+'-'+i,dep,arrival:base.arrival+delta,times:base.times.map(row=>[row[0],row[1],row[2]===null?null:row[2]+delta,row[3]===null?null:row[3]+delta])});}}
 }
 return result.sort((a,b)=>a.dep-b.dep);
}
export function combineFeeds(current,incoming){const feeds=[...(current?.feeds|| (current?[current]:[]))].filter(f=>f.name!==incoming.name);feeds.push(incoming);const combined={version:2,name:feeds.map(f=>f.name).join(' + '),feeds,stops:Object.create(null),routes:Object.create(null),trips:Object.create(null),shapes:Object.create(null),dateStart:feeds.map(f=>f.dateStart).sort()[0],dateEnd:feeds.map(f=>f.dateEnd).sort().at(-1)};for(const [i,feed]of feeds.entries())for(const key of ['stops','routes','trips','shapes'])for(const [id,obj]of Object.entries(feed[key]))combined[key][i+':'+id]=obj;return combined;}
export async function storeFeed(feed){return new Promise((resolve,reject)=>{const req=indexedDB.open('iberia-real-timetables',1);req.onupgradeneeded=()=>req.result.createObjectStore('feeds');req.onerror=()=>reject(req.error);req.onsuccess=()=>{const db=req.result,tx=db.transaction('feeds','readwrite');tx.objectStore('feeds').put(feed,'latest');tx.oncomplete=()=>{db.close();resolve();};tx.onerror=()=>{db.close();reject(tx.error);};};});}
export async function loadFeed(){return new Promise(resolve=>{try{const req=indexedDB.open('iberia-real-timetables',1);req.onupgradeneeded=()=>req.result.createObjectStore('feeds');req.onerror=()=>resolve(null);req.onsuccess=()=>{const db=req.result,tx=db.transaction('feeds'),get=tx.objectStore('feeds').get('latest');get.onsuccess=()=>{db.close();resolve(get.result||null);};get.onerror=()=>{db.close();resolve(null);};};}catch{resolve(null);}});}
