# Inhouse Photos: motor 3.1.0-durable-upload-20261003

El servidor guarda los archivos recibidos y una lista persistente de trabajos
en PostgreSQL. La subida termina cuando el original está guardado y registrado,
sin esperar la compresión, los metadatos o las miniaturas. Puede acumular archivos
mientras haya espacio en el disco del servidor y procesarlos después de
desconectar el móvil. El procesado avanza también durante las subidas.

Redis recibe una ventana limitada de trabajos; el resto permanece en la base
de datos hasta que hay trabajadores disponibles. Tras un reinicio o pérdida
de las colas Redis, el motor recupera los trabajos pendientes desde PostgreSQL.
Los errores de procesado conservan el original y se reintentan.

## Instalación

Descarga `Inhouse-Photos-Server-Runtime-3.1.0-durable-upload-20261003.zip` y
extráelo en el PC del servidor. Con Docker Desktop activo, cierra Inhouse Photos
Server desde su icono de la bandeja. Abre PowerShell en la carpeta extraída:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Actualizar-servidor.ps1
```

La biblioteca debe estar vinculada y verificada por el gestor. El actualizador
acepta el motor original publicado y el motor Storage Saver de 20261002,
verifica la imagen y sus checksums, conserva los montajes y añade la tabla de
trabajos pendientes. Solo reinicia `immich-server`. La versión que muestra el
gestor Windows puede seguir siendo la del gestor; el resultado del script
identifica la versión y el commit del motor instalado.

La actualización del móvil de esta función permite seguir enviando archivos
sin esperar a que termine el procesado del servidor. Instala también el APK
publicado con esta función para aprovechar ese cambio en el cliente.

## Recuperación y validación

Después de aplicar la migración, el motor anterior no reconoce el esquema
actual. El actualizador rechaza el rollback y conserva el motor nuevo, los
originales, los trabajos pendientes y el registro de recuperación. Si se
interrumpe, utiliza `-ResumeRecord` según `LEEME-Actualizar.md`; no borres colas
ni restaures la base de datos para volver al motor anterior.

La publicación incluye `durable-backlog-results.json` con una prueba de subida
de 48 archivos con el procesado detenido, comprobación de originales después
de reiniciar el servidor y borrar Redis, y finalización de los trabajos
recuperados. `runtime-smoke-results.json` verifica el arranque, la API, las
subidas y el procesado de fotos y vídeos.

Se mantienen los trabajadores separados y los ajustes rápidos de compresión.
El benchmark de esta imagen, con {{CPUS}} núcleos, midió {{ENCODED_SPEEDUP}}
veces más velocidad en el lote que recomprime y {{BATCH_SPEEDUP}} veces
incluyendo vídeos que ya son eficientes. Es una medición sintética del motor,
no una medición de velocidad de subida del móvil.

El ZIP incluye la imagen completa, el manifiesto y los resultados de validación.
El lanzador comprueba los SHA-256 del manifiesto, los scripts y la imagen;
`SHA256SUMS.txt` permite verificar también los informes publicados.
