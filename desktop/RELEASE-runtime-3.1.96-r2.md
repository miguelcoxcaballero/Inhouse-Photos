# Inhouse Photos 3.1.96: scripts de actualización corregidos (r2)

Esta publicación corrige los scripts de actualización para Windows PowerShell
5.1. Docker puede escribir progreso en stderr aunque el comando termine
correctamente. El helper conserva la salida JSON separada, comprueba el código
de salida y permite reanudar una actualización interrumpida sin repetir ese
fallo. Se mantienen las comprobaciones de identidad, la recuperación del
registro de actualización y el bloqueo de un rollback incompatible con la base
de datos.

También se conserva una línea por variable al preparar el entorno del helper
de colas, incluyendo los valores que contienen espacios; PowerShell 5.1 podía
juntar esas variables e impedir la conexión con Redis o PostgreSQL.

El motor y la API siguen siendo **3.1.96**. Se reutilizan, sin reconstruirlos,
el manifiesto, el archivo de imagen y los tres informes de validación de
`server-runtime-v3.1.96`. Su commit de origen sigue siendo
`2c36a66f40347273f9f2f75242e42cda3091a1a3` y la imagen conserva el identificador
`sha256:0781b4081482853b34963f4e8faefc4c92d4a25da87f45dd3cf9f93ce645062c`.
Los informes describen las comprobaciones del motor original; esta revisión
añade pruebas de los scripts en Windows PowerShell 5.1 y de sus transacciones
de actualización y recuperación.

Descarga `Inhouse-Photos-Server-Runtime-3.1.96.zip` desde esta publicación
`server-runtime-v3.1.96-r2` y consulta `LEEME-Actualizar.md`. El ZIP incluye los
scripts corregidos, el lanzador que verifica sus hashes, la misma imagen y los
informes originales. `SHA256SUMS.txt` permite comprobar los archivos publicados.
El commit señalado por esta publicación identifica los scripts corregidos;
`sourceCommit` en el manifiesto identifica el motor original.

La publicación original permanece intacta. Esta revisión se publica como
prerelease y no cambia la publicación marcada como latest.
