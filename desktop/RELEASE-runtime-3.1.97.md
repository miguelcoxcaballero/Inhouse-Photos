# Inhouse Photos 3.1.97: motor del servidor

El motor y la API muestran la versión 3.1.97. Se conserva la cola persistente:
los archivos recibidos quedan guardados antes de procesarse y las subidas
continúan mientras haya espacio. PostgreSQL conserva los trabajos y los recibos
de subida para recuperarlos después de un reinicio o de perder las colas Redis.

El actualizador corrige las esperas indefinidas de Docker en Windows. Separa el
progreso de stderr de la salida JSON y comprueba los códigos de salida. Cada
comando tiene un tiempo máximo: las consultas ordinarias disponen de 30
segundos, cargar la imagen de 10 minutos y los cambios de contenedor de 3
minutos. Las esperas de compresiones activas y de salud también están acotadas.
Al detener una operación, limpia los clientes y procesos hijos que creó y
conserva el registro necesario para recuperarla. Una espera agotada no confirma
una instalación ni autoriza volver a una imagen incompatible con el esquema.

Para un gestor 3.1.96 que siga en «Installing», instala primero
[Windows 3.1.97](https://github.com/miguelcoxcaballero/Inhouse-Photos/releases/download/server-v3.1.97/Inhouse-Photos-Server-Setup.exe)
con el mismo usuario. Usa **Salir del gestor** si está disponible. Si la versión
antigua impide salir, deshabilita temporalmente en Programador de tareas solo
**Inhouse Photos Server**, cuya acción es el launcher local
`%LOCALAPPDATA%\Programs\Inhouse Photos Server\Inhouse Photos.exe --startup`;
reinicia Windows, instala el programa nuevo y vuelve a habilitar **Inicio
automático**. El nuevo gestor continúa la solicitud guardada y conserva la
biblioteca y el procesamiento pendiente.

La publicación valida la versión real de la API, arranque, subidas, procesado y
recuperación de la cola persistente. Las pruebas de Windows comprueban comandos
nativos, códigos de salida, tiempos máximos, procesos hijos y recuperación de
transacciones. El benchmark, con {{CPUS}} núcleos, midió {{ENCODED_SPEEDUP}}
veces más velocidad en el lote que recomprime y {{BATCH_SPEEDUP}} veces incluyendo
vídeos que ya son eficientes. Son mediciones sintéticas del motor.

`Inhouse-Photos-Server-Runtime-3.1.97.zip` contiene la imagen, manifiesto,
actualizador e informes. El lanzador verifica los SHA-256 antes de actuar.
Consulta `LEEME-Actualizar.md` para instalación y recuperación local.
