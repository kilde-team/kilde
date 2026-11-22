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
Intelligence activado también puede redactar un resumen de la reunión (Pro).
El audio y las transcripciones nunca salen de tu dispositivo.

ENCUENTRA CUALQUIER MOMENTO
Las transcripciones se pueden buscar a texto completo en la biblioteca de
grabaciones: busca y salta directo al momento exacto en que se dijo, sin
arrastrar la barra de una grabación de una hora. También puedes buscar las
grabaciones desde Spotlight, exportar las transcripciones como texto,
Markdown o subtítulos (SRT / WebVTT), e importar archivos de audio y vídeo
grabados con otras herramientas para transcribirlos.

ACTAS, PREGUNTAS Y TRADUCCIÓN (PRO, PAGO ÚNICO)
Convierte las grabaciones en actas de reunión con tareas, redacta mensajes
de seguimiento, pregunta sobre una transcripción (o en toda la biblioteca)
y traduce transcripciones: el procesamiento ocurre en este Mac con Apple
Intelligence (macOS 26 o posterior). Pro es un pago único, no una
suscripción. La grabación y la transcripción siguen siendo gratis.

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
requieren macOS 26 o posterior. Grabar y transcribir es gratis. Sin
anuncios, código abierto (MIT).

La app comparte el mismo motor de grabación que la herramienta de línea de
comandos `kilde`. Más información en https://github.com/kilde-team/kilde
```

## Palabras clave (≤100)

```text
audio del sistema,micrófono,acta,notas,conferencia,dictado,voz,clase,subtítulos,transcripción
```

(93 caracteres / 96 bytes. Issue #605 (2026-11-19): se quitaron las palabras ya
indexadas en otro campo — «grabadora de pantalla» (nombre), «transcribir» /
«reunión» (subtítulo: «Graba y transcribe reuniones») — y se usó el espacio para
«conferencia», «dictado», «voz», «clase» y «subtítulos» (formato de exportación).
Revisión de #607: «transcripción» vuelve a la lista — es la forma nominal que los
usuarios buscan y el subtítulo solo indexa el verbo «transcribe». «subtítulos» se
queda en plural como excepción (es el término de búsqueda natural en español).
El historial de #160 (0.43.0) queda en git.)

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

## Novedades (0.8.2)

```text
Actualizamos la página del producto en el App Store. No hay cambios en las funciones de la aplicación.
```

## Novedades (0.8.3)

```text
Mejoras internas de la aplicación. No hay cambios en las funciones de la aplicación.
```

## Novedades (0.8.4)

Los términos de la interfaz coinciden con Localizable.xcstrings (es):
«Abrir carpeta», «Grabaciones recientes».

```text
Añade botones «Abrir carpeta» en la pantalla de finalización de la grabación y en la lista de grabaciones recientes. Incluye también una mejora de estabilidad: al detectar una interrupción de la captura, kilde guarda la grabación hasta ese momento y te avisa.
```

## Novedades (plantilla)

```text
Resume los cambios de esta versión en 1–3 líneas (correcciones y novedades).
```

## Novedades (0.8.5)

Un cambio visible desde 0.8.4: el motor de grabación se actualiza a
kilde-cli-swift **v0.9.0**, que añade un **reinicio automático** tras las
interrupciones de captura (kilde-cli-swift#73 / issue #304). Cuando
ScreenCaptureKit detiene la transmisión por su cuenta (p. ej. tras una
reconfiguración de pantallas), la versión anterior del motor (v0.8.2) finalizaba la grabación en ese
punto; ahora el motor reanuda la grabación en el mismo archivo hasta 3 veces.
La GUI cambia la notificación a «se reanudó automáticamente» mediante
`Summary.captureRestartCount`.

```text
La grabación en pantalla ahora se reanuda automáticamente tras interrupciones como cambios de conexión o resolución de pantallas, y continúa en el mismo archivo. Si no se puede reanudar la captura, kilde guarda la grabación hasta ese punto y te avisa.
```

## Novedades (0.9.0)

Sin cambios funcionales desde 0.8.5: esta presentación alinea el número de
versión de App Store con la distribución directa v0.9.0 (issue #307 / issue #310).
El reinicio automático tras interrupciones de captura (0.8.5) y el botón
«Abrir carpeta» (0.8.4) ya llegaron a los usuarios de App Store, así que el
texto solo indica que es una versión de mantenimiento.

```text
Esta es una versión de mantenimiento. El número de versión se alinea con la distribución directa. No hay cambios en las funciones de grabación.
```

## Novedades (0.10.0)

Dos cambios visibles desde 0.9.0. Ahora se puede transcribir después de
grabar —con actas (resumen) opcionales— desde la ventana de la biblioteca,
incluso para grabaciones hechas con la transcripción desactivada (issue #321).
El motor se actualiza a kilde-cli-swift **v0.10.0** (issue #316) con
bitrates predeterminados reajustados (kilde-cli-swift#86): la grabación mp4
predeterminada baja a unos 200 MB por hora. La alternativa de «subir el
bitrate en config.json» no aplica a la compilación de App Store (sandbox),
así que no se menciona en el texto.

```text
Ya puedes crear una transcripción —o un acta con resumen— después de grabar, desde la biblioteca de grabaciones, incluso para grabaciones hechas con la transcripción desactivada (la transcripción requiere macOS 26 o posterior; los resúmenes necesitan Apple Intelligence). Las grabaciones MP4 en H.264 con la configuración predeterminada también son mucho más pequeñas (unos 200 MB por hora).
```

## Novedades (0.11.0)

Un cambio visible desde MAS 0.10.0: ahora las transcripciones se pueden
exportar como archivo de texto desde la biblioteca de grabaciones
(issue #329). La exportación siempre genera todo el texto en el mismo
formato legible «[HH:MM:SS] texto» sea cual sea el formato del archivo
lateral, y el guardado usa NSSavePanel, que funciona igual bajo el sandbox
de App Store. Sin actualización de motor (el pin sigue en kilde-cli-swift
v0.10.0) y sin requisitos nuevos.

```text
Ya puedes exportar la transcripción de una grabación como archivo de texto (.txt) desde la biblioteca de grabaciones: útil para llevar el texto de tus reuniones a tus notas u otras herramientas.
```

## Novedades (0.12.0)

Un cambio visible desde MAS 0.11.0: ahora las grabaciones se pueden pausar
y reanudar desde el panel de la barra de menús (issue #338). Mientras está
en pausa el tiempo transcurrido se congela, y los periodos en pausa quedan
excluidos tanto de la duración como del archivo guardado. El comportamiento
del motor llegó con kilde-cli-swift v0.10.0; sin actualización de motor (el
pin sigue en v0.10.0) y sin requisitos nuevos.

```text
Ahora puedes pausar y reanudar una grabación desde el panel de la barra de menús. Los periodos en pausa quedan excluidos de la duración de la grabación y del archivo guardado.
```

## Novedades (0.13.0)

El cambio principal desde MAS 0.12.0 es una **comprobación de espacio libre
en disco antes de iniciar la grabación** (la preverificación del motor
v0.13.0, adoptada al subir el pin de v0.10.0 a v0.14.0). Antes de grabar se
compara el tamaño estimado de la configuración con el espacio libre del
destino: si el espacio está justo se avisa de antemano y, si claramente no
basta, la grabación no se inicia. El motor v0.14.0 trae sobre todo mejoras
para la CLI, sin efecto en la grabación desde la GUI. También incluye
instrumentación de métricas (issue #343) sin cambios funcionales.

```text
kilde ahora comprueba el espacio libre en disco antes de iniciar una grabación. Recibirás un aviso por adelantado si el espacio está justo y la grabación no comenzará si claramente no es suficiente: así una grabación larga es mucho menos probable que llene el disco a mitad de camino.
```

## Novedades (0.14.0)

Esta versión se centra en mejoras internas: el motor de grabación se ha
actualizado como base para próximas funciones (issue #352). Sin cambios
en las operaciones de grabación de la GUI.

```text
Esta actualización renueva el motor de grabación como base para próximas funciones.
```

## Novedades (0.15.0)

El único cambio visible para el usuario desde MAS 0.14.0: el origen de
captura (pantalla / ventana / solo audio), las fuentes y dispositivos de
audio, la disposición de las pistas («Mezclar en una pista» / «Separar por
fuente») y la configuración de transcripción elegidos en el panel se
guardan al iniciar la grabación desde el panel (botón o atajo global) y se
restauran en el siguiente arranque (issue #345 / PR #359). La configuración
solo se guarda al iniciar una grabación desde el panel: las grabaciones
iniciadas desde Atajos o por detección automática de reuniones no la guardan
(ambas sustituyen el origen de captura, y la detección de reuniones también
fija las entradas de audio). «Hacer predeterminada esta selección de audio y
ubicación» también guarda el origen de captura. Sin actualización del motor
(el pin se mantiene en kilde-cli-swift v0.15.0).

```text
Al iniciar una grabación desde el panel, kilde ahora recuerda el origen de captura, las fuentes y dispositivos de audio, la disposición de las pistas y la configuración de transcripción seleccionados, para que el próximo arranque empiece con la misma configuración. «Hacer predeterminada esta selección de audio y ubicación» también guarda el origen de captura.
```

## Novedades (0.16.0)

El único cambio visible para el usuario desde MAS 0.15.0: al elegir una app
en ejecución en la ventana emergente, se graba solo el audio de esa app
(issue #364 / PR #366). La función está **disponible en macOS 15 o
posterior** (el Audio Process Tap del motor kilde-cli-swift v0.16.0 — el pin
se actualizó en el PR #366); en macOS 14.x la interfaz «Elegir audio de
apps…» no aparece. Se puede combinar con el micrófono, pero el audio de apps
y el audio del sistema no se pueden grabar a la vez (al elegir una app se
desactiva el audio del sistema). La selección se guarda por bundle ID al
comenzar una grabación desde el panel (el botón de guardado como
predeterminada hace lo mismo) y se conserva en el próximo arranque (una app
que no esté en ejecución se muestra como «(no está en ejecución)» con un
aviso al comenzar la grabación).

```text
Ya puedes elegir una app en ejecución en la ventana emergente para grabar solo el audio de esa app (requiere macOS 15 o posterior). Se puede combinar con el micrófono, pero el audio de apps y el audio del sistema no se pueden grabar a la vez. La selección se guarda al comenzar una grabación y se conserva en el próximo arranque.
```

## Novedades (0.17.0)

Sin cambios visibles para el usuario desde MAS 0.16.0. Como mejora interna,
el origen de captura (pantalla / solo audio) que se guarda al comenzar una
grabación ahora se almacena en el mismo archivo de configuración que los
demás ajustes de grabación (la clave `defaultTarget` de config.json —
issue #372 / PR #373; motor kilde-cli-swift v0.17.0, kilde-cli-swift#123).
**El momento del guardado no cambia: el inicio de una grabación** (el botón
de inicio del panel o el atajo global; las grabaciones iniciadas por Atajos o
el gravador automático de reuniones no se guardan; el botón de guardado como
predeterminada guarda lo mismo sin iniciar una grabación), y la selección de
una ventana sigue guardándose dentro de la app, porque el ID de ventana se
reasigna en cada arranque de la app (la ruta de restauración validada existente
no cambia).

```text
El origen de captura (pantalla o solo audio) elegido al comenzar una grabación desde el panel o el atajo global ahora se guarda en el mismo archivo de configuración que los demás ajustes de grabación. El momento del guardado no cambia (al comenzar la grabación) y el comportamiento de grabación tampoco.
```

## Novedades (0.18.0)

Propinas (la parte MAS del issue #171). Tres productos IAP consumibles
(kilde.tip.small / kilde.tip.medium / kilde.tip.large) se pueden comprar
desde la sección "Apoya esta app" en la parte inferior del panel. La política
del issue de «no degradar la experiencia gratuita» se refleja en la UI: la
sección se oculta por completo cuando no se puede obtener la lista de
productos, y una compra cancelada no muestra nada y una fallida muestra una sola línea de
texto; en ningún caso se muestra una alerta. Los importes siguen la propuesta del issue
(¥160 / ¥480 / ¥1,200; niveles de precio 1 / 3 / 8 en ASC). La compilación de
distribución directa (DMG) no muestra nada — la parte de «enlace a Sponsors»
del issue queda sin implementar hasta completar la solicitud de GitHub
Sponsors (configuración bancaria) y se añadirá por separado más adelante
(issue #171 se acota aquí a «que las propinas de la versión MAS pasen la
revisión»). Las novedades indican explícitamente que todas las funciones
siguen siendo gratuitas.

```text
Se añadió una sección "Apoya esta app" en la parte inferior del panel donde puedes enviar una propina en tres importes (solo en la versión distribuida por la tienda). Todas las funciones de grabación y transcripción siguen siendo gratuitas.
```

## Novedades (0.19.0)

La acción "Transcripción" en la notificación de grabación completada
(issue #392): un acceso de un toque desde el momento del éxito, que pone el
trabajo en cola con los ajustes del momento (formato / idioma; sin resumen).
Las grabaciones ya transcritas abren el archivo existente en lugar de crear
un duplicado «-2». La notificación lleva un bookmark con ámbito de
seguridad, así que tocar tras cambiar el destino y reiniciar sigue
procesando la grabación de la carpeta anterior. En Mac no compatibles
(anteriores a macOS 26) la acción no aparece.

```text
Se añadió la acción "Transcripción" a la notificación de grabación completada. Empieza a transcribir una grabación terminada directamente desde la notificación (la transcripción requiere macOS 26 o posterior y los datos de voz de tu idioma).
```
## Novedades (0.20.0)

Nombres de reunión desde el calendario (issue #393): un ajuste opcional de la
grabación automática de reuniones consulta el calendario antes de comenzar y
nombra la grabación `kilde-<fecha>-<título del evento>`. El título también se
usa en la notificación de inicio y en el encabezado de la minuta. El permiso se
solicita al activar el ajuste, y de nuevo al abrir el panel con el ajuste
activo y el permiso sin responder (`requestFullAccessToEvents`, macOS 14+ —
macOS no ofrece un permiso de solo lectura, por lo que se solicita acceso
completo, pero la aplicación solo lee eventos). Permiso denegado, sin evento
superpuesto o búsqueda sin terminar: se usa el nombre de archivo
predeterminado.

```text
Las reuniones detectadas por la grabación automática ahora pueden llevar el nombre de tus eventos del calendario. Activa «Usar los nombres de los eventos del calendario para los nombres de archivo» y el título del evento superpuesto se usará para el nombre del archivo, la notificación de inicio y el encabezado de la minuta. El calendario se lee solo para esta función en este dispositivo y su contenido nunca se envía por la red (desactivado de forma predeterminada).
```
## Novedades (0.21.0)

Detección automática del idioma de transcripción (issue #409, motor
kilde-cli-swift#131; diseño en cli-swift SPIKE-NOTES F-Q). Añade
«Automático (detectar de la grabación)» al ajuste de idioma de transcripción
(el valor predeterminado sigue siendo «Idioma del dispositivo»). Al
activarlo, los primeros 30 segundos de **cada pista de audio** se transcriben
con los idiomas candidatos (idioma del dispositivo, japonés, inglés) y gana
el de mayor confianza media ponderada. En grabaciones con pistas separadas,
la pista del otro participante y la del propio micrófono se deciden por
separado. Las pistas sin decisión vuelven al idioma del dispositivo. Sin permisos
nuevos; grabaciones y transcripciones no salen del dispositivo (los modelos
de idioma que falten se descargan de Apple, igual que con idiomas fijos).

```text
El ajuste de idioma de transcripción incorpora "Automático (detectar de la grabación)". Detecta el idioma de la reunión desde los primeros 30 segundos de la grabación (candidatos: idioma del dispositivo, japonés e inglés) y transcribe en él; con pistas de audio separadas, la pista del otro participante y la de tu micrófono se transcriben cada una en su idioma. Si no se puede decidir, se usa el idioma del dispositivo como antes. La transcripción requiere activar "Transcribir tras la grabación" y macOS 26 o posterior con los datos de voz (modelo de idioma) del idioma (el valor predeterminado no cambia; las grabaciones y transcripciones nunca se envían por la red, aunque los modelos de idioma que falten se descargan de Apple — como en cualquier petición de red, la descarga llega a Apple con tu dirección IP).
```


## Novedades (0.22.0)
Importación de archivos existentes (issue #416). La ventana de biblioteca
añade un selector «Importar archivos…» (selección múltiple) y arrastrar y
soltar, para poder transcribir archivos de audio/vídeo grabados antes de
kilde o con otras herramientas (el equivalente en GUI de `kilde transcribe`;
**la transcripción sigue siendo gratuita**). Los archivos se **copian a la
carpeta de destino** — bajo el sandbox de la App Store la app no puede
escribir un sidecar junto a un archivo cualquiera elegido por el usuario —
como `kilde-<fecha>-<nombre original>` y pasan a la cola de transcripción
existente (idioma y formato según los ajustes del momento, igual que
«Crear transcripción»; sin resumen). Un archivo con el mismo nombre y tamaño
ya presente cuenta como importado, así que reimportar no duplica. Sin
permisos nuevos; grabar y transcribir siguen siendo gratuitos (sin compras
salvo las propinas de 0.18.0).

```text
La biblioteca ahora puede importar archivos de audio/vídeo existentes (MOV, MP4, M4V, M4A, MP3, WAV, AIF/AIFF, CAF, AAC). Elige un archivo o suéltalo en la ventana de la biblioteca: las grabaciones hechas antes de kilde o con otras herramientas se copian en la carpeta de destino y se transcriben en el dispositivo (el archivo original no se modifica; un archivo cuyo nombre y tamaño coinciden con una importación existente no se vuelve a copiar). Las grabaciones importadas se vuelven buscables en la biblioteca. Importar y transcribir requieren macOS 26 o posterior y los datos de voz del idioma correspondiente. También se corrigió: el panel de la barra de menús podía conservar la altura compacta de grabación tras terminar la grabación.
```

## Novedades (0.23.0)

Versión de mantenimiento sin cambios funcionales (issue #426). Su propósito es
registrar los vídeos de vista previa del App Store (ja / en, generados en
kilde#399 y verificados a 1920×1080 / H.264 / 29,9 s): los recursos de una
versión quedan bloqueados mientras está en revisión o publicada, así que crear
la 0.23.0 (PREPARE_FOR_SUBMISSION) es la primera oportunidad para adjuntarlos
(ver el comentario del 2026-10-24 en el issue #160). Todo lo fusionado desde
v0.22.0 es refuerzo del selftest (issue #424), sin cambios visibles para el
usuario. Siguiendo el precedente de 0.9.0, el texto de Novedades dice
llanamente que es una versión de mantenimiento.

```text
Esta versión es de mantenimiento: no hay cambios en la grabación ni en la transcripción. Se publica junto con el nuevo vídeo de vista previa de la aplicación en la página del App Store.
```

## Novedades (0.24.0)

Exclusión voluntaria de estadísticas de uso e informes de fallos (issue #435).
Nueva sección «Privacidad» en los ajustes del panel; al desmarcar «Enviar
estadísticas de uso de la app e informes de fallos» Analytics se detiene de inmediato
y Crashlytics desde el siguiente inicio (comportamiento del SDK); lo registrado
mientras está desactivado se borra al reactivarlo. Si la app
se abre con el ajuste desactivado, no llama a `FirebaseApp.configure()`.
**Activado por defecto** (lo que se recoge no cambia; lo que cambia es que se
puede detener). Sin cambios en el motor (pin v0.19.0). Los elementos medidos
(descripción / palabras clave / subtítulo / capturas) no cambian.

```text
Nuevo ajuste «Privacidad». Desmarca «Enviar estadísticas de uso de la app e informes de fallos»: las estadísticas de uso (Firebase Analytics) se detienen de inmediato y los informes de fallos (Firebase Crashlytics) dejan de recopilarse a partir del siguiente inicio. Si la app se abre con el ajuste desactivado, no inicializa el SDK de analítica, y lo que se registró mientras estuvo desactivado se borra en lugar de enviarse al reactivarlo. Está activado por defecto y no se recoge nada nuevo: tus grabaciones, transcripciones y nombres de archivo nunca se envían, sea cual sea el ajuste.
```

## Novedades (0.25.0)

Enlace a GitHub Sponsors en la sección «Apoya esta app» de la versión de
descarga directa (la parte restante del issue #171). Con el alta completada,
se añade la vía aplazada desde 0.18.0: un botón que abre la página de
Sponsors en el navegador predeterminado — la aplicación no realiza ninguna
llamada de red nueva por esta acción (el tráfico existente, como la
comprobación de actualizaciones y las estadísticas de uso, no cambia). El
repositorio también recibe un FUNDING.yml para el botón Sponsor (mismo
destino). Sin cambios funcionales en la versión de la Mac App Store —
imagen especular de 0.18.0. **El texto de Novedades (visible en la tienda)
no menciona Sponsors**: mencionar una vía de pago externa rozaría las normas
de la App Store (3.1.1) y la propia regla del issue, así que el texto sigue
el precedente de versión de mantenimiento de 0.23.0. La grabación y la
transcripción siguen siendo gratuitas. Sin cambios en el motor (pin v0.19.0).

```text
Esta versión es de mantenimiento: la versión de la Mac App Store no tiene cambios funcionales. Todas las funciones siguen siendo gratuitas, como siempre.
```

## Novedades (0.26.0)

```text
Los resúmenes de reuniones pasan a ser una compra única de Pro (sin suscripción). Al activar el resumen en los ajustes, tras cada grabación se recopilan automáticamente los puntos clave, las decisiones y las tareas pendientes, con procesamiento en el dispositivo mediante Apple Intelligence (macOS 26 o posterior). La grabación y la transcripción son gratuitas actualmente.
```

## Novedades (0.27.0)

```text
Mejoras internas de la aplicación. No hay cambios en las funciones.
```

## Novedades (0.28.0)

```text
Los borradores de seguimiento se han añadido a Pro. Genera un borrador de correo o de mensaje de chat para los participantes a partir del resumen de cada reunión (procesado en el dispositivo con Apple Intelligence en macOS 26 o posterior). Ya están incluidos si ya tienes Pro; no se requiere ninguna compra adicional. La grabación y la transcripción son gratuitas actualmente.
```

## Novedades (0.29.0)

```text
Las instrucciones personalizadas se han añadido a Pro. Especifica el tono, los destinatarios, una firma y más para dar forma a los resúmenes y a los borradores de seguimiento con tu propio estilo (procesado en el dispositivo con Apple Intelligence en macOS 26 o posterior). Ya están incluidas si ya tienes Pro; no se requiere ninguna compra adicional. La grabación y la transcripción son gratuitas actualmente.
```

## Novedades (0.30.0)

Reorganización del panel y nueva ventana de Ajustes (issue #478). El texto solo dice lo que
existe (misma política que 0.28.0): no hay funciones nuevas ni eliminadas — es un cambio de
distribución, y así se indica.

```text
El panel de grabación se ha reorganizado. El objetivo de captura, el audio, el interruptor de transcripción y el destino siguen en el panel. Los ajustes que se cambian rara vez (atajo de teclado, inicio automático al iniciar sesión, grabación automática de reuniones, privacidad y más) y los detalles de la transcripción (idioma, formato y más) se agrupan ahora en una nueva ventana de Ajustes, que se abre con el icono de engranaje de la cabecera del panel. La grabación, la transcripción y los resúmenes no cambian.
```


## Novedades (0.31.0)

Reducción de fallos de transcripción: la lista de idiomas sigue las locales que admite
SpeechTranscriber (issue #486). El texto solo dice lo que existe (misma política que 0.28.0),
con la condición de macOS 26 y el aviso de «no se transcribe cuando no se puede determinar».

```text
Elegir el idioma de la transcripción es más fácil (la transcripción requiere macOS 26 o posterior). La lista de idiomas de Ajustes muestra ahora todos los idiomas que la transcripción en este Mac admite (primero japonés e inglés, y los idiomas que aún hay que descargar se indican). Si el idioma de tu Mac no está admitido, los ajustes lo indican y la transcripción detecta el idioma a partir de la grabación. Cuando no puede determinar el idioma, no se transcribe y se te pide elegir un idioma admitido en Ajustes. Las funciones de grabación no cambian.
```

## Novedades (0.32.0)

Sacar transcripciones de la biblioteca: formatos de subtítulos (SRT / WebVTT) en el menú
de exportación y acciones de copiado (issue #493). El texto solo dice lo que existe
(misma política que 0.28.0), con el aviso de que los tiempos de fin son aproximados en
las transcripciones guardadas como texto/Markdown (esos formatos no guardan tiempos de fin).
El botón de copia se describe sin citar su etiqueta («Copiar todo»): asc-submit detecta la
palabra suelta «todo» como marcador de placeholder de una copia sin terminar
(`\btodo\b` sin distinción de mayúsculas — español corriente da falso positivo).

```text
Sacar transcripciones de la biblioteca de grabaciones es más fácil. El menú de exportación ofrece ahora archivos de subtítulos SubRip (.srt) y WebVTT (.vtt) además de texto sin formato (.txt), útil cuando una plataforma de vídeo necesita subtítulos (las transcripciones guardadas como texto/Markdown no guardan tiempos de fin, así que sus tiempos de fin en los subtítulos son aproximados). El nuevo botón de copia del encabezado lleva la transcripción completa, con el formato «[hora] texto», al portapapeles, y al hacer clic derecho en una línea se copia solo el texto de esa línea. Las funciones de grabación y transcripción no cambian.
```

## Novedades (0.33.0)

Soporte de Spotlight para la biblioteca de grabaciones: las grabaciones y transcripciones
se registran en el índice de Spotlight y un resultado abre la biblioteca con esa grabación
(issue #502). Se describe solo lo que existe en la implementación (misma política que 0.28.0).
«Lo que kilde registra en el índice se guarda solo en este Mac; kilde no lo envía a
ningún sitio» sigue la PRIVACY.md corregida («Spotlight index», acotado a lo que kilde
registra y envía — no el comportamiento propio de Spotlight). El nombre de la sección es el
texto localizado de la app («Biblioteca de grabaciones»).

«Los primeros 100.000 caracteres» es el límite de textContent (textContentLimit en SpotlightExporter.swift); la búsqueda completa dentro de la app cubre todo el texto.

```text
Ahora puedes buscar grabaciones desde Spotlight: por nombre, fecha y duración, y también por las palabras de la transcripción (se indexan los primeros 100.000 caracteres de cada transcripción). Al elegir un resultado de Spotlight se abre la biblioteca de grabaciones con esa grabación seleccionada (para grabaciones de la ubicación de guardado actual). Lo que kilde registra en el índice se guarda solo en este Mac; kilde no lo envía a ningún sitio. Se puede desactivar en Ajustes > Biblioteca de grabaciones. Las funciones de grabación y transcripción no cambian.
```

## Novedades (0.34.0)

Exportar los elementos de acción del resumen de un acta a Recordatorios (issue #509). Se
describe solo lo que existe en la implementación (misma política que 0.28.0). «Lo que se
añade se prepara en este Mac; kilde no lo envía a ningún sitio» sigue la PRIVACY.md
corregida («Reminders», acotado al tráfico propio de kilde — si la lista predeterminada es
de iCloud, la sincronización con otros dispositivos es de macOS, no de kilde). «Añadir a
Recordatorios» es el texto localizado del botón.

```text
Ya puedes añadir los elementos de acción del resumen de un acta a Recordatorios. Selecciona una grabación con acta (.md) que incluya un resumen en la biblioteca y pulsa «Añadir a Recordatorios»: los elementos se añaden a tu lista de Recordatorios predeterminada, con la grabación de origen anotada en las notas de cada elemento. El primer uso pide acceso a Recordatorios. kilde solo añade elementos — nunca lee ni modifica los existentes. Lo que se añade se prepara en este Mac; kilde no lo envía a ningún sitio. Las funciones de grabación, audio y transcripción no cambian.
```

## Novedades (0.35.0)

Evitar la suspensión automática de la pantalla mientras se graba (issue #516). Se
describe solo lo que existe en la implementación (misma política que 0.34.0). «Cerrar la
tapa del portátil sigue suspendiendo el Mac» es el límite honesto de IOPMAssertion (solo
se evita la suspensión por inactividad).

```text
Mientras grabas con vídeo, la pantalla del Mac ya no se suspende automáticamente. Si te alejas durante la grabación de una reunión, la pantalla sigue encendida, así que es mucho menos probable que la grabación pierda fotogramas o termine antes por una pantalla apagada. Al detener la grabación, el Mac vuelve normalmente a su comportamiento de suspensión (en raras ocasiones, si la llamada al sistema falla, la suspensión se reanuda en la siguiente grabación). Las grabaciones de solo audio funcionan igual que antes. Cerrar la tapa del portátil sigue suspendiendo el Mac. Las funciones de grabación, audio y transcripción no cambian.
```

## Novedades (0.36.0)

Mover grabaciones a la papelera desde la biblioteca (issue #523). El texto solo describe lo
que existe (misma política que 0.35.0). La frase sobre los archivos del mismo nombre y la de
«las transcripciones de otra grabación se quedan» describen la implementación con exactitud.

```text
Ya se pueden mover grabaciones a la papelera desde la biblioteca de grabaciones, para ordenar grabaciones antiguas de reuniones sin abrir Finder. Al mover una grabación también se mueven los archivos de transcripción y actas que comparten su nombre. Las transcripciones que pertenecen a otra grabación se quedan donde están. Las grabaciones en la papelera se pueden restaurar desde la papelera en Finder. No se pueden mover grabaciones que se estén transcribiendo o grabando.
```

## Novedades (0.37.0)

Renombrar grabaciones desde la biblioteca (issue #532). El texto solo describe lo que
existe (misma política que 0.36.0). Las frases sobre los archivos del mismo nombre, las de
otras grabaciones y la de conflicto (no se cambia nada y la app avisa) describen la
implementación con exactitud. La frase del prefijo «kilde-» es la declaración honesta del
contrato de listado de la biblioteca.

```text
Ya se puede cambiar el nombre de las grabaciones desde la biblioteca de grabaciones, para convertir los nombres automáticos («kilde-» con fecha y hora) en nombres que digan de qué trató cada reunión (se conserva el prefijo «kilde-»). El cambio se aplica al archivo de grabación y a los archivos de transcripción y actas que comparten su nombre; las extensiones no cambian. Los archivos de otras grabaciones no se tocan. Si ya existe un archivo con el mismo nombre, no se cambia nada y la aplicación avisa. No se puede cambiar el nombre de grabaciones que se estén transcribiendo o grabando.
```

## Novedades (0.38.0)

Cuarta función Pro: preguntas y respuestas sobre la transcripción (issue #540, motor
kilde-cli-swift#141). El texto solo dice lo que existe (misma política que 0.29.0).
El botón «Preguntar» (añadido a la barra de detalles de grabaciones con
transcripción) y las líneas de la transcripción en las que se basa la respuesta (que
devuelve la ruta de extracción) describen la implementación con exactitud. «Sin
compra adicional» sigue el contrato del producto único kilde.pro, y «La grabación y
la transcripción siguen siendo gratuitas» indica con honestidad el reparto
gratuito/Pro.

```text
Pro ahora incluye «Preguntas y respuestas». Selecciona una grabación con transcripción en la biblioteca y pregunta desde «Preguntar», y la aplicación busca la respuesta en la transcripción de esa grabación (puedes preguntar cosas como «¿Qué se decidió en esta reunión?» y, en transcripciones largas, también muestra las líneas de la transcripción en las que se basa la respuesta. Procesamiento en el dispositivo con Apple Intelligence; macOS 26 o posterior. No está disponible si Apple Intelligence no está activado). Si ya compraste Pro, funciona sin compra adicional. La grabación y la transcripción son gratuitas actualmente.
```

## Novedades (0.39.0)

La quinta función Pro: preguntas y búsqueda en toda la biblioteca (issue #547, motor kilde-cli-swift#145).
El texto solo describe lo que está implementado (misma política que 0.38.0). El botón «Preguntar a la
biblioteca» (añadido a la barra de búsqueda de la ventana de la biblioteca — activo solo cuando hay una
grabación transcrita), las fuentes de la respuesta (qué reunión y qué líneas — los extractos «reunión:
línea» que devuelve el motor) y «las grabaciones que contienen tus términos de búsqueda se priorizan»
(el campo de búsqueda se pasa como términos de selección) son descripciones exactas de la implementación.
«Sin compra adicional» sigue el contrato de un solo producto kilde.pro, y «La grabación y la transcripción
son actualmente gratuitas» indica honestamente la línea entre lo gratuito y Pro.

```text
Pro ahora incluye «Preguntar a la biblioteca». Desde «Preguntar a la biblioteca» en la biblioteca de grabaciones, la app busca la respuesta a través de varias grabaciones transcritas y también muestra las fuentes de la respuesta (en qué reunión y en qué líneas se basa). Puedes preguntar cosas como «¿Qué se decidió en estas reuniones?» y, si escribes palabras en el campo de búsqueda, se priorizan las grabaciones que las contienen. Procesamiento en el dispositivo con Apple Intelligence; macOS 26 o posterior. No disponible si Apple Intelligence no está activado. Si ya compraste Pro, funciona sin compra adicional. La grabación y la transcripción son actualmente gratuitas.
```

## Novedades (0.40.0)

La sexta función Pro: preguntas de seguimiento en las hojas de preguntas y respuestas (issue #556, motor kilde-cli-swift#147).
El texto solo describe lo que está implementado (misma política que 0.38.0 / 0.39.0). Hacer preguntas de
seguimiento con las preguntas y respuestas anteriores como contexto (el `history` del motor — `QATurn`),
el historial que se queda en la hoja y desaparece al cerrarla (la conversación no se guarda), y «Copiar»
dirigido a la última respuesta y sus fuentes (la etiqueta «Preguntar de nuevo» se retiró en favor de
preguntas continuas) son descripciones exactas de la implementación. «Sin compra adicional» sigue el
contrato de un solo producto kilde.pro, y «La grabación y la transcripción son actualmente gratuitas»
indica honestamente la línea entre lo gratuito y Pro.

```text
Pro ahora incluye preguntas de seguimiento en las hojas de preguntas y respuestas. Después de una respuesta, puedes hacer una pregunta de seguimiento como «¿Cuál era ese importe?» — las preguntas y respuestas anteriores se pasan como contexto. Se quedan en la hoja como historial y desaparecen al cerrarla. «Copiar» copia la última respuesta y sus fuentes. Procesamiento en el dispositivo con Apple Intelligence; macOS 26 o posterior. No disponible si Apple Intelligence no está activado. Si ya compraste Pro, funciona sin compra adicional. La grabación y la transcripción son actualmente gratuitas.
```

## Novedades (0.41.0)

La séptima función Pro: traducción de transcripciones (issue #564, motor kilde-cli-swift#149).
El texto solo describe lo que está implementado (misma política que 0.38.0-0.40.0). Traducir la
transcripción de una reunión al idioma elegido desde el botón «Traducir» de una grabación (la barra
de acciones de la transcripción — cableado del issue #564), las marcas de tiempo que se mantienen
para leer cada línea junto al original (la instrucción del motor — kilde-cli-swift#149), y el último
idioma usado que queda como predeterminado (TranscriptTranslateSupport.lastLanguage — memoria en
UserDefaults) son descripciones exactas de la implementación. «Sin compra adicional» sigue el
contrato de un solo producto kilde.pro, y «La grabación y la transcripción son actualmente gratuitas»
indica honestamente la línea entre lo gratuito y Pro.

```text
Pro ahora incluye la traducción de transcripciones. Desde «Traducir» en una grabación, puedes traducir la transcripción de una reunión grabada al idioma que elijas (japonés / inglés / chino simplificado / coreano / español). Las marcas de tiempo se mantienen, así que cada línea traducida se puede corresponder con el original. Copia la traducción completa, y el último idioma usado queda como predeterminado la próxima vez. Procesado en el dispositivo con Apple Intelligence; macOS 26 o posterior. No disponible si Apple Intelligence no está activado. Si ya compraste Pro, funciona sin compra adicional. La grabación y la transcripción son actualmente gratuitas.
```

## Novedades (0.42.0)

Lanzamiento de correcciones y mejoras (issues #566, #571-#575). El texto dice solo lo que se publica (misma política que 0.38.0-0.41.0). «La transcripción se guarda aunque falle la generación del resumen» (issue #575 — motor kilde-cli-swift#151 / PR #152 con el cableado de kilde#577; antes, un resumen fallido también dejaba la transcripción sin archivo; «cancelar el proceso de transcripción no escribe el archivo de transcripción — la grabación se conserva» respeta el contrato de la sección 4 del DESIGN.md del motor), «los nombres de los hablantes aparecen en el resultado» (issue #566 — las rutas Preguntar, Traducir y Preguntar a la biblioteca; las etiquetas de hablante aparecen en las grabaciones hechas con el micrófono y el audio del sistema en pistas separadas, las demás grabaciones no cambian), y las cuatro correcciones de la biblioteca (issues #571/#572/#573/#574 — PRs #582/#583/#584/#586) son descripciones exactas. «La grabación y la transcripción son actualmente gratuitas» es la misma expresión establecida que en 0.41.0. No hay función Pro nueva, así que no se toca el texto de Pro.

```text
Esta versión mejora la grabación y la biblioteca. Cuando falla la generación del resumen, ahora se guarda la transcripción (antes, un resumen fallido también dejaba la transcripción sin archivo. Al cancelar el proceso de transcripción, el archivo de transcripción sigue sin escribirse — la grabación se conserva). «Preguntar», «Traducir» y «Preguntar a la biblioteca» ahora muestran los nombres de los hablantes en el resultado, así que las preguntas sobre quién dijo qué —y las traducciones que se corresponden línea a línea con el original— se entienden mejor (los nombres de hablante aparecen en las transcripciones de grabaciones hechas con el micrófono y el audio del sistema en pistas separadas). También se corrigió la biblioteca: el texto al usarla en idiomas distintos del japonés (campo de búsqueda, contador, estado vacío), los espacios que no se podían escribir en el campo «Preguntar», y el deslizador de volumen que tapaba los botones «Renombrar» y «Mover a la papelera». La grabación y la transcripción son actualmente gratuitas.
```

## Novedades (0.43.0)

Versión de mantenimiento solo de metadatos (issue #594 — cambio 5 de #160,
optimización de la página de producto del App Store). Sin cambios de código
respecto a 0.42.0; la descripción de la página de producto refleja ahora el
conjunto actual de funciones. Las Novedades siguen el precedente de
0.8.2 / 0.23.0: indicar con franqueza que la app no cambia.

```text
Esta es una versión de mantenimiento. No hay cambios en las funciones de grabación ni de transcripción. La descripción de la página de producto se ha actualizado.
```

## Novedades (0.44.0)

Versión de mantenimiento solo de metadatos (issue #605 — issue #607, optimización
de las palabras clave de búsqueda del App Store). Sin cambios de código respecto
a 0.43.0; las palabras clave de búsqueda de la página de producto se reajustaron
según una investigación ASO (se eliminaron palabras ya indexadas por el nombre o
el subtítulo y se añadieron términos de grabación, salida de texto y casos de
uso). Las Novedades siguen el precedente de 0.43.0 / 0.8.2: indicar con franqueza
que la app no cambia.

```text
Esta es una versión de mantenimiento. No hay cambios en las funciones de grabación ni de transcripción. Las palabras clave de búsqueda de la página de producto se han actualizado.
```

## Novedades (0.45.0)

Refuerzo del flujo de valoraciones y reseñas (issue #612 — una medida sobre el hallazgo principal 3 de la investigación issue #597, «cero reseñas en el MAS dejan sin prueba social»). El texto dice solo lo que se publica (misma política que versiones anteriores). «Pide una reseña justo después de que la transcripción termina correctamente» es el nuevo gancho sobre la finalización correcta de la transcripción (transcription.onCompletion → noteTranscriptionCompleted) — antes solo se valoraba justo al terminar la grabación, así que se aplazaba a una grabación posterior mientras la transcripción seguía en marcha; las grabaciones sin transcripción se valoran justo al terminar la grabación, como antes. «No se vuelve a mostrar durante al menos 90 días» es ReviewPromptPolicy.minimumDaysBetweenRequests; «los límites de frecuencia del sistema» es el tope de visualización de StoreKit (AppStore.requestReview). «Valorar en el App Store» es la entrada permanente en Ajustes → «Apoya esta app» (SettingsPaneView.reviewSection, la URL write-review de macappstore:// que se abre con un toque del propio usuario). Solo en la compilación MAS. «La grabación y la transcripción son actualmente gratuitas» es la expresión establecida de la línea gratuita/Pro.

```text
Dejar una reseña es ahora más fácil. Cuando la transcripción de una grabación termina correctamente, kilde pide una reseña en el App Store si el momento es adecuado. En las grabaciones hechas sin transcripción, se valora justo al terminar la grabación; con el resumen (acta) activado, justo después de generarlo. Antes solo se valoraba justo al terminar la grabación, así que se aplazaba a una grabación posterior mientras la transcripción seguía en marcha). Las solicitudes no se vuelven a mostrar durante al menos 90 días y respetan los límites de frecuencia del sistema. En Ajustes → «Apoya esta app» se ha añadido «Valorar en el App Store», que abre la página de reseñas en cualquier momento. La grabación y la transcripción son actualmente gratuitas.
```

## Novedades (0.46.0)

Flujo de envío al MAS idempotente y más fiable (issue #615). **Las funciones y
el código de la app no cambian respecto a 0.45.0** — esta versión solo toca la
infraestructura de publicación (idempotencia del workflow, vigilancia de
estancamiento, verificar el estado real de ASC). Las Novedades siguen el
precedente de 0.43.0 / 0.44.0: indicar con franqueza que la app no cambia.

```text
Esta es una versión de mantenimiento. No hay cambios en las funciones de grabación ni de transcripción.
```

## Novedades (0.47.0)

Corrección de visualización en el motor (kilde-cli-swift#154 — el arreglo
equivalente del lado de la GUI se hizo en kilde#585).
`TranscriptionRun.summaryFailureReason(of:)` ahora divide por `isNewline`.
El `split(separator: "\n")` anterior no podía dividir descripciones de error
con CRLF (`\r\n`, p. ej. de origen Windows), y la descripción completa podía
llegar con sus saltos de línea a la note de la GUI y a la línea ⚠ del CLI.
La note de la GUI y la línea ⚠ quedan en una sola línea. La grabación, la
transcripción y la generación del resumen no cambian — el texto solo afirma
lo que está implementado y no usa el término interno CRLF en el texto para
usuarios.

```text
El motivo que se muestra cuando falla la generación del resumen ahora se ajusta a una sola línea con más fiabilidad. Según el estilo de salto de línea de la descripción del error, la descripción completa podía aparecer en varias líneas. La grabación, la transcripción y la generación del resumen no cambian.
```

## Novedades (0.48.0)

Versión de mantenimiento (kilde#623). **Las funciones y el código de la app
no cambian respecto a 0.47.0** — el motor (kilde-cli-swift v0.27.2) solo
reescribe la explicación del mecanismo en dos comentarios de código para
que coincida con el comportamiento real del split (kilde-cli-swift#156 —
el comportamiento y las pruebas no cambian), y la grabación, la transcripción
y el resumen no cambian. Las Novedades siguen el precedente de 0.46.0:
indicar con franqueza que la app no cambia.

```text
Esta es una versión de mantenimiento. No hay cambios en las funciones de grabación ni de transcripción.
```

## Novedades (0.49.0)

Mejora de fiabilidad (kilde#629 — adopción del TranscriptStash del motor,
kilde-cli-swift#153, en la ruta de resumen de la GUI). La generación del
resumen (map-reduce del LLM en el dispositivo) es el tramo más largo entre
«transcripción terminada» y «escritura del sidecar»; si la app moría en ese
tramo, la transcripción completada no quedaba en ningún sitio. La ruta de
resumen de la GUI (TranscriptionCoordinator) no pasa por el TranscriptionRun
del motor, así que tenía la misma ventana — esta versión adopta el
TranscriptStash del motor para cerrarla. La transcripción completada se
escribe en un archivo oculto de reserva antes de iniciar el resumen, y el
archivo que deje un cierre inesperado se recupera la próxima vez que se
genere el resumen de la misma grabación. El contrato «al cancelar no se
escribe el archivo final» no cambia (una cancelación no deja ni reserva ni
final). La grabación, la transcripción y la generación de resúmenes no
cambian. Escribir solo lo que hace la implementación (estilo de la casa).
No mencionar en el texto de la tienda los términos internos (reserva,
sidecar).

```text
Si la app se cierra mientras se genera el resumen, la transcripción completada ya no se pierde. Se recupera automáticamente la próxima vez que generes el resumen de la misma grabación. La grabación, la transcripción y la generación de resúmenes no cambian.
```
