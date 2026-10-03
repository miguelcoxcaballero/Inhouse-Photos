# Inhouse Photos Server 1.2.17

Permite actualizar el motor de fotos desde la app del móvil y ver la versión y el progreso de la actualización. Los archivos recibidos quedan guardados en el servidor y su procesamiento continúa cuando el móvil se desconecta.

El gestor descarga el paquete publicado, comprueba sus hashes y utiliza el actualizador integrado. La actualización del motor conserva las carpetas de fotos, la base de datos y sus contenedores. Los comandos remotos requieren una sesión de administrador y solo permiten aplicar la versión publicada.

El instalador actualiza el gestor 1.2.16 mediante el mecanismo existente. El motor de fotos se actualiza después desde la app; la instalación del gestor conserva la biblioteca actual.

La publicación verifica el ejecutable x64, el contenido del instalador, los recursos integrados, las comprobaciones del gestor y una instalación real de 1.2.16 a 1.2.17 en un entorno Windows aislado. El ejecutable no está firmado con Authenticode; se publica su SHA-256. No requiere desactivar SmartScreen ni el antivirus.
