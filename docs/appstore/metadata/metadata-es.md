# Metadatos del App Store — español (es-ES)

**Actualización del issue #160 (2026-09-26)**: reescrita para destacar la
transcripción y los resúmenes (0.8.1) y para quitar marcas de terceros
(nombres de servicios de reuniones, etc.) de la descripción y las palabras
clave. El subtítulo pasa a «Graba y transcribe reuniones». El texto anterior
está en el historial de git y en el registro previo al cambio de
[metrics.md](metrics.md).

## Nombre de la app (≤30)

```text
kilde — Grabadora de pantalla
```

## Subtítulo (≤30)

```text
Graba y transcribe reuniones
```

(28 caracteres. Mantiene «graba» + «transcribe» en el subtítulo indexable;
«audio del sistema» pasa a las palabras clave y la descripción.
Anterior: «Audio del sistema + micrófono»)

## Descripción

```text
kilde graba la pantalla y el audio juntos: una herramienta de código abierto
para macOS que captura, con un clic, el audio del sistema que la grabación
de pantalla integrada no puede registrar.

PARA REUNIONES
Graba reuniones online mezclando las voces de los demás participantes
(audio del sistema) y tu propia voz (micrófono) en un solo archivo.
Si grabas las fuentes en pistas separadas, la transcripción etiqueta a cada
hablante (tú / la otra parte). También puede detectar ventanas de reunión y
empezar a grabar automáticamente (desactivado por defecto).

TRANSCRIBE Y RESUME (MACOS 26 O POSTERIOR)
Al terminar la grabación, kilde la transcribe por completo en este Mac y
escribe la transcripción en Markdown junto al archivo. En Macs con Apple
Intelligence activado también puede redactar un resumen de la reunión.
El audio y las transcripciones nunca salen de tu dispositivo.

ENCUENTRA CUALQUIER MOMENTO
Las transcripciones se pueden buscar a texto completo en la biblioteca de
grabaciones: busca y salta directo al momento exacto en que se dijo, sin
arrastrar la barra de una grabación de una hora.

CARACTERÍSTICAS
- Pantalla + audio del sistema sin ninguna configuración (ScreenCaptureKit
  nativo)
- Graba a la vez un micrófono o interfaces de audio (mezclados o en pistas
  separadas)
- Captura por ventana: el audio se acota a esa app
- Grabación solo de audio (M4A), sin drivers adicionales
- Inicia y detén con atajos de teclado globales o la app Atajos
- Tanto si detienes la grabación como si cierras la app, el archivo siempre
  se escribe por completo

PRIVACIDAD
Tus grabaciones y transcripciones nunca salen de tu Mac. El desarrollador
solo recibe estadísticas de uso agregadas, como el número de inicios, e
informes de fallos cuando la app se cierra inesperadamente; nunca el
contenido de tus grabaciones. Consulta PRIVACY.md en
github.com/kilde-team/kilde.

REQUISITOS
macOS 14 o posterior (Apple Silicon); la transcripción y los resúmenes
requieren macOS 26 o posterior. Gratis, sin anuncios, código abierto (MIT).

La app comparte el mismo motor de grabación que la herramienta de línea de
comandos `kilde`. Más información en https://github.com/kilde-team/kilde
```

## Palabras clave (≤100)

```text
grabadora de pantalla,audio del sistema,transcribir,transcripción,reunión,micrófono,acta
```

(87 caracteres / 88 bytes — las vocales acentuadas ocupan 2 bytes. El límite
real del campo se cuenta en caracteres (ver el README de metadata); se
mantiene también por debajo de 100 bytes. Se quitó «Zoom» (marca de
terceros) y «grabar pantalla» (ya cubierto por «grabadora de pantalla») y
se añadieron «transcribir», «transcripción» y «acta»)

## Novedades (0.6.0)

El único cambio respecto a 0.5.0 es interno (informes de fallos), así que el
texto se mantiene breve y honesto — sin anunciar funciones que no existen.

```text
Mejoras de estabilidad y fiabilidad.
```

## Novedades (0.8.1)

```text
Añade transcripción de grabaciones y resúmenes (en el dispositivo), soporte de Atajos para iniciar y detener grabaciones, y una biblioteca de grabaciones con búsqueda de texto completo y reproducción desde el momento exacto. La transcripción ahora también funciona aunque cambies la carpeta de destino durante la grabación.
```

## Novedades (plantilla)

```text
Resume los cambios de esta versión en 1–3 líneas (correcciones y novedades).
```
