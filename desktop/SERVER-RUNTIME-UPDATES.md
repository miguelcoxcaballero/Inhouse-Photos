# Actualizar el motor del servidor Windows

La versión del gestor Windows y la del motor de fotos se actualizan por separado.
La recepción con cola persistente y las mejoras de compresión necesitan instalar
el paquete del motor en el PC que ejecuta Docker Desktop. Este actualizador se aplica a una
biblioteca previamente vinculada y verificada por Inhouse Photos Server.

Con Android **3.1.95** y el gestor Windows **1.2.17**, la actualización se solicita
desde **Ajustes > Gestión del servidor**, en la misma pantalla que muestra el
estado del servidor, los discos y las copias. Si aparece la actualización del
gestor Windows, instálala primero desde esa pantalla. Después pulsa
**Actualizar servidor**. El PC descarga, verifica e instala el motor; el móvil
muestra el progreso y confirma la versión instalada. La instalación continúa
aunque salgas de la pantalla del móvil.

La actualización del gestor conserva el motor en ejecución. La actualización
del motor reinicia brevemente la API de fotos y conserva la biblioteca y los
trabajos pendientes. Durante la operación, el gestor bloquea las operaciones
que podrían cambiar su configuración.

La instalación manual sigue disponible para diagnóstico:

Descarga el ZIP del motor desde la publicación oficial, extráelo en una carpeta
local, cierra el gestor desde su icono de la bandeja y ejecuta el lanzador
`Actualizar-servidor.ps1` incluido en el paquete, con el mismo usuario de Windows
que utiliza el gestor. El lanzador fija los SHA-256 reales del manifiesto y de
los scripts; no requiere introducir credenciales.

El paquete contiene una imagen completa del motor y puede rondar 1 GB
comprimido. Reserva espacio para extraerla y para que Docker conserve ambas
imágenes. La preparación espera hasta 15 minutos a que terminen las
compresiones que ya están activas. Conserva los trabajos pendientes; no los
borra. La API se reinicia brevemente durante la sustitución del motor. Una
actualización correcta muestra la nueva versión y el commit instalado.

## Operación y verificación

`server-runtime-update.ps1` verifica el SHA-256 publicado del manifiesto y del
archivo `docker save`, el commit OCI de la imagen, su ID y la plataforma
`linux/amd64` y el hash del esquema compilado. El manifiesto permite únicamente
imágenes de origen cuya compatibilidad se verificó. La versión
`3.1.0-durable-upload-20261003` admite el motor original publicado y el motor
`3.1.0-storage-saver-20261002`. Añade una sola migración identificada:
`1790985600000-DurableUploadProcessing`, que crea la cola persistente y los
recibos de subida en PostgreSQL sin sustituir ni borrar las tablas existentes.
Los recibos permiten reconocer reintentos del archivo original después de
comprimirlo. Los SHA-256 de la imagen/configuración originales pueden diferir entre
almacenes Docker; ambos identificadores deben constar explícitamente en la
lista de imágenes compatibles de la publicación.

Antes de aplicar, comprueba el recibo de vinculación y su snapshot verificado,
los hashes de `docker-compose.yml`, `.env` y `Caddyfile`, el proyecto Compose,
todos los servicios y montajes, y la imagen de la base de datos. Sin `-Apply`,
solo realiza esta preparación de lectura:

```powershell
.\server-runtime-update.ps1 -ManifestPath .\server-runtime-update.json `
  -ManifestSha256 '<SHA-256 publicado del manifiesto>' `
  -ArchivePath .\<archivo de imagen indicado por el manifiesto>
```

Para instalar, el lanzador del ZIP añade `-Apply` con las rutas y checksums
reales de la publicación. El actualizador pausa las dos colas de Storage Saver,
deja terminar las compresiones activas y cambia exclusivamente la línea `image`
de `immich-server`. Ejecuta `compose up -d --no-deps --pull never immich-server`.
La base de datos, Redis, el proxy, los otros contenedores y sus montajes deben
conservar la misma identidad. Tras confirmar salud y montajes, actualiza el
recibo y restaura el estado de pausa que tenían las colas.

El helper de colas se ejecuta en un contenedor temporal sin montajes y con
entrada `node`; usa las APIs de pausa y consulta de BullMQ y consultas de lectura
en PostgreSQL para verificar si se puede volver a un motor anterior. Las
variables del servidor se copian de forma temporal a un archivo privado del
usuario, no se registran ni se muestran, y se eliminan al finalizar.

## Recuperación

Si el motor sigue respondiendo a la API, el móvil permite reanudar una
actualización pendiente desde la misma pantalla. Si la API quedó totalmente
detenida, el gestor no puede verificar una nueva sesión de administrador del
móvil: abre **Ajustes > Actualizaciones del motor** en Windows para recuperarla.

La actualización conserva los bytes originales de Compose y del recibo, el
ID de la imagen anterior y un registro de transacción dentro de
`%LOCALAPPDATA%\Inhouse Photos Server\runtime-updates`. No elimina la imagen
anterior. Evita limpiar imágenes Docker hasta confirmar la actualización.

Si el arranque falla antes de aplicar la migración, intenta volver a la imagen
anterior conservando los trabajos. Si quedan vídeos en la cola nueva, archivos
en la cola persistente o ya se instaló la migración de esa cola, se rechaza el
rollback. El motor anterior tampoco reconoce una migración más reciente aunque
la cola ya esté vacía. La recuperación continúa con el motor nuevo mediante
`-ResumeRecord`; el actualizador no revierte migraciones ni elimina archivos o
filas de la base de datos. No se deben borrar colas ni restaurar la base de datos
para resolver ese caso. Tras
un fallo que requiera recuperación, las colas pueden quedar pausadas; el
registro y las copias indican qué paso se completó.

Si se cierra PowerShell a mitad de la operación, el siguiente intento detecta
el registro pendiente y muestra su ruta. Para terminar esa transacción y
recuperar el estado original de pausa, con el gestor cerrado:

```powershell
.\server-runtime-update.ps1 -ResumeRecord '<ruta de transaction.json>'
.\server-runtime-update.ps1 -ResumeRecord '<ruta de transaction.json>' -Apply
```

Esta recuperación confirma la imagen que corresponde al Compose conservado,
su salud y sus montajes, completa el recibo y restaura las pausas registradas
antes de la actualización. No toma la pausa accidental del intento interrumpido
como el estado original. Si la recuperación tampoco se confirma, mantiene las
copias y el registro para poder reintentar.

Para solicitar una recuperación posterior, con el gestor cerrado:

```powershell
.\server-runtime-update.ps1 -RollbackRecord '<ruta de transaction.json>'
.\server-runtime-update.ps1 -RollbackRecord '<ruta de transaction.json>' -Apply
```

La segunda instrucción verifica que sigue siendo la misma instalación, pausa
las colas, espera los trabajos activos y comprueba las colas y el esquema antes
de restaurar la imagen y su recibo. La restauración se rechaza si cambió
la configuración, otro contenedor o un montaje. No ejecuta `compose down`, no
elimina volúmenes y no modifica cuentas.

## Checks de desarrollo

```powershell
powershell -NoProfile -File desktop\server-runtime-update.tests.ps1
node --test desktop/server-runtime-queue-handoff.test.cjs
python desktop/build-server-runtime.test.py
```

Los checks comprueban rechazo de cambios de base de datos, montajes, identidad,
configuración, manifiestos incompatibles y YAML ambiguo, así como pausa y
recuperación de colas sin pérdida de trabajos. El empaquetado exige dependencias
idénticas a las del motor base y un build completo limpio, incluida la migración.
La publicación verifica subidas con el procesado detenido y recuperación tras
reiniciar el servidor y perder las colas Redis. Una instalación real debe
confirmar además la salud de la imagen publicada en Docker Desktop.
