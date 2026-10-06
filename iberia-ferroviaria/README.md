# Iberia Ferroviaria · v0.3

Juego de gestión ferroviaria en español: diriges Renfe de 2022 a 2050 sobre el mapa de España, con **el horario oficial de todos los trenes** (Cercanías, Rodalies, Media Distancia, Larga Distancia y Alta Velocidad).

- **Jugar:** abre [`outputs/Iberia-Ferroviaria.html`](outputs/Iberia-Ferroviaria.html) en un navegador moderno. Funciona sin conexión.
- **Instrucciones, datos y licencias:** [`proyecto/LEEME.txt`](proyecto/LEEME.txt).
- **Estado y próximos pasos:** [`proyecto/PLAN.txt`](proyecto/PLAN.txt) · **Verificación:** [`proyecto/VERIFICACION.txt`](proyecto/VERIFICACION.txt).

```sh
cd proyecto
npm run timetable   # regenera dist/assets/timetable.js desde investigacion/gtfs (Python 3 + numpy)
npm run build       # genera ../outputs/Iberia-Ferroviaria.html
npm test            # motor, campaña completa, horario oficial y jornadas
node ui-v3-test.mjs /ruta/a/playwright/index.mjs   # recorrido de interfaz con capturas
```

Horarios: Renfe Data (CC BY 4.0). Vías: © OpenStreetMap contributors (ODbL). Historia alternativa: la escasez inicial, los cierres de 2022 y los personajes son ficción; la economía y 2027–2050 son simulación.
