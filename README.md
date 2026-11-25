# ClearWidget — 0.1.0 (validación técnica)
Widget mediano para iPhone, SwiftUI + WidgetKit. Reconstrucción visual de referencia; no contiene imágenes de terceros ni capturas del fondo.

- Tres vistas excluyentes; navegación mediante AppIntent en la extensión.
- Estado local de la extensión, compartido entre instancias del mismo widget; no App Groups.
- Sin temporizadores, GPS, polling, red ni procesos persistentes en esta versión.
- Una actualización de calendario al siguiente inicio de día, además de las recargas de WidgetKit al interactuar.
- Fondo administrado por el sistema. El modo Claro de la pantalla de inicio habilita el material de cristal; el sistema puede transformar los colores.
- Los enlaces al clima y calendario se enrutan mediante la app contenedora (puede aparecer brevemente); esquemas externos sujetos a prueba en el dispositivo.
- WeatherKit requiere membresía y entitlement; las temperaturas se muestran como — hasta incorporar una fuente autorizada. El icono del clima y la tipografía manuscrita son aproximaciones provisionales.
- No hay aún personalización de las acciones desde la app.

## Compilar
Actions → Build ClearWidget IPA. El IPA es sin firmar; SideStore debe firmar app y extensión. No se garantiza compatibilidad hasta instalar y probar.
## Criterios de aceptación en iPhone
1. Instalar y agregar widget mediano. Verificar cristal nativo sobre dos fondos distintos.
2. Alternar 30 veces las tres pantallas; registrar video a 60 fps y calcular mediana y p95 desde toque hasta nuevo contenido visible. Comparar con Widgy en las mismas condiciones.
3. Confirmar persistencia, cambio de día, lunes como inicio de semana, fecha actual roja y enlaces.
4. Comparar capturas a igual tamaño; revisar proporciones, icono, escritura, colores y botones.
5. Medir consumo en condiciones equivalentes durante 24 h, con y sin widget; ninguna afirmación de mejora cuantitativa hasta medir.
