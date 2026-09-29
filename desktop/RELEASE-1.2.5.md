# Inhouse Photos Server 1.2.5 (Windows)

«Conectar móvil» ofrece ahora un QR temporal como camino principal. El móvil
muestra la cuenta, el ordenador y un código de seis cifras; el gestor muestra el
mismo código y exige aprobación explícita antes de crear una sesión nueva para
el teléfono. El QR no contiene contraseñas ni tokens de inicio de sesión,
caduca en tres minutos y no puede reutilizarse.

El gestor conserva solo una sesión de administrador protegida con DPAPI para
el usuario actual de Windows; puede cerrarse desde la misma pantalla. La
dirección y el inicio de sesión manual siguen disponibles como alternativa.
La generación del QR es local y no requiere un servicio externo.

La instalación actualiza solo el gestor. No mueve la biblioteca ni modifica
los volúmenes de fotos o de base de datos. El nuevo flujo requiere que el
servidor admita la API de vinculación y que el móvil tenga la app actualizada.
