[English](README.md) | [日本語](README.ja.md) | [简体中文](README.zh-CN.md) | [한국어](README.ko.md) | [Español](README.es.md)

# kilde

[![Release](https://github.com/kilde-team/kilde/actions/workflows/release.yml/badge.svg)](https://github.com/kilde-team/kilde/actions/workflows/release.yml)

Una herramienta de grabación de pantalla y audio de código abierto para macOS.

kilde graba tu pantalla junto con **el audio del sistema que la grabadora de
pantalla de QuickTime Player no puede capturar** — como CLI de un solo comando
y como app de la barra de menús.

El proyecto está dividido en dos repositorios (issue #115):

| Repositorio | Contenido | Visibilidad |
|---|---|---|
| [kilde-team/kilde](https://github.com/kilde-team/kilde) (este repositorio) | App de barra de menús (`gui/`), firma y distribución de versiones, fórmula de Homebrew, documentación | Público |
| [kilde-team/kilde-cli-swift](https://github.com/kilde-team/kilde-cli-swift) | El motor de grabación (`KildeCore`) y el código del CLI `kilde` | Privado (miembros de kilde-team) |

## Características

- 🖥️ Graba la pantalla y el audio del sistema sin ninguna configuración usando
  la captura nativa de ScreenCaptureKit
- 🎤 Graba a la vez un micrófono u otro dispositivo de entrada como BlackHole
  - Mezcla varias fuentes en **una sola pista** de forma predeterminada, o
    conserva pistas separadas con `--audio-tracks separate`
- 🪟 **Captura una sola ventana** y acota el audio del sistema a su app,
  excluyendo sonidos de notificación y de otras apps
- 🎙️ Graba solo audio con `--no-video`, sin necesidad de controladores
  adicionales
- 🛡️ Finaliza de forma segura el archivo de salida aunque detengas la grabación
  con Ctrl+C
- ⌨️ Inicia y detiene la grabación con un atajo de teclado global mientras usas
  otra app
- 📝 Transcribe grabaciones a archivos sidecar en markdown/SRT/VTT/texto/JSON,
  íntegramente en el dispositivo (macOS 26+)

## Instalación

- macOS 14 o posterior
- La transcripción requiere **macOS 26 o posterior**
- Los binarios publicados son **compilaciones arm64 (Apple Silicon)** — los Mac
  Intel no son compatibles por ahora
- Las pruebas en tiempo de ejecución se realizan actualmente en macOS 26 sobre
  Apple Silicon
- Para compilar se necesita un toolchain con el SDK de macOS 26 (el motor usa
  la API de macOS 26 `captureHDRRecordingPreservedSDRHDR10`; en tiempo de
  ejecución sigue admitiéndose macOS 14+)

### Mac App Store

La app de barra de menús está en el Mac App Store — se instala con un clic y
el App Store la mantiene actualizada automáticamente:

<a href="https://apps.apple.com/app/id6812783176">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/appstore/badge/mac-app-store-badge-en-white.svg">
    <img src="docs/appstore/badge/mac-app-store-badge-en-black.svg" alt="Descargar en el Mac App Store" height="40">
  </picture>
</a>

### Homebrew

```sh
brew tap kilde-team/kilde
brew trust --formula kilde-team/kilde/kilde   # solo una vez, solo en Homebrew recientes
brew install kilde

# O instala directamente desde el tap
brew install kilde-team/kilde/kilde
```

### Binarios publicados

Descarga `kilde-<versión>-macos.zip` de
[GitHub Releases](https://github.com/kilde-team/kilde/releases), descomprímelo
y pon el binario `kilde` en tu `PATH`:

```sh
unzip kilde-*-macos.zip && sudo cp release/kilde /usr/local/bin/
```

### Compilar desde el código fuente

El CLI `kilde` y el motor `KildeCore` se desarrollan en
[kilde-team/kilde-cli-swift](https://github.com/kilde-team/kilde-cli-swift),
que es **privado**, así que de momento no hay compilaciones públicas desde el
código — usa Homebrew o los binarios publicados. Los miembros de kilde-team
pueden clonar ese repositorio y compilarlo ahí con `swift build` (ver su
documentación).

## Primeros pasos

Empieza con `doctor`. La grabación de pantalla y la captura de micrófono
requieren permisos de macOS, y este comando comprueba el entorno y solicita
los permisos que falten:

```sh
kilde doctor
```

Después graba tu pantalla y el audio del sistema. Pulsa Ctrl+C para detener y
finalizar el archivo de forma segura:

```sh
kilde rec demo.mov
```

Usa los demás comandos para descubrir objetivos de captura, inspeccionar una
grabación y gestionar los valores predeterminados persistentes:

```sh
kilde devices         # Lista pantallas, ventanas y dispositivos de audio
kilde inspect FILE    # Muestra las pistas y los niveles de audio de una grabación
kilde transcribe FILE # Transcribe una grabación a un archivo sidecar (macOS 26+)
kilde config show     # Muestra los valores configurados y los predeterminados vigentes
```

## Ejemplos de grabación

Graba toda la pantalla (predeterminado) o una parte. `--region` acepta
`x,y,w,h` en puntos con el origen arriba a la izquierda. El ancho y el alto se
redondean hacia abajo a valores pares por H.264; una región fuera de la pantalla falla
antes de empezar a grabar (código 1), y los valores mal formados o menores de
2 puntos son errores de argumentos (código 64). No se puede combinar con
`--window`, `--no-video` ni `--preset meeting`:

```sh
# Toda la pantalla + audio del sistema (predeterminado)
kilde rec demo.mov

# Una parte de la pantalla
kilde rec --region 0,0,1280,720 demo.mov
```

Graba una reunión de Zoom, Google Meet o Teams. El preajuste de reunión te
pide elegir una ventana y luego mezcla el audio del sistema de los demás
participantes y tu micrófono en una sola pista:

```sh
kilde rec --preset meeting meeting.mov
```

También puedes añadir un micrófono explícitamente, grabar solo audio como M4A
o acotar la captura a la ventana de una app concreta. `--window` acepta una
coincidencia parcial de título, de bundle ID o de ID de ventana; usa
`kilde devices` para ver las ventanas disponibles.

```sh
# Pantalla + audio del sistema + micrófono
kilde rec --audio system --audio mic out.mov

# Solo audio
kilde rec --no-video memo.m4a

# Solo el audio de una ventana de Zoom coincidente, excluyendo otras apps
kilde rec --no-video --window zoom meeting.m4a

# Varias ventanas en un archivo. Pasa --window más de una vez; la salida tiene
# el tamaño de toda la pantalla y todo lo que quede fuera de esas ventanas
# aparece en negro
kilde rec --window zoom --window notes demo.mov

# Oculta apps concretas de una grabación a pantalla completa, como un gestor de
# contraseñas o un cliente de chat. Los bundle ID coinciden de forma exacta --
# ejecuta `kilde devices` para encontrarlos
#   Nota: el *audio* de una app excluida también se descarta. Excluir una app
#   de reuniones o un navegador pierde también su sonido; si solo quieres
#   ocultar lo que aparece en pantalla, considera grabar las ventanas que
#   quieras con --window
kilde rec --exclude-app com.1password.1password --exclude-app com.tinyspeck.slackmacgap demo.mov

# Captura HDR, que necesita macOS 15 o posterior, una pantalla HDR y HEVC.
# La salida es HEVC Main10 con PQ; los primarios siguen el preajuste del SO
#   (macOS 26: BT.2020 con metadatos HDR10, 15: Display P3)
#   Si falta alguno de esos elementos, kilde graba en SDR, explica por qué y
#   sale con código 0 -- no te entregará un archivo que creas HDR cuando no lo es
kilde rec --hdr --codec hevc demo.mov
```

Para grabar a través de BlackHole y seguir oyendo el audio, instala BlackHole
y usa el modo monitor. El modo monitor crea y desmonta temporalmente el
dispositivo de salida múltiple necesario durante la sesión de grabación.

```sh
brew install --cask blackhole-2ch
kilde rec --no-video --audio "device:BlackHole 2ch" --monitor meeting.m4a
```

Inicia kilde en modo de espera de atajo y usa Cmd+Shift+R globalmente para
iniciar y detener la grabación. Pulsar Ctrl+C mientras espera sale sin crear
ningún archivo. `--hotkey` no se puede combinar con `--countdown`.

```sh
kilde rec --hotkey cmd+shift+r meeting.mov
```

`--duration` *sí* se puede combinar con un atajo, pero se cuenta desde el
momento en que termina la espera — no desde el arranque. Un `hotkey` en el
archivo de configuración convierte incluso `kilde rec --duration 30s` en un
comando que espera la tecla, así que un script desatendido se quedaría detenido
hasta que alguien la pulse (Ctrl+C, SIGTERM y SIGHUP salen limpiamente). kilde
imprime una advertencia en stderr cuando un atajo *de la configuración* retrasa
un `--duration` que pediste; un `--hotkey` explícito no avisa, porque esperar
es lo que pediste. Para grabar sin supervisión, elimina la tecla configurada
con `kilde config unset hotkey`.

### Transcribir después de grabar

Añade `--transcribe` y kilde transcribe la grabación a un archivo sidecar
(`meeting.md`) en cuanto el archivo de grabación queda finalizado (macOS 26+,
sin necesidad del permiso de Reconocimiento del habla):

```sh
kilde rec --transcribe --preset meeting meeting.mov
```

La transcripción se ejecuta íntegramente en tu Mac (en el dispositivo) — ni el
audio ni el texto transcrito se envían a ningún sitio. Empieza solo cuando el
archivo de grabación está completo, así que un fallo o una interrupción nunca
tocan la grabación en sí. Pulsar Ctrl+C mientras se transcribe interrumpe solo
la transcripción — el archivo de grabación permanece en el disco y el código de
salida sigue siendo `0`. Un *fallo* de la transcripción (por ejemplo un entorno
o idioma no admitido, o un fallo al descargar el modelo) sale con código `1`,
porque lo pediste explícitamente. `--transcript-format md|srt|vtt|txt|json`
elige el formato del sidecar y `--locale ja-JP` elige el idioma. En una
grabación `--no-video --audio-tracks separate`, las dos pistas de audio se
transcriben con etiquetas de hablante («相手» para la pista del audio del
sistema, «自分» para la del micrófono). También puedes transcribir una
grabación ya existente con `kilde transcribe FILE`.

### ¿Por qué no se requiere BlackHole?

kilde usa la captura nativa de audio del sistema de ScreenCaptureKit, así que
la grabación normal de pantalla y audio funciona sin un driver de audio
virtual. BlackHole solo hace falta para enrutar el audio de forma especial,
como en el modo monitor, cuando quieres escuchar el audio mientras lo grabas
por otra vía.

## Opciones y valores predeterminados de grabación

De forma predeterminada, kilde captura la pantalla `0`, graba el audio
`system` en una pista `mixed`, usa el códec de vídeo H.264 e incluye el
cursor. Si no se indica una ruta de salida, crea `kilde-yyyyMMdd-HHmmss.mp4`
(un `.mov` si se elige `--format mov` o cuando ProRes fuerza el contenedor
predeterminado de vuelta a `mov`, o un `.m4a` en modo de solo audio). Ejecuta
`kilde rec --help` para ver la lista completa de opciones.

Entre las opciones habituales:

- `--display NUMBER` o `--window MATCH` para elegir el objetivo de captura
- `--audio system|mic|device:NAME_OR_UID|none` repetible para elegir las fuentes de audio
- `--audio-tracks mixed|separate` para mezclar las fuentes o conservar pistas separadas
- `--no-video`, `--monitor`, `--duration 30s` (se cuenta desde el fin de la espera
  del atajo, no desde el arranque), `--codec h264|hevc|prores`, `--fps NUMBER` y
  `--format mov|mp4` (la extensión `.mov`/`.mp4` de la ruta de salida también
  elige el contenedor; ProRes no cabe en MP4, así que un `--codec prores` solo
  retrocede a `mov`)
- `--cursor` o `--no-cursor`, `--countdown SECONDS`, `--preset meeting` y
  `--hotkey SHORTCUT`
- `--transcribe` (con `--transcript-format` y `--locale`) para transcribir la
  grabación a un archivo sidecar una vez finalizada (macOS 26+)
- `-o PATH` o `--output PATH` como alternativa a la ruta de salida posicional

## Configuración

Los valores persistentes de `rec` se guardan en `~/.kilde/config.json`.
Gestiónalos con `kilde config show|set|unset|path` en lugar de editar el
archivo a mano.

```sh
kilde config set outputDirectory ~/Movies/kilde
kilde config set defaultAudioSources system,mic
kilde config set showsCursor false   # Para mostrarlo solo una vez, kilde rec --cursor
kilde config set hotkey cmd+shift+r  # Inicia rec en modo de espera de atajo (ver abajo)
kilde config set transcribe true     # Transcribe cada grabación al detenerse
kilde config set transcriptFormat srt
kilde config set locale ja-JP
kilde config show
kilde config unset hotkey
kilde config path
```

Las claves admitidas son `outputDirectory`, `defaultAudioSources`,
`audioTracks`, `format`, `codec`, `videoBitrate`, `audioBitrate`, `fps`,
`showsCursor`, `hotkey`, `transcribe`, `transcriptFormat` y `locale`.

La configuración de grabación se resuelve en este orden, de mayor a menor
prioridad:

1. Argumentos del CLI
2. `--preset`
3. Variables de entorno como `KILDE_OUTPUT_DIR`
4. El archivo de configuración
5. Los valores integrados

El atajo tiene su propio orden equivalente: `--hotkey`, luego el `hotkey`
configurado, luego sin modo de espera.

Un atajo global solo puede tenerlo un proceso a la vez, así que **gana quien lo
registre primero**. Esto importa cuando la app de la barra de menús está en
ejecución, porque se inicia al iniciar sesión y mantiene el atajo configurado.
Cuando `rec` encuentra la tecla ya ocupada, un atajo que venga del archivo de
configuración se omite: imprime una advertencia y empieza a grabar de inmediato
en lugar de esperar. Un `--hotkey` explícito falla indicando el motivo, porque
esperar es lo que pediste.

`rec` comprueba si la tecla está disponible justo antes de decidir, así que un
proceso que la tome en ese instante aún hará que salga con el error de
registro — en la práctica hace falta lanzar dos grabaciones casi al mismo
tiempo, ya que un atajo mantenido por la GUI queda atrapado por esa
comprobación.

Configura `KILDE_CONFIG_DIR` para reubicar tanto `config.json` como
`monitor-state.json`, algo útil en entornos aislados y para pruebas. Su valor
debe ser una ruta absoluta o empezar por `~`; las rutas relativas se rechazan.
Una configuración no válida o un directorio de salida inexistente fallan antes
de grabar con el estado de salida `1`.

## Códigos de salida

| Código | Significado |
|---:|---|
| `0` | Éxito, incluida una grabación detenida de forma segura por SIGINT, SIGTERM o SIGHUP. Interrumpir con Ctrl+C la transcripción posterior de `rec --transcribe` también sale con código `0` — el archivo de grabación permanece en el disco |
| `1` | Otro fallo en tiempo de ejecución, incluida una configuración no válida. Un fallo de la transcripción posterior de `rec --transcribe` (entorno o idioma no admitido, fallo al descargar el modelo, fallo al escribir el sidecar) también sale con código `1` — el archivo de grabación permanece en el disco, pero la transcripción la pediste explícitamente |
| `2` | Falta un permiso |
| `3` | No se encontró la pantalla, la ventana o el dispositivo de audio |
| `64` | Error de análisis de la línea de comandos o de validación de opciones, como `rec --fps 0` |

## GUI

La app de la barra de menús en `gui/` usa `NSStatusItem` y `NSPopover`. Se
gestiona manualmente con AppKit porque `MenuBarExtra` de SwiftUI con un panel
`.window` no se abre en macOS 26. Comparte el mismo motor de grabación
`KildeCore` que el CLI mediante una dependencia de
[kilde-team/kilde-cli-swift](https://github.com/kilde-team/kilde-cli-swift)
(privado — la resolución del paquete requiere credenciales git de
kilde-team) con **revisión fijada**. El proyecto Xcode, que no se sube al
repositorio, se genera desde `project.yml` con
[XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen   # Solo la primera vez
cd gui && xcodegen
open KildeGUI.xcodeproj # Ejecuta el esquema KildeGUI en Xcode
```

Tras compilar, aparece un icono ● en la barra de menús. Haz clic para elegir el
objetivo de captura (pantalla / ventana / solo audio), las fuentes de audio y
el directorio de salida, y empieza a grabar. Durante la grabación, la barra de
menús muestra el tiempo transcurrido y el panel muestra medidores de nivel por
fuente. Cerrar el panel no detiene la grabación. Los valores iniciales se leen
del mismo `~/.kilde/config.json` que el CLI.

Cuando termina una grabación, una notificación muestra su nombre, duración y
tamaño; al hacer clic, el archivo se revela en el Finder. El panel también
enumera las cinco grabaciones más recientes del directorio de salida —
incluidas las hechas con el CLI — y al hacer clic en una se revela en el
Finder. Puedes fijar un atajo global en el panel para iniciar y detener la
grabación desde cualquier app; se guarda como `hotkey` en el mismo archivo de
configuración, así que `kilde rec` también lo lee. Una casilla registra la app
para que se inicie al iniciar sesión mediante `SMAppService`; macOS puede
pedirte aprobarlo en Ajustes del Sistema.

El archivo de configuración solo se comparte con el CLI en la versión de
distribución directa (GitHub Releases / Homebrew, o compilada desde el código
fuente). La versión del Mac App Store se ejecuta en el App Sandbox y no puede
leer `~/.kilde`: guarda sus ajustes dentro de su propio contenedor
(`~/Library/Containers/com.takezou621.KildeGUI/Data/Library/Application Support/kilde/`), por lo que
los valores iniciales, el atajo global y los demás ajustes no se comparten con
`kilde rec`.

## Desarrollo

- Motor y CLI (`KildeCore`, `kilde`): se desarrollan en
  [kilde-team/kilde-cli-swift](https://github.com/kilde-team/kilde-cli-swift)
  (privado) — sus pruebas y CI son de ese repositorio
- App de barra de menús, workflow de versiones y fórmula de Homebrew: este repositorio
  - Compilación, permisos y solución de problemas de la GUI:
    [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)
  - Versiones oficiales (firma, notarización, distribución):
    [docs/RELEASE.md](docs/RELEASE.md)
- Arquitectura y comportamiento: [docs/DESIGN.md](docs/DESIGN.md)
- Resultados del spike M0: [docs/SPIKE-NOTES.md](docs/SPIKE-NOTES.md)
- Estudio de estrategias de monetización (en japonés):
  [docs/MONETIZATION.md](docs/MONETIZATION.md)

## Hoja de ruta

- **M0** ✅ Spike técnico: validada la captura de audio con ScreenCaptureKit
- **M1** ✅ MVP del CLI: `kilde rec / devices / doctor / audio monitor / inspect`
  (el motor y el código del CLI viven ahora en
  [kilde-team/kilde-cli-swift](https://github.com/kilde-team/kilde-cli-swift),
  issue #115)
- **M2** Atajo global ✅; captura por región ✅; pausa/reanudación
- **M3** App GUI de barra de menús: esqueleto ✅ / UI de grabación ✅ /
  incorporación de permisos ✅ / notificaciones de finalización, grabaciones
  recientes, atajo global e inicio al iniciar sesión ✅

## El nombre

*kilde* es la palabra en danés y noruego para **fuente** — literalmente un
manantial, el lugar donde brota el agua, y por extensión la fuente de una
información, como las fuentes de un periodista o de un académico.

Cada vez más conocimiento se crea en reuniones en línea y frente a una
pantalla. En una era en la que la IA puede transcribir, resumir y buscar en las
grabaciones, estas — el vídeo, el audio, la pantalla — son en sí mismas fuentes
valiosas de información, no subproductos que se descartan al terminar la
reunión. kilde lleva el nombre de aquello para lo que existe: la fuente. Por la
misma convicción, kilde está hecho de modo que detener una grabación — incluso
con Ctrl+C — deja siempre un archivo finalizado y reproducible. Una fuente que
no puedes volver a abrir no es ninguna fuente.

## Contribuir

Los informes de errores, las peticiones de funcionalidades y los pull requests
son bienvenidos. Consulta [CONTRIBUTING.md](CONTRIBUTING.md) para empezar. El
trabajo en el motor de grabación y el CLI se realiza en
kilde-team/kilde-cli-swift.

## Licencia

[MIT License](LICENSE)
