import windowsUpdate from '../../windows-server-update.json';
import androidUpdate from '../../android-update.json';
const windowsChecksums = windowsUpdate.InstallerUrl.slice(0, windowsUpdate.InstallerUrl.lastIndexOf('/') + 1) + 'SHA256SUMS.txt';
const androidChecksums = androidUpdate.apkUrl.slice(0, androidUpdate.apkUrl.lastIndexOf('/') + 1) + 'SHA256SUMS.txt';
export const dynamic = 'force-static';
export default function Home() {
 return <div className="download-page">
 <header><a className="brand" href="https://fotos.miguelcoxcaballero.com"><img src="./inhouse.svg" alt="" width="44" height="44" />inhouse photos</a><a href="https://fotos.miguelcoxcaballero.com">Abrir fotos ↗</a></header>
 <main><p className="eyebrow">EN TUS DISPOSITIVOS</p><h1>Tus fotos.<br /><span>En tu casa.</span></h1><p className="intro">La app para llevarlas contigo. El servidor para cuidarlas.</p>
 <section className="downloads" aria-label="Descargar aplicaciones">
 <article><span className="platform">01 / MÓVIL</span><h2>Android</h2><p>Tu galería, álbumes y copia de seguridad automática.</p><a className="download" href={androidUpdate.apkUrl}>Descargar APK <span aria-hidden>↓</span></a><small>Android 8 o posterior · Versión {androidUpdate.version} · Actualiza sin desinstalar</small></article>
 <article><span className="platform">02 / EN CASA</span><h2>Windows</h2><p>Conecta tu biblioteca actual o crea una nueva, guiado paso a paso, desde una interfaz sencilla.</p><a className="download secondary" href={windowsUpdate.InstallerUrl}>Descargar para Windows <span aria-hidden>↓</span></a><small>Windows 10 / 11 · Versión {windowsUpdate.Version} · Instalador y asistente para crear una biblioteca nueva.</small><small>Para actualizar el gestor que ya está abierto, sal desde su icono junto al reloj y ejecuta el instalador. Esto no detiene el servidor ni toca la biblioteca; volverá a iniciarse al entrar en Windows.</small><small>La biblioteca existente no se sustituye. El PC debe estar encendido para acceder remotamente.</small><small>Para acceso desde fuera de casa, configura un dominio y los puertos del router. No es compatible con todas las conexiones CGNAT. Primera instalación de Docker: puede requerir permisos de administrador y reiniciar Windows.</small><small>Ejecutable sin firma digital; mantén las protecciones de Windows activadas. RAID solo aparece si hay discos vacíos compatibles.</small><small><a href={windowsChecksums}>Verificar instalador ↗</a></small></article>
 </section><p className="note">¿Usas iPhone? <a href="https://fotos.miguelcoxcaballero.com">Abre la versión web</a> y añádela a tu pantalla de inicio. La copia automática en segundo plano requiere la app nativa.</p></main>
 <footer><span>Tu biblioteca sigue siendo tuya.</span><a href={androidChecksums}>Verificar descargas ↗</a><a href="https://github.com/miguelcoxcaballero/Inhouse-Photos">Código fuente ↗</a></footer></div>;
}
