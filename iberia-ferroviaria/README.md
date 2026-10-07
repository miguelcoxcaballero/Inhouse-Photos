# Iberia Ferroviaria · v2.0

Juego de gestión ferroviaria en español: diriges la alta velocidad de Renfe de 2022 a 2050 sobre el mapa de España. Solo hay **AVE y Alvia**, y lo que puede circular depende de la vía: ancho estándar, ibérico o mixto, con catenaria o sin ella. Electrificas, pones tercer carril, pasas líneas a ancho estándar y construyes cambiadores, con **el horario oficial de todos los AVE y Alvia**, mapas de anchos y de electrificación, nueve personajes satíricos con retrato propio y tres caras, imprevistos que te obligan a decidir, trenes en 3D, banda sonora original y voces en castellano de España.

- **Jugar:** abre [`outputs/Iberia-Ferroviaria.html`](outputs/Iberia-Ferroviaria.html) en un navegador moderno. Funciona sin conexión.
- **Instrucciones, datos y licencias:** [`proyecto/LEEME.txt`](proyecto/LEEME.txt).
- **Estado y próximos pasos:** [`proyecto/PLAN.txt`](proyecto/PLAN.txt) · **Verificación:** [`proyecto/VERIFICACION.txt`](proyecto/VERIFICACION.txt).

```sh
cd proyecto
npm run infra       # regenera la red de anchos y catenaria (dist/assets/infra.js) sobre las vías OSM
npm run timetable   # regenera el horario AVE y Alvia desde investigacion/gtfs (Python 3 + numpy)
npm run build       # genera ../outputs/Iberia-Ferroviaria.html y la versión web ../outputs/web/
npm test            # reglas del juego y campaña completa 2022–2050 jugada por un jugador automático
node ui-test.mjs /ruta/a/playwright/index.mjs   # recorrido de interfaz con capturas
```

Horarios: Renfe Data (CC BY 4.0). Vías: © colaboradores de OpenStreetMap (ODbL). three.js (MIT). La economía y lo que pasa desde 2027 es simulación.
