# Inhouse Photos 3.1.96: motor del servidor

La API del servidor y la imagen publicada muestran la versión 3.1.96, igual que
la app y el gestor Windows. Se conservan las dependencias verificadas y el
procesado con cola persistente de la versión anterior.

Los archivos recibidos quedan guardados en el servidor antes de procesarse.
Las subidas pueden continuar mientras haya espacio, y los trabajos pendientes
se recuperan desde PostgreSQL tras reinicios o pérdida de Redis. La actualización
acepta también el motor durable-upload de 20261003 y conserva sus trabajos,
originales, base de datos y montajes.

El gestor Windows 3.1.96 aplica este motor al actualizar Inhouse Photos. La
continuación queda guardada en el ordenador y puede completar el proceso aunque
el móvil se desconecte. Esta publicación incluye también el paquete
`Inhouse-Photos-Server-Runtime-3.1.96.zip` para una instalación local verificada.

Se corrige el tratamiento del progreso que Docker escribe en stderr al usar
Windows PowerShell 5.1. Los scripts distinguen la salida JSON del progreso y
comprueban el código de salida del proceso. Una actualización interrumpida
conserva sus registros y puede reanudarse; no vuelve a un motor que no pueda
leer la migración y los trabajos nuevos.

La publicación valida la versión real de la API, el arranque, las subidas y el
procesado de fotos y vídeos. `durable-backlog-results.json` verifica 48 archivos
recibidos con el procesado detenido y su recuperación tras reiniciar el servidor
y borrar Redis. El benchmark, con {{CPUS}} núcleos, midió {{ENCODED_SPEEDUP}}
veces más velocidad en el lote que recomprime y {{BATCH_SPEEDUP}} veces incluyendo
vídeos que ya son eficientes. Son mediciones sintéticas del motor.

El ZIP contiene la imagen, el manifiesto y los informes de validación. El
lanzador verifica los SHA-256 del manifiesto, los scripts y la imagen. Consulta
`LEEME-Actualizar.md` para instalación y recuperación local.
