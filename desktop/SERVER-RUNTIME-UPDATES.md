# Actualizar el motor del servidor Windows

Actualizar el gestor Windows 1.2.16 no cambia la imagen que procesa las fotos.
Las mejoras de compresión necesitan instalar el paquete de actualización del
motor en el PC que ejecuta Docker Desktop. Este actualizador se aplica a una
biblioteca previamente vinculada y verificada por Inhouse Photos Server.

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
`linux/amd64`. El manifiesto permite únicamente imágenes de origen cuya
compatibilidad se verificó y una actualización sin cambios de esquema de base
de datos. Los SHA-256 de la imagen/configuración originales pueden diferir entre
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
entrada `node`; usa únicamente las APIs de pausa y consulta de BullMQ. Las
variables del servidor se copian de forma temporal a un archivo privado del
usuario, no se registran ni se muestran, y se eliminan al finalizar.

## Recuperación

La actualización conserva los bytes originales de Compose y del recibo, el
ID de la imagen anterior y un registro de transacción dentro de
`%LOCALAPPDATA%\Inhouse Photos Server\runtime-updates`. No elimina la imagen
anterior. Evita limpiar imágenes Docker hasta confirmar la actualización.

Si el arranque falla, intenta volver a la imagen anterior conservando los
trabajos. La versión anterior no procesa la cola nueva de vídeos: si quedan
trabajos en ella, el rollback se rechaza y se conserva el motor nuevo. No se
deben borrar colas ni restaurar la base de datos para resolver ese caso. Tras
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
las colas, espera los trabajos activos y comprueba que la cola nueva está vacía
antes de restaurar la imagen y su recibo. La restauración se rechaza si cambió
la configuración, otro contenedor o un montaje. No ejecuta `compose down`, no
elimina volúmenes y no modifica cuentas.

## Checks de desarrollo

```powershell
powershell -NoProfile -File desktop\server-runtime-update.tests.ps1
node --test desktop/server-runtime-queue-handoff.test.cjs
```

Los checks comprueban rechazo de cambios de base de datos, montajes, identidad,
configuración, manifiestos incompatibles y YAML ambiguo, así como pausa y
recuperación de colas sin pérdida de trabajos. Una instalación real debe
confirmar además la salud de la imagen publicada en Docker Desktop.
