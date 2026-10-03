# Inhouse Photos 3.1.97 para Windows

Corrige las actualizaciones que permanecían en «Installing» sin confirmar
avances. Los comandos Docker tienen tiempos máximos; el actualizador detiene
los clientes y procesos hijos que creó, conserva la transacción pendiente y
permite reintentar. Cuando termina un instalador fallido, el gestor libera su
estado ocupado. Instalar el gestor nuevo reinicia los intentos de recuperación;
la actualización solo se completa tras verificar el motor, su salud y el recibo.

La app 3.1.97 puede consultar una operación sin avances desde **Actualizar**
antes de solicitar otra. La consulta de progreso es de lectura y no cancela ni
duplica la actualización del PC.

## Si 3.1.96 sigue en «Installing»

1. Descarga [el instalador Windows 3.1.97](https://github.com/miguelcoxcaballero/Inhouse-Photos/releases/download/server-v3.1.97/Inhouse-Photos-Server-Setup.exe) y abre en el PC el menú del icono junto al reloj. Si **Salir del gestor** está disponible, úsalo y ejecuta el instalador con el mismo usuario de Windows.
2. Si el gestor bloqueado impide salir, abre **Programador de tareas** (`taskschd.msc`). Deshabilita temporalmente solo **Inhouse Photos Server**, comprobando que su acción ejecuta `%LOCALAPPDATA%\Programs\Inhouse Photos Server\Inhouse Photos.exe` con el argumento `--startup`. Si esa tarea no existe, omite este paso.
3. Reinicia Windows y ejecuta el instalador 3.1.97 antes de abrir el gestor antiguo. En el nuevo programa, vuelve a habilitar **Inicio automático** si deshabilitaste la tarea. El reinicio interrumpe el acceso al servidor hasta que Windows y Docker vuelvan a estar disponibles.
4. Mantén el PC encendido. La solicitud guardada continúa automáticamente; si necesita otro intento, usa **Ajustes > Actualizaciones** en Windows. Instala también la app Android 3.1.97 para consultar el progreso.

El instalador conserva las fotos, cuentas, álbumes, discos, recibos y trabajos
pendientes. No hace falta borrar registros ni volver a subir los archivos.

El gestor publica automáticamente los nueve recursos del portal y refresca su
catálogo de Android y Windows en el directorio de descargas ya servido por
Caddy. Conserva las páginas personalizadas y comprueba los archivos antes de
sustituirlos. Esta entrega ocurre en el PC después de instalar el gestor;
publicar la release de GitHub por sí solo no modifica la web del servidor.

La publicación verifica los ejecutables x64, el payload, la instalación desde
3.1.96, los recursos web integrados, los comandos nativos de Windows y las
transacciones de recuperación. Los SHA-256 están en `SHA256SUMS.txt`.
