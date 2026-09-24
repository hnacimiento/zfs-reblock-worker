# Ronda 13 — consola interactiva en vivo (secciones I y H completas)

**[Leer en español ↓](#español)** · **[Read in English ↓](#english)**

---

# Español

La única parte del `TEST-PLAN.md` que no podía cerrarse por SSH remoto en
solitario: todo lo que depende de que alguien real esté tecleando en una
terminal interactiva, con teclas sueltas (`[P]`/`[Q]`/`[C]`), mientras el
worker corre. Ejecutada turno por turno: el operador ejecutaba un paso a la
vez en su propia sesión SSH, y una sesión de solo lectura aparte confirmaba
cada paso (`events.log`, `journal.tsv`, y `remote/zrw-deep-observe.sh` para
observar `/proc` del proceso real) antes de dar luz verde para el
siguiente.

No hay logs de sesión únicos para archivar como en las rondas anteriores —
la evidencia de esta ronda es el propio intercambio turno por turno, más
las tres correcciones de código que salieron de hallazgos en vivo.

## Resultado

Secciones **I** y **H** completas, todos los ítems confirmados. Ver el
detalle en `docs/TEST-PLAN.md`. Tres hallazgos reales, cada uno corregido y
desplegado en el momento, sin esperar al final de la sesión:

### 4.4.2 — el teclado del operador competía con el inventario por `stdin`

`run_loop()` leía el inventario de archivos por `stdin` (sin descriptor
propio), y `poll_keys()` (que atiende las teclas) también leía de `stdin`,
igual sin descriptor propio, desde mucho más adentro de la misma cadena de
llamadas. Encontrado apretando `[Q]` durante una copia real: un archivo
del inventario —nunca tocado, siempre intacto en disco— terminó marcado
`MISSING` con ruta vacía en el journal. Corregido: el inventario ahora usa
el descriptor 3, dejando `stdin` libre para el teclado.

### 4.4.4 — `[C]` cambiando `recordsize`/`threshold` podía abortar el job en curso

`env_sane()` (el chequeo de seguridad que corre antes de cada archivo)
comparaba el recordsize real del dataset contra la misma variable global
que `[C]` opción 8 muta para "el próximo job". Cambiarla en caliente hizo
que el job **actual**, real, en curso, abortara con `[ERROR] El recordsize
cambio durante la ejecucion` — pese a que el dataset real nunca cambió.
Corregido con `RUN_RECORDSIZE`/`RUN_THRESHOLD`, congeladas una sola vez al
resolver la configuración del job, inmunes a cambios posteriores de `[C]`.

### 4.4.7 — `Ctrl+C` no terminaba el proceso, solo la pregunta actual

`trap cleanup EXIT INT TERM`, con un `cleanup()` que nunca llamaba a
`exit`. Un trap solo reemplaza la acción *por defecto* de una señal — no
hace que el proceso termine solo. Encontrado navegando el wizard: un
`Ctrl+C` no salió del programa, saltó a la siguiente pregunta; hizo falta
un `Ctrl+C` por cada pregunta restante. El mismo trap cubre una copia real
en curso: un operador tratando de abortar un job colgado se hubiera
encontrado con lo mismo. Corregido separando `trap cleanup EXIT` de
`trap 'exit 130' INT` / `trap 'exit 143' TERM`.

## Dos mejoras de UI, hechas en el momento

- **4.4.5 / 4.4.6 — color en el dashboard**: existía una infraestructura de
  color completa (paleta, detección de `NO_COLOR`/TTY, un colorizador de
  `[TAG]` para el log) pero casi sin usar en el dashboard en vivo. Dos
  piezas nuevas y reutilizables: `cfield()` (colorea un campo de ancho fijo
  sin romper la alineación) y `chealth()` (mapea el estado del servidor al
  mismo lenguaje de color que ya usa el log). Aplicado en dos pasadas:
  contadores/salud del servidor/título del resumen final primero, después
  governor/autoridad manual/estado del archivo actual — pensado desde qué
  necesita notar un operador mirando la pantalla durante horas, no desde
  "pintar todo".

## Un detalle del entorno real, no un bug

Al intentar mover `whiptail` fuera del PATH para probar el fallback
(`sudo mv /usr/bin/whiptail ...`): `Read-only file system`. TrueNAS SCALE
monta la raíz del sistema en solo lectura por diseño. Resuelto con el mismo
patrón de PATH sombra ya usado en la ronda 5 (symlinks a todo el PATH real
salvo `whiptail`, en un directorio aparte) — sin tocar el filesystem de
solo lectura del sistema.

## Interrupción real, en el medio

El servidor y la PC del operador se reiniciaron a mitad de la ronda (evento
real, no planeado). Al retomar: NAS limpio salvo por los archivos de la
prueba en curso (6 archivos de la sección I, ya completados, sin
consecuencia), `whiptail` intacto en su lugar. Se limpió y se continuó
desde la sección H sin perder nada de lo ya confirmado.

## Cierre

Con esto, el `TEST-PLAN.md` completo queda cerrado salvo: el dataset
completo de producción (decisión del operador, sección J), `b3sum`/BLAKE3
(si se instala en algún momento), ACL POSIX/`atime=on` real sin dataset de
laboratorio dedicado (ya cerrados vía `zrw-lab-dataset.sh` en la ronda 9,
mencionado acá por completitud), y "llenar el pool" (prohibido de forma
permanente). Versión final: **4.4.7**.

---

# English

The only part of `TEST-PLAN.md` that couldn't be closed via remote SSH
alone: everything that depends on a real person typing at an interactive
terminal, with individual keystrokes (`[P]`/`[Q]`/`[C]`), while the worker
runs. Run turn by turn: the operator executed one step at a time in their
own SSH session, and a separate read-only session confirmed each step
(`events.log`, `journal.tsv`, and `remote/zrw-deep-observe.sh` to observe
`/proc` for the real process) before the next step was given the green
light.

There are no single session logs to archive as in previous rounds — the
evidence for this round is the turn-by-turn exchange itself, plus the
three code fixes that came out of findings made live.

## Result

Sections **I** and **H** complete, all items confirmed. See the detail in
`docs/TEST-PLAN.md`. Three real findings, each fixed and deployed on the
spot, without waiting for the end of the session:

### 4.4.2 — the operator's keyboard was competing with the inventory for `stdin`

`run_loop()` read the file inventory from `stdin` (with no descriptor of its
own), and `poll_keys()` (which handles keystrokes) also read from `stdin`,
likewise with no descriptor of its own, from much further inside the same
call chain. Found by pressing `[Q]` during a real copy: a file from the
inventory — never touched, always intact on disk — ended up marked
`MISSING` with an empty path in the journal. Fixed: the inventory now uses
descriptor 3, leaving `stdin` free for the keyboard.

### 4.4.4 — `[C]` changing `recordsize`/`threshold` could abort the job in progress

`env_sane()` (the safety check that runs before every file) compared the
dataset's real recordsize against the same global variable that `[C]`
option 8 mutates for "the next job". Changing it on the fly made the
**current**, real, in-progress job abort with `[ERROR] El recordsize cambio
durante la ejecucion` ("recordsize changed during execution") — even though
the real dataset never changed. Fixed with `RUN_RECORDSIZE`/`RUN_THRESHOLD`,
frozen once when the job's configuration is resolved, immune to later
changes from `[C]`.

### 4.4.7 — `Ctrl+C` wasn't terminating the process, only the current prompt

`trap cleanup EXIT INT TERM`, with a `cleanup()` that never called `exit`. A
trap only replaces a signal's *default* action — it doesn't make the
process terminate on its own. Found while navigating the wizard: a
`Ctrl+C` didn't exit the program, it jumped to the next prompt; it took one
`Ctrl+C` per remaining prompt. The same trap covered a real copy in
progress: an operator trying to abort a hung job would have run into the
same thing. Fixed by separating `trap cleanup EXIT` from
`trap 'exit 130' INT` / `trap 'exit 143' TERM`.

## Two UI improvements, made on the spot

- **4.4.5 / 4.4.6 — dashboard color**: a complete color infrastructure
  already existed (palette, `NO_COLOR`/TTY detection, a `[TAG]` colorizer
  for the log) but was barely used in the live dashboard. Two new,
  reusable pieces: `cfield()` (colors a fixed-width field without breaking
  alignment) and `chealth()` (maps server health to the same color language
  the log already uses). Applied in two passes: counters/server
  health/final-summary title first, then governor/manual authority/current
  file status — designed around what an operator needs to notice while
  watching the screen for hours, not around "coloring everything".

## An environment detail, not a bug

When trying to move `whiptail` out of the PATH to test the fallback
(`sudo mv /usr/bin/whiptail ...`): `Read-only file system`. TrueNAS SCALE
mounts the system root read-only by design. Resolved with the same shadow
PATH pattern already used in round 5 (symlinks to the entire real PATH
except `whiptail`, in a separate directory) — without touching the system's
read-only filesystem.

## A real interruption, mid-round

The server and the operator's PC rebooted partway through the round (a
real, unplanned event). On resuming: the NAS was clean except for the files
from the test in progress (6 files from section I, already completed, no
consequence), `whiptail` intact in its place. It was cleaned up and
continued from section H without losing anything already confirmed.

## Close-out

With this, the entirety of `TEST-PLAN.md` is closed except for: the full
production dataset (operator's decision, section J), `b3sum`/BLAKE3 (if it
ever gets installed), real non-trivial POSIX ACL/`atime=on` without a
dedicated lab dataset (already closed via `zrw-lab-dataset.sh` in round 9,
mentioned here for completeness), and "filling the pool" (permanently
forbidden). Final version: **4.4.7**.
