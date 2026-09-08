const releases = 'https://github.com/miguelcoxcaballero/Inhouse-Photos/releases';
export const dynamic = 'force-static';
export default function Home() {
 return <div className="download-page">
 <header><a className="brand" href="https://fotos.miguelcoxcaballero.com"><img src="./inhouse.svg" alt="" width="44" height="44" />inhouse photos</a><a href="https://fotos.miguelcoxcaballero.com">Abrir fotos ↗</a></header>
 <main><p className="eyebrow">EN TUS DISPOSITIVOS</p><h1>Tus fotos.<br /><span>En tu casa.</span></h1><p className="intro">La app para llevarlas contigo. El servidor para cuidarlas.</p>
 <section className="downloads" aria-label="Descargar aplicaciones">
 <article><span className="platform">01 / MÓVIL</span><h2>Android</h2><p>Tu galería, álbumes y copia de seguridad automática.</p><a className="download" href={releases+'/download/v3.1.80-connected/Inhouse-Photos-3.1.80-arm64.apk'}>Descargar APK <span aria-hidden>↓</span></a><small>Android 8 o posterior · Actualiza sin desinstalar</small></article>
 <article><span className="platform">02 / EN CASA</span><h2>Windows</h2><p>Administra tu servidor, el almacenamiento y la conexión del móvil.</p><a className="download secondary" href={releases+'/download/v3.1.80-connected/Inhouse-Photos-Server.exe'}>Descargar para Windows <span aria-hidden>↓</span></a><small>Windows 10 / 11 · Vista previa 0.1, para servidores existentes</small><small>Instalación nueva y RAID integrado, próximamente. Ejecutable sin firma digital; no desactives las protecciones de Windows.</small></article>
 </section><p className="note">¿Usas iPhone? <a href="https://fotos.miguelcoxcaballero.com">Abre la versión web</a> y añádela a tu pantalla de inicio. La copia automática en segundo plano requiere la app nativa.</p></main>
 <footer><span>Tu biblioteca sigue siendo tuya.</span><a href={releases+'/download/v3.1.80-connected/SHA256SUMS.txt'}>Verificar descargas ↗</a><a href="https://github.com/miguelcoxcaballero/Inhouse-Photos">Código fuente ↗</a></footer></div>;
}
