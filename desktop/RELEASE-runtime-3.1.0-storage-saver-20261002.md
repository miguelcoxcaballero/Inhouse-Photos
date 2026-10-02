# Inhouse Photos: motor 3.1.0-storage-saver-20261002

Este paquete instala en el servidor las mejoras de compresión de la PR #16.
El gestor Windows continúa en la versión 1.2.16; su actualizador habitual
actualiza el gestor y este paquete actualiza el motor que procesa los archivos.

## Instalación

Descarga `Inhouse-Photos-Server-Runtime-3.1.0-storage-saver-20261002.zip` desde
esta publicación y extráelo. En el PC del servidor, con Docker Desktop activo,
cierra Inhouse Photos Server desde su icono de la bandeja. Abre PowerShell en
la carpeta extraída y ejecuta:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Actualizar-servidor.ps1
```

La biblioteca debe estar vinculada y verificada por el gestor. El actualizador
comprueba la compatibilidad de la imagen instalada, conserva la base de datos
y los montajes, espera las compresiones activas y reinicia el servicio de fotos.
Comprueba su salud antes de restaurar el estado original de las colas. Si se
interrumpe, el registro permite recuperar la operación con `-ResumeRecord`.
Los detalles de operación y recuperación están en `LEEME-Actualizar.md`.

La imagen publicada es `inhouse-photos-server:v3.1.0-storage-saver-20261002`,
con el commit de servidor identificado en `server-runtime-update.json`.
La publicación incluye el manifiesto y `SHA256SUMS.txt`; el lanzador verifica
los checksums del manifiesto, los scripts y el archivo de la imagen.

## Rendimiento y validación

En la imagen de producción, con cuatro núcleos y tres mediciones por archivo,
el lote sintético de JPEG y vídeo fue **3,46 veces más rápido** para archivos
que se recomprimen y **4,42 veces más rápido** incluyendo vídeos eficientes
que conserva sin recomprimir. Los resultados están en
`storage-saver-performance.json`. Son mediciones de este entorno, no del PC
del usuario ni una garantía para cada archivo: los JPEG de 24 MP medidos
mejoraron 2,58 veces y los rotados, 2,10 veces, conservando más resolución.

Fotos y vídeos tienen trabajadores separados. Los vídeos usan x264 ultrafast,
CRF 24, hilos limitados y compresión sin ampliar la resolución. Este ajuste
produce archivos mayores que el preset lento anterior; solo se sustituye el
original cuando el resultado ocupa menos. Las fotos conservan metadatos y
orientación y evitan las operaciones más costosas del codificador JPEG.

La imagen arrancó con PostgreSQL 14 y Valkey 9, confirmó salud y ausencia de
cambios de esquema, y pasó altas/inicio de sesión, subidas, compresión de
fotografías/vídeos, reutilización de vídeo eficiente y procesamiento de un
vídeo pendiente en la cola antigua. Pasaron 34 comprobaciones del actualizador
PowerShell y seis pruebas del helper de colas. La ejecución en Docker Desktop
del PC del usuario queda pendiente de aplicar el paquete.
