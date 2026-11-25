# ClearWidget — 0.2.0 (validación técnica)
Widget mediano para iPhone, SwiftUI + WidgetKit. Reconstrucción visual de referencia; no contiene imágenes de terceros ni capturas del fondo.

- Tres vistas excluyentes; navegación mediante AppIntent en la extensión.
- Estado local de la extensión, compartido entre instancias del mismo widget; no App Groups.
- Sin temporizadores, GPS, polling continuo ni procesos persistentes. Pronóstico de Open-Meteo (ECMWF IFS HRES 9 km), uso personal no comercial. Ubicación fija: Córdoba Capital; no requiere permiso de ubicación.
- WidgetKit solicita una actualización cada 30 minutos y al cambio de día; iOS decide cuándo ejecutarla. La navegación usa la caché y suprime nuevas consultas durante 15 segundos. Una petición para temperatura actual, próxima hora y máxima horaria de mañana. Caché válida 30 min; conserva el último pronóstico hasta 6 h si falla la red, luego muestra guiones. Reintento no antes de 15 min.
- Fondo administrado por el sistema. El modo Claro de la pantalla de inicio habilita el material de cristal; el sistema puede transformar los colores.
- Los enlaces al clima y calendario se enrutan mediante la app contenedora (puede aparecer brevemente); esquemas externos sujetos a prueba en el dispositivo.
- Datos: [Open-Meteo](https://open-meteo.com/) / [ECMWF](https://www.ecmwf.int/) (CC BY 4.0). Pronóstico modelado, no lectura de estación; la máxima de mañana se calcula con las horas locales. Los iconos SF Symbols y la tipografía manuscrita siguen siendo aproximaciones provisionales. La API en vivo y el funcionamiento en iOS aún requieren validación.
- No hay aún personalización de las acciones desde la app.

## Compilar
Actions → Build ClearWidget IPA. El IPA es sin firmar; SideStore debe firmar app y extensión. No se garantiza compatibilidad hasta instalar y probar.
## Pruebas
El workflow ejecuta Tests/WeatherTests.swift sobre un pronóstico sintético determinista antes de compilar. No demuestra precisión meteorológica ni consumo en iPhone.
## Criterios de aceptación en iPhone
1. Instalar y agregar widget mediano. Verificar cristal nativo sobre dos fondos distintos.
2. Alternar 30 veces las tres pantallas; registrar video a 60 fps y calcular mediana y p95 desde toque hasta nuevo contenido visible. Comparar con Widgy en las mismas condiciones.
3. Confirmar persistencia, cambio de día, lunes como inicio de semana, fecha actual roja y enlaces.
4. Comparar capturas a igual tamaño; revisar proporciones, icono, escritura, colores y botones.
5. Medir consumo en condiciones equivalentes durante 24 h, con y sin widget; ninguna afirmación de mejora cuantitativa hasta medir.
