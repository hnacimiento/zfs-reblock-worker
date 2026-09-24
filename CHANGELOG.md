# Changelog

**[Leer en español ↓](#español)** · **[Read in English ↓](#english)**

---

# Español

## 4.4.14 — el governor deja de confundir "disco ocupado siendo útil" con "disco sufriendo"

Rediseño del `health_sample()`, a partir de tres puntos que habían quedado
anotados como "candidatos a mejora" tras la ronda 16 (análisis de hardware local, no publicado)
e investigación externa sobre cómo sistemas maduros resuelven el mismo
problema (limitadores de concurrencia adaptativa de Envoy/Netflix, y el
propio TCP BBR — ver fuentes en el análisis).

### 1. `--adaptive off` ahora mide, aunque no actúe

Antes, `governor_step()` cortaba **antes** de llamar a `health_sample()`
cuando `ADAPTIVE=off` — el panel "SERVIDOR" del dashboard quedaba congelado
en `UNKNOWN`/`0`, no porque el servidor estuviera bien, sino porque el
worker había dejado de mirar. Ahora mide siempre; el corte se movió a
después de `health_sample()`, así que `off` sigue significando exactamente
lo mismo que siempre significó (cero `THROTTLE`/`INCREASE`/pausa
protectiva automática, autoridad del operador absoluta) — esto solo
devuelve la visibilidad real de lo que el disco está haciendo mientras esa
elección está vigente.

### 2. Crédito de "goodput": saturación productiva vs. disco atascado

El hallazgo de fondo de la ronda 16: un `fio` aislado saturó el mismo disco
USB único a 150+ MiB/s reales y sostenidos, y `health_sample()` lo leyó
como `EMERGENCY` (score 14) todo el tiempo, porque `%util`/PSI por sí solos
no pueden distinguir "ocupado entregando bytes reales" de "ocupado y
atascado" — el mismo problema que resuelven TCP BBR y los limitadores de
concurrencia adaptativa (Envoy, Netflix): miden lo que realmente se está
logrando, no solo cuánto está "ocupado" el recurso.

Ahora, si el archivo que se está copiando en este momento lleva al menos 5
segundos en curso y su velocidad real (`GOODPUT_BPS`, medida con los
mismos contadores que ya alimentan el dashboard) alcanza o supera
`--bw-min`, se le resta un crédito fijo (3 puntos) al `HEALTH_SCORE` antes
de decidir el nivel — nunca puede *inventar* presión que las otras señales
no vieran, solo puede suavizarla cuando hay evidencia real de que el disco
sigue entregando. Verificado con el score exacto de la ronda 16 (14, con
`DISK_UTIL=100 DISK_WAIT=60 PSI_IO=85`): con el crédito baja a 11 — sigue
siendo severo si la presión es genuina, pero dejó de castigar por igual a
un disco que rinde y a uno que no.

No se tocaron los umbrales absolutos, el `THROTTLE`, la pausa protectiva ni
ninguna garantía de integridad — la corrección vive enteramente dentro de
`health_sample()`, antes de que nada más lea su resultado.

Fuentes que confirmaron la dirección del diseño:
[Adaptive Concurrency (Envoy)](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/adaptive_concurrency_filter),
[Adaptive request concurrency (Vector/Netflix)](https://vector.dev/blog/adaptive-request-concurrency/),
[BBR, the new kid on the TCP block (APNIC)](https://blog.apnic.net/2017/05/09/bbr-new-kid-tcp-block/).

## 4.4.13 — un `--resume` sin `--bwlimit` podía arrancar del default, no del job guardado

Nota dejada sin resolver en el 4.4.12, cerrada ahora: `validate()` calculaba
`BW_BPS` (el ancho de banda efectivo real) a partir de `BW_TARGET` **antes**
de que la resolución del job y `load_config()` corrieran — así que un
`--resume` sin `--bwlimit` explícito arrancaba siempre del default
compilado (35M), nunca del que el job realmente tenía guardado. Inofensivo
bajo `adaptive=auto` (el governor lo corrige en segundos), pero silencioso
y real bajo `--adaptive off`: nada iba a corregirlo de vuelta a la tasa fija
que el operador había elegido.

### Arreglo

El cálculo se separó a una función propia, `finalize_bw()`, movida a
después de que `load_config()`/`CLI_SET` ya resolvieron el `BW_TARGET`
final — un flag explícito sigue ganando, y un `--resume` sin flags ahora sí
toma el valor guardado del job, no el default. Validado con test unitario
que reproduce el escenario (job guardado con `BW_TARGET=20M`, resume sin
`--bwlimit`, `BW_BPS` final tiene que ser el de 20M, no el de 35M).

Investigado en paralelo: el orden correcto (`defaults < config < flags
explícitos`) coincide con la práctica estándar de precedencia de
configuración en herramientas de línea de comandos — confirma que la
dirección del arreglo era la correcta, no solo una corrección ad-hoc.

## 4.4.12 — un flag explícito en `--resume` no se aplicaba de verdad

Encontrado en vivo, tratando de medir el rendimiento real del disco:
`--resume --adaptive off --bwlimit 80M` seguía frenando por presión como si
`--adaptive off` nunca se hubiera pasado — el log mostraba `THROTTLE` y
`PAUSA PROTECTIVA` igual que siempre.

### Causa raíz

`load_config()` hacía un `source` liso y llano de `config.env` en cada
`--resume`. Eso pisaba **cualquier** campo que el operador acabara de pasar
por línea de comandos con el valor guardado cuando el job se creó — en
este caso, `ADAPTIVE=auto` (el valor original) volvía a escribirse encima
del `ADAPTIVE=off` que `parse_args` acababa de fijar, apenas unas líneas de
código después. El mismo problema alcanzaba, en teoría, a cualquier otro
campo persistido: `--bw-min`, `--bw-max`, `--integrity`, `--cooldown`,
`--workers`, etc.

### Arreglo

Nuevo `CLI_SET`: un registro de qué campos tocó explícitamente esta
invocación. `load_config()` ahora salta esos campos al leer `config.env` —
un flag pasado en el `--resume` gana; un campo no mencionado sigue viniendo
del job guardado, exactamente como antes. Cubierto con test unitario que
reproduce el escenario exacto (un `--adaptive off` que debe ganar, un
`COOLDOWN` no pasado que debe seguir viniendo del archivo).

### Nota, sin resolver todavía

`validate()` (que calcula el `BW` efectivo inicial a partir de
`BW_TARGET`) corre *antes* que la resolución del job y `load_config()`. En
un `--resume` sin `--bwlimit` explícito, eso significa que el `BW` de
arranque sale del default compilado (35M), no del que el job tenía
guardado — inofensivo en la práctica porque el governor adaptativo lo
corrige solo en los primeros segundos, pero es una inconsistencia real que
queda anotada para revisar en otra ronda, no resuelta acá para no
mezclarla con el arreglo de `CLI_SET`.

## 4.4.11 — aviso temprano cuando el dataset vive en un disco USB

Tras confirmar en vivo (rondas de `Series`) que un
disco USB único, sin redundancia, tiene un techo de escritura sostenida
mucho más bajo que su velocidad nominal — y que el governor solo lo
descubre a los ponchazos, probando y retrocediendo varias veces antes de
asentarse cerca del número real.

### Qué cambia

Nueva función `usb_advisory()`: resuelve el/los disco(s) físico(s) detrás
del pool del dataset objetivo (vía `zpool status -PL` + `lsblk -no pkname`)
y, si alguno cuelga de `/sys/.../usb.../`, avisa una vez al arrancar un job
nuevo (y en `--dry-run`) sugiriendo medir con `--dry-run --dry-sample` y
fijar `--bwlimit`/`--bw-max` cerca del número real en vez de dejar que el
governor lo encuentre solo. Puramente informativo: no cambia el `BW`, no
toca el hash de verificación, el commit atómico ni la lógica del governor —
ninguna de las garantías de seguridad del worker se mueve por esto. Si
`lsblk` no está instalado, es un no-op silencioso, como corresponde a
cualquier señal opcional del worker.

## 4.4.10 — el governor oscilaba: recuperar, subir, volver a CRITICAL, cada archivo

Encontrado en vivo, corriendo `Series` ya con el arreglo de memoria de
4.4.8 aplicado: la presión de memoria bajó (18-19%, sana), pero el patrón
de pausas protectivas seguía — casi un archivo sí, un archivo no.

### Causa raíz

ZFS sincroniza datos sucios en un ciclo de ~5s (`zfs_txg_timeout`), y en un
disco único lento ese sync periódico es lo bastante ráfagoso como para
parecer presión real cada vez que ocurre — el patrón "picket fence",
documentado por el propio proyecto OpenZFS. El governor, apenas veía una
muestra `HEALTHY` (incluso la primerísima después de que una pausa
protectiva se resolviera), subía el BW de inmediato — y esa suba
sobrepasaba exactamente a tiempo para la siguiente ráfaga del sync,
disparando CRITICAL otra vez. El ciclo se repetía en casi todos los
archivos: recuperar, subir, CRITICAL, pausar, recuperar, subir...

### Arreglo

Nueva variable `LAST_CRIT_TS`, actualizada cada vez que una muestra da
CRITICAL o EMERGENCY. Mientras no pasen al menos `HEALTH_INTERVAL*3`
segundos desde la última, una lectura `HEALTHY` mantiene el BW donde está
(`HOLD`, con motivo "enfriamiento tras presión reciente") en vez de subirlo
— le da un par de ciclos de sync más para asentarse antes de confiar en que
"sano" significa sano. `THROTTLE` y la pausa protectiva en sí no cambian:
el freno ante peligro real sigue siendo inmediato, esto solo frena el
"acelerador" tras una crisis reciente.

## 4.4.9 — un job resumido mostraba la versión con la que se creó, no la que corre

Encontrado revisando el arreglo de 4.4.8 en vivo: tras subir el binario y
reanudar un job creado con la versión anterior, el dashboard, `--status` y
cada línea del log seguían diciendo "v4.4.7" — aunque el código que
realmente corría ya era 4.4.8.

### Causa raíz

`save_config()` escribía `VERSION=<version>` en `config.env`, y
`load_config()` hace un `source` directo de ese archivo en cada `--resume`.
Un campo llamado literalmente `VERSION` pisaba la constante del binario en
ejecución con lo que sea que decía el archivo — sin afectar ningún
comportamiento real (`$VERSION` solo se usa para mostrarse, nunca para
decidir nada), pero dejando información falsa en todo lo que un operador
mira para saber qué versión está corriendo de verdad.

### Arreglo

El campo pasa a llamarse `JOB_VERSION` — un registro histórico de con qué
versión se creó el job, que ya no pisa el `$VERSION` en vivo. Jobs
existentes, creados antes de este arreglo, van a seguir mostrando la
versión vieja hasta que se cierren (su `config.env` no se reescribe en cada
resume) — cosmético nada más, sin ningún efecto sobre el trabajo real.

## 4.4.8 — el ARC de ZFS se contaba como memoria "usada", inflando la presión

Encontrado en vivo, corriendo `Series` en producción real: el dashboard
mostraba `mem 92%` con CPU, iowait y disco prácticamente en cero, y el
governor igual sumaba puntos de presión por esa lectura — pausando jobs
antes de que hubiera ninguna presión real de disco o CPU.

### Causa raíz

`read_cpu_mem()` calculaba memoria "usada" como
`100 - (MemAvailable*100/MemTotal)`. En Linux, `MemAvailable` no sabe que
el ARC de ZFS es reclamable — el ARC vive fuera de la contabilidad normal
del page cache del kernel, así que un host perfectamente sano con el ARC
cerca de su techo (hasta 95.7% de la RAM, por diseño) se lee como si esa
memoria estuviera comprometida de verdad. Confirmado en vivo: ARC en
~20 GiB de 23.5 GiB totales, `MemAvailable` mostrando solo ~2 GiB libres —
92% "usado" alimentando el `health_score` sin que hubiera ninguna presión
real.

### Arreglo

`read_cpu_mem()` ahora le devuelve al cálculo lo que el ARC podría ceder
sin problema: `tamaño actual del ARC` menos su propio piso configurado
(`c_min`), leído de `/proc/spl/kstat/zfs/arcstats` (ruta configurable vía
`ARCSTATS_FILE`/`ZRW_ARCSTATS_FILE`, para que el test unitario pueda
apuntarlo a un fixture). Si el archivo no existe (host sin ZFS, instalación
exótica), es un no-op silencioso y `MEM` cae al cálculo anterior sin
cambios. Verificado en vivo contra el NAS de referencia: el mismo momento
que antes leía `92%` ahora lee `14%` — sin tocar ninguna otra parte del
governor.

## 4.4.7 — `Ctrl+C` no terminaba el proceso, solo la pregunta actual

Encontrado en vivo, probando el explorador de directorios del wizard: un
`Ctrl+C` no salió del programa — saltó a la siguiente pregunta. Hizo falta
un `Ctrl+C` por cada pregunta restante del wizard, y la última (perfil, con
respuesta vacía) terminó en un error de validación en vez de una salida
limpia.

### Causa raíz

`trap cleanup EXIT INT TERM` registraba el mismo manejador para las tres
señales, y `cleanup()` nunca llamaba a `exit`. Un trap solo reemplaza la
acción *por defecto* de una señal — no hace que el proceso termine por su
cuenta. Sin un `exit` explícito, tras limpiar, la ejecución simplemente
continuaba justo después de lo que se había interrumpido (el `read` de la
pregunta en curso). El mismo trap cubre una copia real en curso: un
operador tratando de abortar un job colgado con `Ctrl+C` se hubiera
encontrado con el mismo problema.

### Corrección

`trap cleanup EXIT` separado de `trap 'exit 130' INT` / `trap 'exit 143'
TERM` (128+señal, la convención estándar). Ese `exit` explícito es lo que
efectivamente termina el proceso, y al hacerlo vuelve a disparar el trap de
`EXIT`, así que `cleanup()` sigue corriendo una sola vez, sin duplicar.
Cubierto con un chequeo estático que impide reintroducir el patrón viejo.

## 4.4.6 — color en el dashboard, segunda pasada (governor, autoridad manual, estado)

Tras ver la 4.4.5 en vivo: "se puede mejorar más, sin
volverlo ilegible". Pensado desde qué necesita notar un operador mirando la
pantalla durante horas, no desde "pintar todo":

- **`autoridad MANUAL`** en la línea de BW: magenta (mismo color que
  `[OPERATOR]` en el log) — recuerda que hay un techo puesto a mano,
  fácil de olvidar en una corrida larga.
- **`Governor`**: `THROTTLE`=amarillo (te está sacando ancho de banda),
  `INCREASE`=verde (te lo está devolviendo), `HOLD`=tenue (nada pasando,
  no compite por atención).
- **`Estado`** (qué está haciendo el archivo actual): amarillo si está
  pausado/esperando, tenue si es el enfriamiento deliberado entre
  archivos, cian para el instante del commit (el único momento
  irreversible) — sin color en el resto, que es el caso común
  ("trabajando normal").

Mismo cuidado que en la 4.4.5: los campos de ancho fijo (`Governor %-9s`)
se rellenan primero y se colorean después, para que los bytes ANSI nunca
entren al cálculo de alineación.

## 4.4.5 — color en el dashboard, reusando la paleta que ya existía

Durante la sesión de consola en vivo: ayudar al ojo a
encontrar los datos en el dashboard. Investigado antes de tocar nada: ya
existía una infraestructura de color completa (`set_palette()`, detección
de `NO_COLOR`/`--no-color`/TTY, y `paint()`, un colorizador de etiquetas
`[TAG]` para el log) — pero `paint()` solo corre en modo `plain`, nunca en
el dashboard en vivo (`log()` no imprime nada línea por línea en modo
`dash`, por diseño). El dashboard mismo solo usaba color para los bordes.

Dos piezas nuevas, reutilizables:
- **`cfield COLOR WIDTH VAL [FORCE]`** — colorea un campo numérico de ancho
  fijo sin romper la alineación: primero rellena el texto plano al ancho
  pedido, y recién después lo envuelve en color por fuera — los bytes ANSI
  invisibles nunca entran al cálculo de ancho de un `%-Ns` de printf (que es
  exactamente lo que lo rompería si se colorea el valor *adentro* del
  campo). Por defecto no colorea cuando el valor es `0` (una fila en cero
  pidiendo atención es peor que una que no lo hace); `FORCE=1` para los
  casos que sí deben colorearse siempre.
- **`chealth ESTADO`** — mapea `HEALTHY/BUSY/PRESSURE/CRITICAL/EMERGENCY/
  UNKNOWN` al mismo lenguaje de color que ya usa `paint()` para `CRITICAL`
  en el log, en vez de inventar una paleta paralela.

Aplicado a: la línea de contadores del dashboard (Reescritos=verde,
Fallidos=rojo si>0, Stale=amarillo si>0, Omitidos/Ausentes=tenue), la línea
de salud del servidor (color según el estado real), y el título del
resumen final (`JOB COMPLETADO`=verde, amarillo si hubo fallidos o quedó
pausado, rojo si se detuvo por un cambio del entorno). Verificado que el
ancho visible (sin los códigos ANSI) sigue siendo exacto incluso con color
activo, y que el valor `0` efectivamente queda sin colorear.

`cfield()`/`chealth()` quedan como piezas genéricas para la próxima vez que
haga falta colorear algo más en el dashboard, sin repetir este análisis.

## 4.4.4 — `[C]` cambiando recordsize/threshold podía abortar el job en curso

Encontrado en la misma sesión de consola en vivo, probando la sección I:
cambiar `recordsize`/`threshold` desde `[C]` (opciones 8/9, pensadas para
"el próximo job") terminó abortando el job **actual**, real, en curso, con
`[ERROR] El recordsize cambio durante la ejecucion` — pese a que el
recordsize real del dataset nunca cambió.

### Causa raíz

`env_sane()` (el chequeo de seguridad que corre antes de cada archivo)
comparaba el recordsize real del dataset contra `$EXPECTED_RECORDSIZE` — la
misma variable global que `[C]` opción 8 muta. El dashboard y el resumen de
cierre tenían el mismo problema, mostrando el valor "para el próximo job"
como si fuera el del job en curso. Los tres leían una variable pensada para
dos propósitos distintos a la vez.

### Corrección

Nuevas variables `RUN_RECORDSIZE`/`RUN_THRESHOLD`, congeladas una sola vez
apenas se resuelve la configuración del job (creación o `--resume`), sin
verse afectadas por cambios posteriores vía `[C]`. `env_sane()`, el header
del dashboard y el resumen de cierre ahora las usan en vez de las variables
que `[C]` sigue pudiendo mutar libremente para el próximo job. Cubierto con
un test unitario que reproduce el mecanismo exacto.

## 4.4.2 — sesión de consola en vivo: el teclado del operador competía con el inventario por stdin

Encontrado en vivo, apretando `[Q]` durante una copia real: un archivo del
inventario (nunca tocado, siempre intacto en disco) terminó marcado
`MISSING` con una ruta vacía en el journal — sin haber desaparecido nunca.

### Causa raíz

`run_loop()` lee el inventario con `while read line; do ... done
<"$INVENTORY"` — sin especificar descriptor, esa lectura usa **stdin (fd
0)**. `poll_keys()`, que atiende `[P]`/`[Q]`/`[C]`/`[S]` y se llama desde
mucho más adentro de esa misma cadena de llamadas (`process_one` →
`run_rsync` → `poll_keys`, una vez por segundo mientras copia), **también**
lee de stdin, sin su propio descriptor. Los dos terminaban compitiendo por
la misma fuente: cada sondeo de tecla durante una copia consumía en
silencio un byte de lo que fuera que viniera después en el inventario. Con
copias de varios minutos y sondeos cada segundo, alcanzaba para corromper
por completo la línea de un archivo posterior — perdiendo su ruta, nunca su
contenido (el original jamás se toca hasta que el commit está verificado).

### Corrección

`run_loop()` ahora lee el inventario por el descriptor 3
(`done 3<"$INVENTORY"`, `read -u 3`), dejando stdin completamente libre
para `poll_keys()`. Cubierto con un test unitario que reproduce el
mecanismo exacto (sondeos de teclado simulados, agresivos, durante la
lectura de un inventario de 5 líneas) y falla de forma reproducible contra
el código anterior.

## 4.4.1 — ronda 12: reinicio real de la máquina, y un huérfano que `recover_temps()` nunca veía

Reinicio real de la máquina
(`/sbin/reboot`) disparado a mitad de una copia real de 6 GiB, en el
directorio de prueba dedicado. El pool volvió a importar limpio, sin
errores; el estado guardado (`PROCESSING`) volvió a `PENDING` exactamente
como documenta el contrato; `--resume` reescribió el archivo completo,
hash idéntico al original.

### Bug real encontrado: el temporal parcial de rsync nunca se recuperaba

Cuando el corte llega mientras `rsync` todavía está transfiriendo (no
después, cuando ya renombró su archivo de trabajo al nombre final `.tmp`),
lo que queda en disco es el nombre de trabajo propio de `rsync`: el `.tmp`
del worker más el sufijo aleatorio de seis caracteres que `rsync` antepone
mientras transfiere (`.zrw-<job>-<token>.tmp.XXXXXX`). El glob de
`recover_temps()` buscaba exactamente `.zrw-*.tmp` — sin el sufijo, ese
archivo nunca aparecía. `--status` sí lo contaba (usa un glob más amplio),
así que el operador veía "1 temporal en el árbol" para siempre, sin que la
recuperación automática lo tocara ni lo pusiera en cuarentena — violando la
invariante #8 del contrato ("nunca se promueve ni se borra, va a
cuarentena"). Corregido ampliando el glob a `.zrw-*.tmp*`. Cubierto con un
test unitario nuevo que reproduce la forma exacta del nombre real
encontrado en el NAS. Limpiado a mano el archivo huérfano de 1.24 GiB que
había quedado del hallazgo original.

Ver `docs/testing/ronda-12-reinicio-real/` para la evidencia completa.

## Sin publicar — ronda 11: primera corrida real sobre producción (`Musicales`)

Sin cambios de código. Primera vez que el worker corre sobre archivos de
producción reales, en su lugar (no una copia descartable), sobre `Musicales` (14.33 GiB, 199
archivos, ninguno en uso). Solo 1 archivo superó el umbral por defecto y
calificó como candidato; se reescribió con 0 fallos, `mtime` preservado
exacto (fecha original de 2007, no la de la corrida), ACL NFSv4 idéntica, y
`zdb -O` confirmando `dblk=1M`. Los 199 archivos verificados al final
(tamaño/mtime/hash idénticos al inventario inicial). Cierra los primeros
tres ítems de la sección J del `TEST-PLAN.md`; solo queda "el dataset
completo", pendiente de decisión del operador.

Dos errores propios (no del worker), documentados sin maquillar en
`docs/testing/ronda-11-produccion-musicales/README.md`: un `for` sin
comillas rompió la comparación automática de ACL (corregida a mano
después, sobre el archivo real), y la limpieza del script borró el estado
de un job pausado antes de poder cerrarlo con `--resume` explícito (sin
consecuencia real: no quedaba trabajo pendiente genuino, y la integridad ya
estaba verificada de forma independiente).

## Sin publicar — ronda 10: `--auto-resume` confirmado contra presión real, y `zrw-deep-observe.sh`

Sin cambios de código en `zfs-reblock-worker.sh`. Dos cosas nuevas:

- **`--auto-resume` validado contra presión real** (carga sintética con
  `fio`): pausó a los 35s de `EMERGENCY` real,
  quedó vivo esperando, reanudó solo al cortar la carga (40s / 3m19s según
  el archivo), terminó con código 0 sin invocar `--resume` jamás. SHA-256
  idéntico en ambos archivos. Cierra el único ítem que quedaba pendiente de
  `--auto-resume` en `docs/TEST-PLAN.md`.
- **`remote/zrw-deep-observe.sh`**: herramienta nueva, de solo lectura,
  apoyada enteramente en `/proc` (sin `strace`, no instalado en el NAS de
  referencia y no instalado por cuenta propia). Subcomandos `tree`, `io`,
  `fds`, `mem`, `cgroup`, `disk`, `snapshot`, `watch`. Verificada contra el
  worker real de esta misma ronda: árbol de procesos, I/O real por
  proceso, descriptores abiertos resueltos a su ruta exacta, memoria,
  cgroup, `iostat`/`zpool iostat`. Es la base de
  [Live Console Protocol](https://github.com/hnacimiento/zfs-reblock-worker/wiki/Live-Console-Protocol) (el protocolo para cerrar la sección I y
  el ciclo `[C]` de H, que necesitan consola interactiva real) y del diseño
  agendado para `zrw-witness.sh` (ver más abajo).

Ver `docs/testing/ronda-10-auto-resume-carga-sintetica/` para la evidencia
completa.

## Pendiente agendado — `zrw-witness.sh` (compañero de observabilidad)

**No construir todavía.** Diseño completo en [Witness Design](https://github.com/hnacimiento/zfs-reblock-worker/wiki/Witness-Design):
una herramienta paralela, de solo lectura, que se engancha por nombre de
proceso + PID a un `zfs-reblock-worker.sh` corriendo y produce evidencia
estructurada (visual en vivo + JSONL reproducible) de lo que pasa a nivel
del sistema — apoyada en `/proc`, evolucionando `remote/zrw-deep-observe.sh`
(ronda 10) con auto-descubrimiento de PID, correlación con `events.log`/
`journal.tsv`, disparadores automáticos en eventos conocidos, y una capa de
detección de anomalías basada en los hallazgos reales de las rondas 1-10.
Retomar cuando el trabajo sobre el worker principal (incluida la ronda de
consola en vivo, [Live Console Protocol](https://github.com/hnacimiento/zfs-reblock-worker/wiki/Live-Console-Protocol)) se dé por cerrado.

## Sin publicar — ronda 9: causa raíz de `zdb -O`, governor ocioso, y cierre de ACL POSIX/`atime`

Sin cambios de código: los cuatro frentes de esta ronda cerraron
investigación y verificación, no bugs.

- **`zdb -O` en archivos recién escritos**: causa raíz encontrada. No era el
  scrub (ronda 7) — `zdb -O` lee las etiquetas del pool en disco, que solo
  se actualizan en el siguiente ciclo de sincronización de TXG
  (`zfs_txg_timeout`, 5s por defecto). Un archivo recién comprometido es
  invisible para `zdb -O` durante ~5-10s tras su `sync`, confirmado con una
  prueba de retraso escalonado. Con la espera correcta, `zdb -O` confirma
  `dblk=1M` sobre un archivo real recién reblockeado — cierra el ítem
  original del `TEST-PLAN.md`. `zfs_hint()` sigue advisory-only, sin
  cambios: esperar ese ciclo antes de cada hint sería mal tradeoff.
- **Governor con servidor genuinamente ocioso**: confirmado que sube limpio
  hasta `--bw-max` (4 eventos `INCREASE`, 0 `THROTTLE`, BW final exacto
  80.0M). El primer intento se contaminó con la propia carga de armar el
  test (generar los archivos de prueba con `/dev/urandom` disparó presión
  real que el baseline capturó) — corregido generando con `/dev/zero` y
  esperando explícitamente a que el sistema se asiente antes de medir.
- **ACL POSIX no trivial, xattr y `atime=on` real**: cerrados usando
  `zrw-lab-dataset.sh` contra un dataset descartable (`acltype=posix
  atime=on`). Confirmado que ese dataset realmente tiene `atime=on` en
  efecto (leer cambia el atime) y que el worker lo restaura exacto pese a
  eso; ACL y xattr idénticos antes/después.

Deliberadamente sin tocar en esta ronda: `--auto-resume` contra presión
real, porque validarlo ahora requeriría generar carga sintética a propósito
sobre el pool de producción — queda pendiente de autorización explícita.

Ver `docs/testing/ronda-9-hash-cascade-lab-dataset-governor-ocioso/` para
la evidencia completa.

## Herramienta nueva — `remote/zrw-lab-dataset.sh`

Script ayudante, para correr a mano en el NAS, que crea y destruye un
dataset de laboratorio descartable (`--parent POOL --acltype posix|nfsv4
--atime on|off`), para poder cerrar los dos ítems de `docs/TEST-PLAN.md`
que no se podían probar en `toolbox/media` sin tocar producción: ACL POSIX
no trivial (el único `acltype=posix` real del pool son datasets de sistema)
y `atime=on` (el dataset real tiene `atime=off`). Nunca se ejecuta por su
cuenta — es una herramienta para que el operador la use cuando decida cerrar
esos dos ítems. `destroy` solo acepta nombres que empiecen con `zrw-lab`
(piso de seguridad fijo, no depende de lo que el operador haya tecleado en
`create`) y pide confirmación escribiendo el nombre completo del dataset,
salvo que se pase `--yes`. Verificado con un ciclo real completo
(`create` → `status` → `destroy`) contra `toolbox`: crea con las propiedades
pedidas, confirma vía `zfs list`, destruye limpio.

## 4.4.0 — BLAKE2b como default, con cascada a BLAKE3 y SHA-256

**Cambio de comportamiento por defecto.** El hash usado para verificar
integridad pasa de `sha256` a `b2` (BLAKE2b, vía `b2sum` de GNU coreutils).
No es un downgrade de seguridad: BLAKE2b (RFC 7693) es un hash criptográfico
con la misma garantía de resistencia a colisión/preimagen que SHA-256 para
el propósito de este contrato (detectar cualquier diferencia entre el
origen y el temporal, accidental o deliberada), y además evita la debilidad
de SHA-256 frente a length-extension. Medido en el NAS de referencia: 482
MB/s contra 167 MB/s — casi 3x más rápido en las dos pasadas de hash que
hace `--integrity strict`/`maximum` en cada archivo.

La selección ahora cae en cascada: **`b2` → `b3` (BLAKE3) → `sha256`**, cada
escalón usado solo si el anterior no está disponible en el host. `sha256sum`
sigue siendo dependencia crítica (el worker no arranca sin él), así que la
cascada nunca puede quedarse sin piso. `--hash b3` también existe como
opción explícita. `b3sum` no está instalado en el NAS de referencia todavía;
la lógica y los controles ya están implementados y probados
(estático/unitario/integración), pero falta confirmar el formato de salida
real de `b3sum` una vez instalado — ítem pendiente en `docs/TEST-PLAN.md`,
sección D.

`--hash md5` sigue existiendo sin cambios, para cuando lo único disponible
es detectar corrupción accidental, no manipulación deliberada.

## 4.3.0 — `--auto-resume` y mejoras de claridad, a partir de las oportunidades de las rondas 5-7

### `--auto-resume` (opt-in): la pausa protectiva ya no tiene que terminar el proceso

Hasta ahora, cuando el governor detectaba presión crítica sostenida y disparaba
la "pausa protectiva" (rondas 6 y 7), el worker salía con código `13` y
quedaba esperando un `--resume` manual — aunque la presión bajara un minuto
después. El propio `TEST-PLAN.md` describía "reanudación automática al
liberar" como el comportamiento esperado, y no era lo que hacía el código.

Con `--auto-resume`, ante una pausa protectiva del governor (y **solo** ante
esa causa — un `[P]`/`[Q]` del operador o el disco lleno siguen deteniendo el
job de verdad, sin excepción) el worker espera dentro del mismo proceso,
volviendo a muestrear la salud del servidor, y retoma solo en cuanto ve salud
sostenida de nuevo — sin salir, sin necesitar `--resume`. Está acotado por
`--pause-timeout MIN` (120 por defecto): si la presión nunca cede, se rinde y
sale exactamente como antes, para que nunca quede colgado en silencio. El
comportamiento por defecto (sin este flag) no cambia en absoluto.

Validado con 5 tests unitarios deterministas (sin esperar tiempo real): la
presión que cede deja el job corriendo solo, sin `PAUSE_REQ`; la presión que
nunca cede se rinde igual con `--pause-timeout=0`. Sin confirmación aún
contra presión real del servidor — el scrub que sostenía la presión en las
rondas 5-7 terminó antes de poder hacer esa prueba; queda pendiente para la
próxima vez que haya carga real sostenida (o una carga sintética, si se
decide generarla a propósito).

### Claridad en `--status`: un temporal activo ya no se lee como "residuo"

Mientras un job copia activamente, su propio archivo temporal en curso
coincidía con el mismo patrón `.zrw-*` que un huérfano real, y `--status`
los mostraba igual ("residuos .zrw-* en el arbol"), aunque uno es completamente
normal y el otro indica algo para revisar. Ahora, mientras el job sigue
`en ejecucion`, el texto aclara que puede tratarse del temporal activo, no
necesariamente un residuo. El campo `orphan_temps` del JSON no cambió de
nombre ni de significado, para no romper nada que ya lo consuma.

### Corrección de una causa raíz mal atribuida (`zdb -O`)

La ronda 7 atribuyó el cuelgue de `zdb -O` al scrub real en curso. Con el
scrub ya terminado, `zdb -O` sigue sin poder resolver la ruta de un archivo
recién commiteado (confirmado también vía `--explain`, que reporta
`dblk=UNKNOWN`) — la causa real todavía no está identificada, y no es
contención de I/O. `zfs_hint()` sigue siendo estrictamente advisory (nunca
decide nada por su cuenta), así que esto no afecta la seguridad ni la
correctitud del worker, pero el ítem del `TEST-PLAN.md` sigue sin poder
cerrarse. Ver `docs/TEST-PLAN.md` para el detalle.

## Sin publicar — ronda 7: el resto del TEST-PLAN sin consola en vivo

Sin cambios de código: los seis frentes de esta ronda confirmaron
comportamiento correcto (uno quedó inconcluso por una causa externa ya
conocida, no por un problema del worker).

- **Hardlink → `SKIPPED`**, UID/GID de un usuario real no root preservados,
  directorio anidado profundo, y salida sin códigos ANSI al redirigir a
  archivo: los cuatro confirmados sin sorpresas.
- **Temporal `.zrw-` de OTRO job**: la corrida reveló que mi propia
  expectativa al escribir la prueba estaba mal, no el worker — el código
  (`recover_temps()`) deja un temporal ajeno completamente intacto, sin
  moverlo a cuarentena (la cuarentena es solo para huérfanos del mismo job).
  Confirmado vía `[RECOVERY] Temporal de OTRO job; no se toca` en el log.
- **Corromper el temporal antes de la verificación**: un vigía corrompió el
  temporal justo cuando rsync terminó, antes de que el worker lo leyera para
  el hash. Resultado: `FAILED` ("SHA-256 no coincide antes del commit"), sin
  commit, original bit a bit intacto.
- **`DONE` forzado a mano + modificación posterior**: `--resume` lo detectó
  (`RECOVERED`, "estado DONE no coincide con el filesystem"), reevaluó desde
  cero y reblockeó preservando el contenido modificado real, no el que el
  estado falso daba por sentado.
- **`guarded` aislado**: bajo presión real crítica del scrub, 3 eventos
  `THROTTLE` y cero eventos `INCREASE` en toda la corrida — el invariante
  "baja pero nunca sube" se sostuvo.
- **`zdb -O` post-commit** (bloques de 1M tras el reblock): inconcluso. Se
  colgó incluso con 60s de timeout, la misma contención de I/O real bajo
  scrub que ya motivó el fix de la ronda 4. Pendiente para cuando el scrub
  termine.

ACL POSIX no trivial y `atime=on` quedaron fuera de esta ronda a propósito:
el dataset real (`toolbox/media`) tiene `atime=off`, y el único
`acltype=posix` real del pool es `toolbox/.ix-virt/*` (datasets de sistema,
no aptos para pruebas). Probarlos de verdad requiere tocar una propiedad de
un dataset de producción o crear/destruir uno de laboratorio — decisión de
infraestructura, no solo escritura de archivos.

Ver `docs/testing/ronda-7-casos-limite-restantes/` para la evidencia
completa.

## Sin publicar — ronda 6: backslash literal, `--workers 2` + `STALE`, y un job real de 3h20m

Sin cambios de código: los tres frentes de esta ronda confirmaron
comportamiento correcto en vez de encontrar bugs.

- **Backslash literal en el nombre de archivo** (no solo salto de línea): el
  fix de `hash_of()` en 4.2.3 ya lo cubre sin cambios adicionales, porque
  `sha256sum` antepone la misma barra de escape en ambos casos.
- **`--workers 2` combinado con `STALE`**: sin interacción problemática. Un
  archivo mutado a mitad de camino con dos workers activos queda `STALE`
  correctamente, sin ser pisado, mientras el resto se procesa con normalidad.
- **Job real de 293 GiB / 3h23m, sin supervisión, bajo presión sostenida
  real del servidor** (el mismo scrub de fondo que motivó el hallazgo de la
  ronda 4): el governor pausó el job por su cuenta (`JOB PAUSADO`, código de
  salida 13, ya documentado en el README) en vez de forzar un disco
  saturado. Es el comportamiento diseñado funcionando correctamente bajo
  carga real, no un bug — pero confirma una expectativa operativa que vale
  la pena tener presente: un job largo con la configuración adaptativa por
  defecto puede terminar pausado, esperando un `--resume` manual, en vez de
  completarse solo. RSS del proceso estable (~5.8 MB) durante toda la
  corrida, sin señales de fuga de memoria.

Ver `docs/testing/ronda-6-backslash-workers-job-largo/` para la evidencia
completa.

## 4.2.3 — ronda 5: auditoría de `sync`/`sync -f` y dos bugs reales con nombres que tienen salto de línea

### Dos bugs reales, encontrados por la batería de nombres de archivo límite

La batería de la ronda 5 agregó un caso que ninguna ronda anterior había
probado: un archivo cuyo *nombre* contiene un salto de línea literal (algo
perfectamente válido en Linux/ZFS, aunque infrecuente). Ese caso reveló dos
bugs reales e independientes, ambos con la misma causa raíz: código que
asumía una forma fija en la salida de una herramienta externa, sin contar con
que esa herramienta cambia de forma cuando el nombre del archivo tiene un
salto de línea.

- **`hash_of()` comparaba mal el SHA-256.** GNU `sha256sum` antepone una barra
  invertida (`\`) al hash cuando el nombre necesita escaparse (por ejemplo,
  por tener un salto de línea), y en ese caso además imprime el propio salto
  de línea escapado como `\n` literal dentro del nombre — todo en una sola
  línea de salida. `hash_of()` extraía el primer campo con `awk` sin quitar
  esa barra, así que el hash quedaba con un caracter de más y la comparación
  contra el hash real fallaba siempre para estos archivos. Corregido quitando
  la barra inicial si está presente.
- **`xattr_equal()` y `acl_equal_posix()` asumían un encabezado de tamaño
  fijo.** Usaban `sed '1d'` / `sed '1,3d'` para descartar la línea `# file:
  PATH` de `getfattr` (o las tres líneas `# file:` / `# owner:` / `# group:`
  de `getfacl`), asumiendo que el encabezado siempre ocupa esa cantidad de
  líneas. Cuando el propio `PATH` contiene un salto de línea, el encabezado
  se parte en líneas adicionales y el `sed` posicional deja basura del
  encabezado mezclada con los atributos reales, o corta atributos reales por
  error. Corregido reemplazando el corte posicional por un filtro que
  reconoce positivamente la forma de una línea de atributo/entrada ACL real,
  sin importar cuántas líneas ocupó el encabezado.

En ambos casos el efecto para el operador era el mismo y era seguro: el
archivo terminaba en `FAILED` tras agotar los reintentos, el original quedaba
intacto (nunca hubo pérdida de datos), pero el archivo nunca se reblockeaba.
Cualquier archivo real cuyo nombre tuviera un salto de línea habría fallado
así, en silencio, hasta esta corrección.

Validado end-to-end: laboratorio simulado (`tests/test_integration.sh`,
escenario 26) y una corrida real contra ZFS con un archivo de nombre con
salto de línea, en el directorio de pruebas descartable, con las dos
correcciones desplegadas.

### Auditoría: ¿`sync -f` realmente sincroniza?

Se revisó cada punto del código donde el worker llama a `sync`/`sync -f`
antes de declarar algo durable (`journal()`, `save_state()`, `make_anchor()`,
`rollback()`, el `sync` posterior al commit). **No se encontró ningún bug**:
cada llamada sincroniza el archivo que efectivamente acaba de escribir, en el
orden correcto.

Dos precisiones que valía la pena dejar explícitas en el código, porque sin
ellas un auditor futuro podría sospechar de algo que en realidad está bien:

- **`sync -f PATH` no es un `fsync()` de ese archivo puntual** — es la opción
  `--file-system` de coreutils: sincroniza *todo el sistema de archivos* que
  contiene `PATH`. Más amplio de lo que el nombre sugiere, nunca más débil.
- **El rename del commit (`mv -f -- "$CUR_TMP" "$f"`) no tiene un `sync`
  explícito antes**, y es correcto que no lo tenga: en ZFS, el rename y los
  bloques de datos que referencia son parte del mismo grafo de punteros
  copy-on-write, y solo pueden confirmarse juntos, en el mismo grupo de
  transacciones. Si la máquina se cae antes de que ese TXG llegue a disco,
  ZFS vuelve al último TXG confirmado completo — el rename nunca puede
  "adelantarse" a sus propios datos. Es justamente la razón por la que
  `discover_dataset()` exige que el objetivo esté dentro de un dataset ZFS:
  en cualquier otro filesystem esa garantía no aplicaría, y ese commit sí
  necesitaría su propio `fsync` antes del rename.

## 4.2.2 — un job real encontró lo que ningún dry-run podía

Primera versión validada con un `--new-job` **real** (no simulado, no
`--dry-run`) contra copias propias de archivos de producción, dentro de un
directorio de prueba dedicado y descartable. El hallazgo llegó por accidente,
de la mejor manera posible: un scrub real, corriendo en el pool desde hacía
horas, expuso un bug que ningún laboratorio sintético podía haber mostrado.

### `zdb -O` podía colgar el job entero, sin límite de tiempo

`zfs_hint()` llama a `zdb -O` para obtener una pista advisory sobre el tamaño
de bloque real de un archivo — una pista que, por diseño explícito del
proyecto, **nunca decide nada por sí sola**. Lo que ese diseño no contemplaba
es el *tiempo*: `zdb -O` camina la metadata del pool directamente en disco, y
en un pool con un único disco físico (en el servidor de referencia, un HDD
USB) compitiendo con un scrub real leyendo 12 TB, esa lectura de metadata
puede quedar en cola detrás de la del scrub durante varios minutos.

Confirmado en vivo: con `--workers 2`, ambos workers quedaron bloqueados
**más de 7 minutos**, cada uno esperando su propia llamada a `zdb -O`, sin
que se copiara un solo byte y sin ningún mensaje de error — `--status`
seguía reportando `"running":"si"` indefinidamente. Una pista que nunca
decide nada terminaba, en la práctica, decidiendo que el job no avanzara.

**Fix**: la llamada se envuelve en `timeout 5` cuando el binario está
disponible (nuevo, `timeout` se agrega a `OPT_CMDS` y aparece en el
preflight; sin él, se degrada al comportamiento anterior). Un `zdb` colgado
ahora vuelve `UNKNOWN` a los 5 segundos en vez de bloquear indefinidamente.

### Efecto secundario del mismo bug: `--resume` fallaba con `EX_LOCKED` tras un corte real

Al interrumpir un job con `kill -9` (simulando un corte de energía) y
llamar `--resume` de inmediato, el worker rechazaba el resume: *"El job ya
está en ejecución"*, señalando un PID que **ya estaba muerto**. Causa: si el
proceso muere mientras `zdb -O` sigue bloqueado, ese `zdb` huérfano hereda el
descriptor de archivo del lock del job (`exec 200>"$LOCK_FILE"` no lo marca
`close-on-exec`, y ningún hijo forkeado por el worker lo cierra tampoco) y lo
mantiene retenido hasta que él mismo termina — que, bajo la misma contención,
puede tardar minutos. El fix del timeout resuelve esto también: confirmado
con una reproducción idéntica en el mismo servidor, bajo el mismo scrub,
`--resume` completó con código de salida 0 y SHA-256 idéntico.

### Otros hallazgos operativos de esta ronda

- **Procesos huérfanos de rondas anteriores**, algunos vivos por más de 90
  minutos: el worker ignora `SIGHUP` a propósito (para sobrevivir a un corte
  de SSH durante un job real de días), y una llamada remota envuelta en
  `timeout` local que expira antes de que el comando remoto termine mata el
  cliente SSH sin matar el proceso remoto. Limpiado; documentado como lección
  operativa para cualquier automatización futura contra este worker.
- La presión sostenida (`EMERGENCY`/`CRITICAL`) que el governor venía
  reportando desde el inicio de esta ronda tenía una causa real y legítima:
  un scrub del pool, iniciado a medianoche, con ETA de ~18 horas — no un bug
  del governor ni (solo) los procesos huérfanos. El comportamiento del
  governor (`protective_pause`, throttle progresivo) fue correcto en todo
  momento.

### Validado con datos reales en esta ronda

- Job real completo (3 archivos, integridad `maximum`): SHA-256 idéntico,
  `dblk` pasó de 128K a 1M, timestamps preservados.
- Interrupción real (`kill -9` al árbol de procesos) y `--resume`, con el fix
  desplegado: código de salida 0, SHA-256 idéntico, sin temporales huérfanos.
- `--workers 2` completo sobre 2 archivos reales en paralelo (3.20 GiB,
  8.25 MiB/s de media bajo el scrub, 6m37s), sin temporales residuales.
- `sha256` vs. `b2` cronometrado sobre un archivo real de 6.4 GB: 13.9s vs
  11.0s (con el archivo ya en caché — CPU-bound, no I/O-bound; la ganancia
  medida contra disco real en la ronda anterior fue mayor, 167 vs 482 MB/s).

Todo dentro de un único directorio de prueba, identificable, dentro de
`/mnt/toolbox/media/`, eliminado al finalizar — ningún archivo preexistente
fue modificado.

## Sin publicar — ronda 3: round-trip real contra datos de producción

Validación de escritura real (fuera del directorio origen, en directorios de prueba identificables y eliminados al terminar), sin tocar ningún archivo existente:

- **`acltype=nfsv4` (toolbox/media)**: copia real de un archivo de 6 GiB (`rsync -aAXS --no-compress`, igual que el worker) a un directorio de prueba dedicado dentro del mismo dataset. SHA-256, mode/uid/gid, xattr y ACL (`nfs4xdr_getfacl -j`) **idénticos**. Los bloques asignados (`%b`) difieren levemente por la compresión `lz4` del dataset — esperado, no es un defecto.
- **`acltype=posix` (transcode)**: primer intento incorrecto — comparó la vista `nfs4xdr_getfacl` de un archivo de origen NFSv4 contra su copia en un dataset POSIX, es decir, dos sistemas de ACL distintos que nunca iban a coincidir. Corregido: se repitió con un archivo que ya vive nativamente en ese dataset POSIX, verificado con `getfacl`/`getfattr` (las herramientas correctas para esa política). SHA-256, mode/uid/gid, ACL y xattr **idénticos**.
- **`remote/zrw-discovery.sh --probe-write` ahora verifica espacio antes de copiar** (tamaño + 20%, piso 1 GiB, el mismo margen que usa el worker) — antes copiaba sin comprobar nada.

## 4.2.1 — lo que corrió de verdad en el servidor real

4.2.0 se validó leyendo el reporte de `remote/zrw-discovery.sh`. Esta versión sale de correr el worker, sus tests y su runner por SSH **de verdad** contra el TrueNAS de referencia, en modo estrictamente de lectura (`--check`, `--dry-run`, `--explain`, y los propios bancos de tests). Nada de esto tocó un archivo del pool de medios; cada hallazgo se confirmó de forma determinística antes de tocar código.

### `pipefail` + `grep -q`: el mismo bug, dos veces

- **`zfs-reblock-worker.sh`**: el preflight avisaba *"rsync sin soporte ACL declarado"* en un rsync 3.4.1 que sí lo soporta. Causa: `rsync --version | grep -qi 'ACLs'` — bajo `pipefail`, `grep -q` cierra su extremo del pipe apenas encuentra la coincidencia, y si `rsync` todavía está escribiendo el resto de su salida (Optimizations, Checksum list, Compress list…) recibe `SIGPIPE` y sale con 141, que `pipefail` reporta como el código de la pipeline — indistinguible de "no encontrado". Confirmado 5/5 veces en el servidor de referencia. Corregido con `[[ "$(rsync --version)" == *ACLs* ]]`, que captura toda la salida antes de compararla.
- **`remote/zrw-discovery.sh`**: exactamente el mismo patrón en `sync --help 2>&1 | grep -q -- '-f'`, que alimenta `J_SYNCF` en el JSON. La propia sonda ya documentaba este bug (sección "prueba de la construcción ANTIGUA") pero el fix nunca se había portado al resto del código. Corregido igual.
- Nuevo test estático (`no_racy_grep_q`) que prohíbe `comando | grep -q` sin envolver en un subshell explícito, en todos los scripts del proyecto.

### Rutas con apóstrofe rompían el runner por SSH

`remote/zrw-remote.sh` arma cada comando remoto como un string y lo entrega a `ssh`, envolviendo `$ZRW_TARGET` en comillas simples literales. Con un directorio real que contiene un apóstrofo (por ejemplo, `O'Brien's Collection (2026)`) eso rompe la comilla y el comando ni siquiera llega a ejecutarse. Corregido con `printf '%q'` para citar cada valor antes de interpolarlo — sobrevive el viaje a través de `ssh` tanto en bash como en zsh (el shell de login de root en este TrueNAS).

### El harness de tests no corría en un host con `/tmp` en `noexec`

`tests/test_integration.sh` construye un laboratorio con `zfs`/`zdb`/etc. como scripts ejecutables bajo `mktemp -d`, que por defecto cae en `/tmp`. En el TrueNAS de referencia, `/tmp` es `tmpfs` montado `rw,nosuid,nodev,noexec` — los stubs no podían ejecutarse, bash caía en silencio a los binarios reales del sistema (sin ningún mensaje de error), y como esos binarios reales no conocen las rutas falsas del laboratorio, las 63 pruebas fallaban con `EX_NOT_ZFS`. Ningún dato real corrió peligro (el fallback tampoco podía ver datasets reales bajo las rutas falsas), pero la suite entera se ponía roja por un motivo ajeno al worker. Se agregó `pick_lab_parent()`: prueba `mktemp -d` y, si resulta no-ejecutable, cae al directorio del propio script (que por definición permite ejecutar, ya que ahí vive el binario del worker).

### Pruebas que dependían de lo que el host tuviera instalado

- **`test_units.sh`**: la prueba "servidor ocioso → HEALTHY" no estabeaba `read_psi`/`read_swap`, así que leía el `/proc/pressure` y `/proc/meminfo` **reales** del host que corre la suite. En un WSL sin PSI daba 0 por accidente; en un NAS de producción con carga real, la misma prueba fallaba — no porque el governor estuviera mal, sino porque nunca fue hermética.
- **`test_integration.sh`**, escenarios de ACL: usaban `acltype=nfsv4` para simular "este host no puede verificarlo", pero `nfs4xdr_getfacl` y `jq` vienen de fábrica en TrueNAS SCALE, así que en el servidor real ese dataset SÍ era verificable y la prueba perdía su sentido. Se reemplazó por un `acltype` inventado (siempre cae en la rama *fail-closed*, sin importar qué herramientas tenga el host) y se agregó el escenario que faltaba: un dataset `nfsv4` que SÍ es verificable debe procesarse como cualquier otro. Ese escenario nuevo reveló además un defecto de diseño en la prueba original: agregaba el dataset nfsv4 como un dataset hijo *aparte*, que quedaba excluido de todos modos por la política default `--cross-dataset=skip` — probando la exclusión equivocada.

## 4.2.0 — lo que el servidor real dijo

Esta versión no sale de una revisión de escritorio: sale de correr `remote/zrw-discovery.sh` sobre el TrueNAS de destino y leer el reporte. Dos cosas que dábamos por ciertas no lo eran, y las dos tenían consecuencias.

### ACL: capacidades, política y verificador son tres preguntas distintas

Hasta 4.1 había un único `ACL_METHOD` global, decidido en el preflight: si estaban `getfacl` y `getfattr`, valía `getfacl+getfattr`, y si no, se caía a comparar con `rsync --itemize-changes`. El reporte del servidor mostró por qué eso no alcanza: los datasets usan `acltype=nfsv4`, que `getfacl` **no sabe leer**. El preflight decía READY y después habría fallado archivo por archivo, cada uno ya copiado y hasheado.

El modelo pasa a tener tres capas, que se responden por separado:

| Capa | Pregunta | Cuándo se resuelve |
|---|---|---|
| **Capacidades** | ¿Qué sabe hacer este host? | Una vez, en el preflight |
| **Política del dataset** | ¿Qué exige este dataset? | `acltype`, del mapa de datasets |
| **Verificador efectivo** | ¿Qué corrió para *este* archivo? | Política × capacidades |

- `acltype` se lee **en la misma consulta** que `recordsize` (`zfs list -o mountpoint,name,recordsize,acltype`): es una propiedad del dataset, así que preguntarla una vez por dataset reemplaza un `zfs get` por archivo.
- `acltype=nfsv4` → `nfs4xdr_getfacl -j | jq -S -c 'del(.path,.fhandle)'`. Se excluye `fhandle` porque **tiene** que cambiar: el archivo reescrito es un inode nuevo, por diseño.
- `acltype=posix` → `getfacl` + `getfattr`. `acltype=off` → `getfattr` solo.
- **Se elimina el fallback a `rsync --itemize-changes`.** No verificaba ACL NFSv4; daba una respuesta tranquilizadora y falsa.

**Cambio de contrato: ahora se falla cerrado.** Un dataset cuya `acltype` no tiene verificador disponible en este host queda fuera **antes** de copiar nada, con el nombre de la herramienta que falta. Si ningún dataset del árbol es verificable, el worker sale con `20` (`EX_DEP_MISSING`) sin tocar un solo archivo. Antes seguía adelante con una comparación que no probaba lo que decía probar.

- `--explain` resuelve el verificador real del archivo y lo muestra (antes ni siquiera cargaba el mapa de datasets, así que respondía sobre un mundo distinto del que vería la corrida).
- `env_sane` vigila `acltype` igual que vigila `recordsize`: un `zfs set acltype=` a mitad de un trabajo de días detiene el trabajo en vez de degradar la garantía en silencio.
- El error por archivo nombra la política y el verificador (`acltype=nfsv4, verificador=nfs4xdr+jq`) en lugar de una etiqueta global que ya no significaba nada.

### La pista de `zdb` leía la columna equivocada

Se leía `lsize`, que es el **tamaño lógico del archivo**: un archivo de 2 GiB reporta 2 GiB esté en bloques de 128K o de 1M. Nunca respondía la pregunta. La columna correcta es **`dblk`**, el tamaño de bloque en disco, y se localiza por su encabezado en la salida de `zdb -O`.

- El dry-run muestra el valor (`dblk=128K`) además del veredicto, así el operador ve la evidencia y no solo nuestra conclusión.
- La comparación es **por bytes**: `1024K` y `1M` son el mismo bloque.
- Sigue siendo **solo advisory**: un hint nunca saltea un archivo, ni antes ni ahora.

### Hash

Medido en el servidor de destino: `sha256sum` 167 MB/s, `b2sum` 482 MB/s, `md5sum` 489 MB/s. En `strict` se hashea dos veces cada archivo, así que la diferencia es real.

**El default sigue siendo `sha256`**, porque es el algoritmo que documenta el contrato y el que cualquiera reconoce. Con `--bwlimit` en su valor por defecto (35M) la copia domina el reloj igual. Lo que cambia es que el preflight **avisa** cuando `b2sum` está disponible: quien corra sin límite de banda gana ~3× en las dos pasadas, con una garantía criptográfica equivalente. Un `--hash b2` y listo.

### Sonda de descubrimiento (`remote/zrw-discovery.sh`)

- **`sparse`**: se hacía `stat -c %b` inmediatamente después del `rsync`, con la escritura todavía en un grupo de transacciones sin confirmar. Ahora se sincroniza primero. Y aun así, sobre un dataset que comprime, `%b` mide compresión y no agujeros: en ese caso el resultado se reporta como **indicativo** (`sparse_preserved: null`) en vez de como veredicto.
- La sección de `zdb` valida la lectura de **`dblk`**, no el viejo regex de `lsize`, e informa el valor y el `recordsize` del dataset para poder compararlos.
- `try` usa la etiqueta que recibe; se elimina `J_STATE_FLOCK`, que nunca tuvo quien lo escribiera.

### Runner por SSH (`remote/zrw-remote.sh`)

- **El filtro de `rsync` nunca copiaba `remote/`.** Como `discover` corre `remote/zrw-discovery.sh` en el NAS, ese modo fallaba siempre que `rsync` estuviera disponible — que es el caso normal. Solo funcionaba por el camino de respaldo con `scp`. Ahora se copia, y `stage` verifica que llegó en vez de fallar tres pasos después con un "No such file".
- `die` imprimía `"$*"`, así que el código de salida quedaba pegado al final de cada mensaje de error (`... zrw-remote.conf. 2`).
- **Tolerancia a CRLF en el `.conf`.** Ese archivo se edita desde Windows, y un CRLF ahí es veneno silencioso: `ZRW_ALLOW_WRITE` vale `no<CR>`, que no es `no`, y cada ruta arrastra un retorno de carro. Se descartan los CR al leerlo, con aviso.
- Nuevos `ZRW_HASH` y `ZRW_WORKERS`.
- **Nuevo `remote/zrw-env.sh`.** El reporte de entorno era un one-liner incrustado en el runner, y necesitaba tres niveles de escapado de comillas para sobrevivir el viaje por SSH. Ese escapado escondía un filtro `awk` equivocado: solo consideraba datasets montados **bajo** el objetivo, cuando el caso habitual es el contrario — el objetivo es un subdirectorio común del dataset que lo contiene, así que la tabla salía vacía. Ahora es un script propio, se lee, y usa la misma relación que el worker. Lista las herramientas de verificación una por una y tabula `recordsize`, `acltype`, `compression`, `xattr` y `atime`.
- `all` cierra con un **resumen que traduce el código de salida** de cada etapa (`20` → "falta una dependencia crítica, o ningún dataset es verificable").
- **`ZRW_SSH_BIN` / `ZRW_SCP_BIN`.** Desde Git Bash, el `ssh` de MSYS aplica reglas de permisos POSIX a una llave guardada en un disco NTFS, donde esos bits no significan nada, y la rechaza. El OpenSSH de Windows lee la ACL de NTFS y acepta la misma llave. Poder nombrar el binario convierte "primero copiá tu llave privada al home de WSL" en una opción y no en un requisito.
- Por la misma razón, el aviso de permisos de la llave ya no se emite cuando la ruta es de un disco de Windows: ahí sería ruido.
- `status` existía y no figuraba en la ayuda.

### `job_stats`

- Las columnas del journal se localizan **por nombre**, desde su propia fila de encabezado, en lugar de por posición (`cut -f1`/`-f2`). Un trabajo lo escribe la versión del worker que lo corrió, que no es necesariamente esta.
- Un journal que solo tiene su encabezado ya no reporta la palabra literal `timestamp` como última actividad.
- Se eliminan las tres sustituciones de proceso: los conteos salen de una pasada de `awk` y de `wc -l`, y un directorio ausente da cero en vez de dejar el contador donde estaba.

### Resumen y reportes

- `summary.tsv` / `summary.json`: `acl_method` (etiqueta global, ya sin sentido) pasa a **`acl_policy`**, la `acltype` de cada dataset del árbol, más `datasets_acl_verifiable` / `datasets_acl_unverifiable` y `datasets_recordsize_ok` / `datasets_recordsize_other`.
- Nuevo `paused_for_space`. Una pausa por disco lleno ya no se reporta como una pausa cualquiera: el banner dice cuánto queda libre y que hay que liberar espacio **antes** de reanudar, porque reanudar sin hacerlo vuelve a chocar contra el mismo archivo.
- `survey_tree` cuenta también el dataset propio del objetivo. Apuntar el worker a un subdirectorio común reportaba cero datasets en el árbol.

### Pruebas

- El banco de integración levanta stubs de `getfacl`/`getfattr` y su `zfs list` publica cuatro columnas, como la consulta real.
- Escenarios nuevos: un dataset `nfsv4` sin `nfs4xdr_getfacl` (sus archivos quedan fuera del inventario y **no se tocan**), y un árbol entero sin verificador (sale con `20` sin copiar nada).
- Los tests unitarios de `zdb` pasan a fijar `dblk`, e incluyen la matriz completa de capacidades × `acltype` × verificador.
- El banco estático corre `bash -n` y `shellcheck` también sobre `remote/*.sh`: se envían y se ejecutan en el servidor, así que un error de sintaxis ahí es tan fatal como en el worker.
- `shellcheck -S warning` queda limpio en todo el proyecto. Las variables que denunciaba (`TREE_RS_OK`, `TREE_RS_BAD`, `SPACE_PAUSE`, `D_HASH`) no se silenciaron: se calculaban y se tiraban, y ahora se reportan.

### Corregido

- 19 cadenas de formato de `printf` donde un `\n` literal se había convertido en un salto de línea real, dejando el argumento en la línea siguiente. Funcionaban, pero el bloque del dry-run era ilegible justo donde hay que poder modificarlo rápido.


## 4.1.0 — consciente del pool, y legible a las 3 de la mañana

### ZFS: un path no es un filesystem

Un directorio como `/mnt/toolbox` puede abarcar datasets hijos, otros pools, montajes no ZFS y directorios `.zfs`, cada uno con su propio `recordsize` y su propio espacio libre. Tratar todo el árbol como "el dataset del directorio de arriba" significa comprobar el recordsize equivocado y el espacio equivocado para la mayoría de los archivos. Eso es un defecto de diseño nuestro, no un error del operador.

- **Mapa de datasets** construido una vez y consultado por *cada* archivo (longest-prefix sobre `zfs list`).
- El `recordsize` se verifica contra **el dataset que realmente contiene el archivo**.
- El espacio libre se mide sobre ese mismo dataset.
- **`.zfs` nunca se recorre** (`-prune` en el propio `find`).
- Archivos en datasets no aptos quedan **fuera del inventario**, con el motivo en el resumen — no entran para después fallar.
- `--cross-dataset skip|process|stop` y `--one-dataset` para fijar la política.
- `survey_tree` informa, **antes de tocar un byte**, cuántos datasets abarca el árbol y cuáles se van a omitir.

### Color para el ojo humano

- Paleta aplicada a prefijos de log (`[OK]` verde, `[FAILED]` rojo, `[STALE]` amarillo, `[AUTO]` azul, `[RECOVERY]` cian…), al estado del servidor y a las barras de progreso.
- El color **nunca es la única señal**: cada uno lleva su palabra, así que un terminal monocromo no pierde nada.
- **El log en disco siempre es texto plano**, sin ANSI.
- `--no-color` y `NO_COLOR=1`.

### Integridad

- **El default pasa a `strict`.** `maximum` sigue disponible, pero ahora **avisa en stdout** que relee cada archivo completo tras el commit (~+33 % de I/O de lectura) y lo dice también en la documentación.
- **`--hash sha256|b2|md5`.** `b2` (BLAKE2b, `b2sum` de coreutils) es criptográfico *y* más rápido que MD5: es la mejor opción si el SHA-256 domina el reloj. `md5` queda como tercera opción, y el worker avisa explícitamente de que detecta corrupción accidental pero **no resiste manipulación deliberada**.

### Governor

- **PSI** (`/proc/pressure/{io,cpu,memory}`): fracción de los últimos 10 s en que alguna tarea estuvo bloqueada esperando ese recurso. Es lo más parecido que hay a "¿cuánto estoy molestando a este servidor?", y pesa como el almacenamiento.
- **Swap** en uso como señal tardía pero inequívoca.
- El baseline aprende también el PSI y lo usa como referencia de desviación.

### Control e interfaz

- **Menú de decisión ante `STALE`** (revalidar / omitir / actualizar inventario / no preguntar más). `--stale-policy auto|ask|skip|retry|refresh`; `auto` pregunta solo en terminal y omite si está desatendido.
- **Menú de condiciones de parada** en caliente: hasta completar, tras este archivo, tras N archivos, o a una hora.
- **Cambio de perfil en caliente** (la idea DAY/NIGHT), que no levanta un techo manual ya impuesto.
- **Panel de recuperación detallado** al reanudar: última actividad, último evento, progreso con barra, y qué requiere recuperación (archivos en vuelo, temporales, anclas).
- **Puntero al trabajo actual**: `--resume` y `--retry-*` ya no exigen recordar el job id.
- **Journal completo** de cada cambio del operador y de cada bloqueo de AUTO.

### Dry-run

- Clasifica **"posiblemente ya en el recordsize objetivo"** vs. **"necesitan reblock"**, siempre marcado como pista advisory de `zdb`.
- Reporta los archivos excluidos por dataset.
- **`--estimate`**: la estimación de duración y la comparativa entre límites de BW dejan de salir por defecto; el operador decide. `--quiet` y `--ui json` nunca la imprimen como texto.

### Corregido

- `local a=x b="${a}"`: bash expande todas las palabras del `local` antes de asignar ninguna, así que `b` veía `a` sin definir. Corregido y con un escaneo en el propio repositorio para que no vuelva.

## 4.0.0 — reescritura consolidada

Reescritura completa del worker incorporando lo mejor de los seis entregables previos, las mejoras que faltaban del documento de diseño y una auditoría de código propia. El detalle línea a línea está en [`docs/AUDIT-CODE.md`](docs/AUDIT-CODE.md).

### Adoptado del legacy (v3.3 / v3.4)

- **Ancla de rollback por hardlink.** El commit deja de ser una puerta de ida: un hardlink al inode original mantiene los datos previos alcanzables, con coste de espacio cero, hasta que la verificación post-commit pasa. Si falla, el reemplazo va a cuarentena y el original vuelve a su nombre.
- **`sync -f` sobre estado y journal**, para que el checkpoint sobreviva a un corte de energía y no solo a una salida ordenada.
- **Verificación de ACL/xattr post-commit contra el ancla**, que todavía conserva los metadatos del original.
- **`PENDING` explícito para todo el inventario**: "pendientes" pasa a ser un hecho contado, no una resta.
- **Parseo endurecido de `zdb`**: solo cuenta un campo `lsize`/`logical size` explícito.
- **Re-hash del origen tras la copia**, que detecta cambios de contenido que preservan tamaño y mtime.

### Corregido respecto del legacy

- v3.3 y v3.4 **abortan en el primer archivo** (`orig_sha: unbound variable`). Ninguna versión previa llegó a procesar un archivo.
- El ancla de rollback de v3.4 no se recupera nunca: un corte durante el commit deja el original con `nlink=2` y el worker lo marca `SKIPPED` para siempre. `recover_anchors` compara inodes y completa o descarta el rollback según corresponda.
- v3.3/v3.4 mantienen el `IFS` global que deja `CPU` e `IOWAIT` en 0: su governor solo reacciona a load y memoria.
- v3, v3.2, v3.3 y v3.4 no tienen `trap`: Ctrl+C dejaba temporales y anclas en el árbol de datos.
- `zdb` con hint `1M` volvía a producir `SKIP` en v3.4, contradiciendo su propio `FINAL-ASSURANCE.md`.

### Agregado

- **Presión de disco en el health score** desde `/proc/diskstats`: utilización y latencia media, por encima de CPU y memoria. Un pool saturado por un scrub ya no se ve como "servidor saludable".
- **Nivel `EMERGENCY`** por encima de `CRITICAL`.
- **BW inicial recomendado por el baseline**, en vez de asumir siempre 35M.
- **`--workers N`**: paralelismo real con claim atómico entre workers y reparto del BW para respetar el techo del operador en total. Default 1.
- **`--adaptive-priority on`**: `nice`/`ionice` gobernados por el estado del servidor, con el valor del operador como cota agresiva.
- **Modos de salida `--ui auto|dash|plain|quiet|json`**, `--log-file`, e inmunidad a `SIGHUP` para operación por SSH.
- **`--dry-sample N`**: lee N candidatos completos (solo lectura) y mide el throughput real del pool.
- **Impacto estimado antes de aplicar un cambio de BW**, y etiquetas `Applies: NEXT FILE / JOB / INVENTORY` en el panel de control.
- **Lock informativo**: PID, hora de inicio y target del worker que lo tiene.
- **`--status --json`** y cuarentena pre-analizada (tamaño y SHA-256 de cada elemento).
- **11 exit codes semánticos**, documentados en `--help`.
- **`remote/`**: runner por SSH de solo lectura por defecto, con la configuración fuera del repositorio.

### Calidad

- Comentarios íntegramente en inglés, explicando el porqué; comprobado por el test estático.
- 20 secciones numeradas con índice en la cabecera.
- Bancos de prueba: 37 comprobaciones estáticas, 60 asserts unitarios y 41 de integración end-to-end, todos ejecutados en Linux real.

## 3.3.0 — Laboratory Candidate

Primera versión que arranca, está completa y se ejecutó de punta a punta. Consolida la V3.1 (la más completa pero rota) con el endurecimiento que prometía la V3.2 (sintácticamente correcta pero regresiva), y cierra los pendientes que el diseño había dejado abiertos. El detalle está en [`docs/AUDIT-V3.md`](docs/AUDIT-V3.md).

### Corregido

- **El script ahora ejecuta.** La V3.1 tenía `process_one()` truncado y no pasaba `bash -n`.
- **El governor vuelve a funcionar.** El ancho de banda se manejaba como `"36700160B"`, un formato que ni `rsync` acepta ni el propio parser puede releer: tras el primer ajuste el governor quedaba congelado. Ahora se trabaja en bytes/s y se formatea a KiB solo al invocar `rsync`.
- **El health score ya no es ciego.** `read` sobre `/proc/stat` con el `IFS` global (que no incluye espacio) nunca separaba la línea: `CPU_UTIL` e `IOWAIT` quedaban siempre en 0.
- **La invariante de `atime` ya no falla siempre.** El hash del temporal se calculaba después de restaurar los timestamps, y esa lectura volvía a alterar el atime. Se reordenó el pipeline: primero los hashes, después la restauración, después la verificación.
- **El atime del origen se restaura tras leerlo** para hashearlo, de modo que un `FAILED` o `STALE` no deje el original alterado.
- **La recuperación ya no puede secuestrar el temporal de otro job.**

### Agregado

- Estado `RECOVERED` y regla explícita de que **el checkpoint no es la autoridad**: un `DONE` o `SKIPPED` solo se acepta si el archivo sigue coincidiendo con lo registrado.
- Falta de espacio **pausa el lote** en lugar de marcar cientos de archivos como `FAILED`.
- Niveles de integridad `standard` / `strict` / `maximum` (default `maximum`).
- `--retry-stale` para revalidar archivos modificados después del inventario.
- `--explain PATH`: explica por qué un archivo sería o no procesado y con qué garantías.
- `--check`: preflight del sistema sin tocar ningún archivo.
- Wizard consciente del estado: detecta el trabajo previo, su progreso y sus temporales huérfanos antes de ofrecer opciones.
- Explorador de directorios con `whiptail`, `dialog` y `fzf`, con informe de disponibilidad en el preflight y selector Bash siempre presente como fallback.
- Verificación de ACL/xattr con `getfacl`/`getfattr` cuando existen, y `rsync --itemize-changes` como fallback. El método usado queda registrado en el resumen.
- Inventario snapshot publicado atómicamente.
- Job ID con nanosegundos y PID además de fecha y hash.
- Temporales marcados con el token del job; los ajenos se reportan y no se tocan.
- Journal estructurado separado del log humano.
- `--status` filtrable por directorio, con progreso y recuento de estados.
- Códigos de salida documentados (0 / 1 / 2 / 3).
- Banco de pruebas ejecutable: estático, unitario e **integración completa** con ZFS simulado.

### Observabilidad

El capítulo del diseño que ninguna entrega anterior había implementado.

- **Doble progreso**: por archivos y por bytes. 98/238 no significa lo mismo si un archivo pesa 2 GiB y otro 80 GiB.
- **ETA global** a partir de la velocidad media real del job, más velocidad media acumulada y tiempo transcurrido.
- **Línea de estado**: qué está haciendo ahora mismo (inspección ZFS, SHA-256, reescribiendo, verificando, commit, sync, cooldown).
- **Últimos 5 archivos completados**, con tamaño, velocidad y duración.
- **Cuenta regresiva del cooldown**, para que la pantalla no parezca colgada durante el `sleep`.
- **Modo en la cabecera**: `NEW` / `RESUME` / `RETRY-FAILED` / `RETRY-STALE`.
- **Contador de avisos** visible, y `warn()` que además los registra en `events.log`.
- **Desglose de motivos** (hardlink, cambiado, desaparecido, sin espacio) en pantalla, en TSV y en JSON.
- **Resumen final** con datos reescritos, velocidad media, tiempo, avisos, recuperaciones, estado del sistema y el comando exacto para lo que quede pendiente.

### Control operativo

- `--cooldown-mode adaptive`: la pausa entre archivos sigue al estado del servidor. `fixed` (el comportamiento del V2) sigue siendo el default.
- `--stop-after N` y `--stop-at HH:MM`: ventanas de mantenimiento sin supervisión. La parada ocurre entre archivos, nunca a mitad de una copia.
- **Health check del entorno antes de cada archivo**: si el dataset desaparece, cambia o le cambian el recordsize durante la ejecución, el worker se detiene de forma segura en lugar de seguir a ciegas.
- **Perfiles leídos de `examples/profiles.conf`**, para que sean los valores del usuario y no los que el worker presuma sobre su hardware. El wizard puede guardar la configuración actual como perfil.
- **El wizard recuerda el último directorio** utilizado, pero nunca lo selecciona en silencio: siempre hay que confirmarlo.

### Empaquetado

- Guarda contra CRLF en los tests: un script Bash con finales de línea de Windows no arranca en TrueNAS (`bad interpreter`).

### Restaurado desde la V3.1

Funcionalidad que la V3.2 había perdido: configuración persistente por job, journal, verificación de ACL/xattr, recuperación de estados interrumpidos, perfiles, `--status`, explorador de directorios, validación de opciones, `--refresh-inventory` y escape JSON.

---

## 3.2 — no publicable

Anunciada como endurecimiento de la V3.1, pero construida sobre el esqueleto V3: sintácticamente correcta y con varias mejoras reales, aunque perdiendo buena parte de la funcionalidad de la V3.1.

## 3.1 — no ejecutable

La más completa en features. El archivo entregado está truncado dentro de `process_one()` y no pasa `bash -n`.

## 3.0 — esqueleto

Arquitectura y documentación del V3, con la implementación todavía incompleta.

## 2.0 — base

Script original. Detección previa por `zdb`, `flock`, I/O limitado, `renice`/`ionice`, preservación `-aAX`, verificación de tamaño y reemplazo por temporal. Es la base conceptual de todo lo demás, y sus defaults siguen siendo los defaults del V3.

---

# English

## 4.4.14 — the governor stops confusing "disk busy being useful" with "disk suffering"

Redesign of `health_sample()`, based on three points that had been left
noted as "improvement candidates" after round 16 (local, unpublished hardware analysis)
and external research on how mature systems solve the same problem
(Envoy/Netflix adaptive concurrency limiters, and TCP BBR itself — see
sources in the analysis).

### 1. `--adaptive off` now measures, even though it does not act

Before, `governor_step()` cut off **before** calling `health_sample()`
when `ADAPTIVE=off` — the dashboard's "SERVER" panel stayed frozen at
`UNKNOWN`/`0`, not because the server was fine, but because the worker
had stopped looking. Now it always measures; the cutoff moved to after
`health_sample()`, so `off` keeps meaning exactly what it always meant
(zero automatic `THROTTLE`/`INCREASE`/protective pause, absolute operator
authority) — this only restores real visibility into what the disk is
doing while that choice is in effect.

### 2. "Goodput" credit: productive saturation vs. a stuck disk

The underlying finding from round 16: an isolated `fio` saturated the
same single USB disk at a real, sustained 150+ MiB/s, and
`health_sample()` read it as `EMERGENCY` (score 14) the whole time,
because `%util`/PSI alone cannot distinguish "busy delivering real
bytes" from "busy and stuck" — the same problem TCP BBR and adaptive
concurrency limiters (Envoy, Netflix) solve: they measure what is
actually being achieved, not just how "busy" the resource is.

Now, if the file currently being copied has been in progress for at
least 5 seconds and its real speed (`GOODPUT_BPS`, measured with the
same counters that already feed the dashboard) reaches or exceeds
`--bw-min`, a fixed credit (3 points) is subtracted from `HEALTH_SCORE`
before deciding the level — it can never *invent* pressure that the
other signals did not see, it can only soften it when there is real
evidence the disk is still delivering. Verified with round 16's exact
score (14, with `DISK_UTIL=100 DISK_WAIT=60 PSI_IO=85`): with the credit
it drops to 11 — still severe if the pressure is genuine, but it stopped
penalizing a disk that performs the same as one that does not.

The absolute thresholds, `THROTTLE`, the protective pause, and no
integrity guarantee were touched — the fix lives entirely inside
`health_sample()`, before anything else reads its result.

Sources that confirmed the direction of the design:
[Adaptive Concurrency (Envoy)](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/adaptive_concurrency_filter),
[Adaptive request concurrency (Vector/Netflix)](https://vector.dev/blog/adaptive-request-concurrency/),
[BBR, the new kid on the TCP block (APNIC)](https://blog.apnic.net/2017/05/09/bbr-new-kid-tcp-block/).

## 4.4.13 — a `--resume` without `--bwlimit` could start from the default, not from the saved job

Note left unresolved in 4.4.12, closed now: `validate()` calculated
`BW_BPS` (the real effective bandwidth) from `BW_TARGET` **before** job
resolution and `load_config()` ran — so a `--resume` without an explicit
`--bwlimit` always started from the compiled default (35M), never from
what the job actually had saved. Harmless under `adaptive=auto` (the
governor corrects it within seconds), but silent and real under
`--adaptive off`: nothing was going to correct it back to the fixed rate
the operator had chosen.

### Fix

The calculation was split into its own function, `finalize_bw()`, moved
to after `load_config()`/`CLI_SET` had already resolved the final
`BW_TARGET` — an explicit flag still wins, and a `--resume` without flags
now does take the job's saved value, not the default. Validated with a
unit test that reproduces the scenario (job saved with `BW_TARGET=20M`,
resume without `--bwlimit`, final `BW_BPS` must be the 20M one, not the
35M one).

Investigated in parallel: the correct order (`defaults < config <
explicit flags`) matches the standard configuration precedence practice
in command-line tools — confirming the fix's direction was correct, not
just an ad-hoc correction.

## 4.4.12 — an explicit flag on `--resume` was not really applied

Found live, while trying to measure the disk's real performance:
`--resume --adaptive off --bwlimit 80M` kept throttling for pressure as
if `--adaptive off` had never been passed — the log showed `THROTTLE`
and `PAUSA PROTECTIVA` just as always.

### Root cause

`load_config()` did a plain `source` of `config.env` on every
`--resume`. That overwrote **any** field the operator had just passed on
the command line with the value saved when the job was created — in
this case, `ADAPTIVE=auto` (the original value) got written back over
the `ADAPTIVE=off` that `parse_args` had just set, only a few lines of
code later. The same problem reached, in theory, any other persisted
field: `--bw-min`, `--bw-max`, `--integrity`, `--cooldown`, `--workers`,
etc.

### Fix

New `CLI_SET`: a record of which fields this invocation explicitly
touched. `load_config()` now skips those fields when reading
`config.env` — a flag passed on `--resume` wins; a field not mentioned
keeps coming from the saved job, exactly as before. Covered by a unit
test that reproduces the exact scenario (an `--adaptive off` that must
win, a `COOLDOWN` not passed that must keep coming from the file).

### Note, still unresolved

`validate()` (which calculates the effective initial `BW` from
`BW_TARGET`) runs *before* job resolution and `load_config()`. On a
`--resume` without an explicit `--bwlimit`, that means the starting `BW`
comes from the compiled default (35M), not from what the job had
saved — harmless in practice because the adaptive governor corrects it
on its own within the first seconds, but a real inconsistency that
stays noted for review in another round, not resolved here so as not to
mix it with the `CLI_SET` fix.

## 4.4.11 — early warning when the dataset lives on a USB disk

After confirming live (`Series` rounds) that a single, non-redundant USB
disk has a sustained write ceiling much lower than its nominal speed —
and that the governor only discovers it the hard way, probing and
backing off several times before settling near the real number.

### What changes

New `usb_advisory()` function: resolves the physical disk(s) behind the
target dataset's pool (via `zpool status -PL` + `lsblk -no pkname`) and,
if any of them hang off `/sys/.../usb.../`, warns once when starting a
new job (and in `--dry-run`) suggesting measuring with `--dry-run
--dry-sample` and setting `--bwlimit`/`--bw-max` near the real number
instead of letting the governor find it on its own. Purely informative:
it does not change `BW`, does not touch the verification hash, the
atomic commit, or the governor logic — none of the worker's safety
guarantees move because of this. If `lsblk` is not installed, it is a
silent no-op, as befits any optional signal in the worker.

## 4.4.10 — the governor oscillated: recover, raise, back to CRITICAL, every file

Found live, running `Series` already with the 4.4.8 memory fix applied:
memory pressure dropped (18-19%, healthy), but the protective-pause
pattern continued — almost every other file.

### Root cause

ZFS syncs dirty data on a ~5s cycle (`zfs_txg_timeout`), and on a slow
single disk that periodic sync is bursty enough to look like real
pressure every time it happens — the "picket fence" pattern, documented
by the OpenZFS project itself. The governor, as soon as it saw a
`HEALTHY` sample (even the very first one right after a protective
pause resolved), raised BW immediately — and that raise overshot
exactly in time for the sync's next burst, triggering CRITICAL again.
The cycle repeated on almost every file: recover, raise, CRITICAL,
pause, recover, raise...

### Fix

New `LAST_CRIT_TS` variable, updated every time a sample comes back
CRITICAL or EMERGENCY. As long as at least `HEALTH_INTERVAL*3` seconds
have not passed since the last one, a `HEALTHY` reading keeps BW where
it is (`HOLD`, with reason "cooldown after recent pressure") instead of
raising it — giving it a couple more sync cycles to settle before
trusting that "healthy" means healthy. `THROTTLE` and the protective
pause itself do not change: the brake against real danger stays
immediate, this only holds back the "accelerator" after a recent
crisis.

## 4.4.9 — a resumed job showed the version it was created with, not the one running

Found while reviewing the 4.4.8 fix live: after uploading the binary and
resuming a job created with the previous version, the dashboard,
`--status`, and every log line kept saying "v4.4.7" — even though the
code actually running was already 4.4.8.

### Root cause

`save_config()` wrote `VERSION=<version>` into `config.env`, and
`load_config()` does a direct `source` of that file on every
`--resume`. A field literally named `VERSION` overwrote the running
binary's constant with whatever the file said — without affecting any
real behavior (`$VERSION` is only used for display, never to decide
anything), but leaving false information in everything an operator
looks at to know which version is really running.

### Fix

The field is renamed to `JOB_VERSION` — a historical record of which
version the job was created with, which no longer overwrites the live
`$VERSION`. Existing jobs, created before this fix, will keep showing
the old version until they close (their `config.env` is not rewritten
on every resume) — purely cosmetic, with no effect whatsoever on the
real work.

## 4.4.8 — ZFS's ARC was counted as "used" memory, inflating pressure

Found live, running `Series` on real production: the dashboard showed
`mem 92%` with CPU, iowait, and disk practically at zero, and the
governor still added pressure points for that reading — pausing jobs
before there was any real disk or CPU pressure.

### Root cause

`read_cpu_mem()` calculated "used" memory as `100 -
(MemAvailable*100/MemTotal)`. On Linux, `MemAvailable` does not know
ZFS's ARC is reclaimable — the ARC lives outside the kernel's normal
page-cache accounting, so a perfectly healthy host with the ARC near its
ceiling (up to 95.7% of RAM, by design) reads as if that memory were
really committed. Confirmed live: ARC at ~20 GiB out of 23.5 GiB total,
`MemAvailable` showing only ~2 GiB free — 92% "used" feeding
`health_score` with no real pressure whatsoever.

### Fix

`read_cpu_mem()` now gives the calculation back what the ARC could yield
without trouble: `current ARC size` minus its own configured floor
(`c_min`), read from `/proc/spl/kstat/zfs/arcstats` (a path configurable
via `ARCSTATS_FILE`/`ZRW_ARCSTATS_FILE`, so the unit test can point it
at a fixture). If the file does not exist (a host without ZFS, an
exotic install), it is a silent no-op and `MEM` falls back to the
previous calculation unchanged. Verified live against the reference NAS:
the same moment that used to read `92%` now reads `14%` — without
touching any other part of the governor.

## 4.4.7 — `Ctrl+C` did not terminate the process, only the current question

Found live, testing the wizard's directory explorer: a `Ctrl+C` did not
exit the program — it skipped to the next question. It took one
`Ctrl+C` per remaining wizard question, and the last one (profile, with
an empty answer) ended in a validation error instead of a clean exit.

### Root cause

`trap cleanup EXIT INT TERM` registered the same handler for all three
signals, and `cleanup()` never called `exit`. A trap only replaces a
signal's *default* action — it does not make the process terminate on
its own. Without an explicit `exit`, after cleaning up, execution simply
continued right after whatever had been interrupted (the `read` for the
question in progress). The same trap covers a real copy in progress: an
operator trying to abort a hung job with `Ctrl+C` would have run into
the same problem.

### Correction

`trap cleanup EXIT` separated from `trap 'exit 130' INT` / `trap 'exit
143' TERM` (128+signal, the standard convention). That explicit `exit`
is what actually terminates the process, and by doing so it re-triggers
the `EXIT` trap, so `cleanup()` still runs exactly once, without
duplicating. Covered by a static check that prevents the old pattern
from being reintroduced.

## 4.4.6 — color in the dashboard, second pass (governor, manual authority, status)

After seeing 4.4.5 live: "it can be improved further, without making it
illegible." Designed around what an operator needs to notice while
staring at the screen for hours, not around "coloring everything":

- **`autoridad MANUAL`** on the BW line: magenta (the same color as
  `[OPERATOR]` in the log) — a reminder that a manual ceiling is set,
  easy to forget during a long run.
- **`Governor`**: `THROTTLE`=yellow (it's taking bandwidth away from
  you), `INCREASE`=green (it's giving it back), `HOLD`=dim (nothing
  happening, does not compete for attention).
- **`Estado`** (what the current file is doing): yellow if
  paused/waiting, dim for the deliberate cooldown between files, cyan
  for the commit instant (the only irreversible moment) — no color for
  the rest, which is the common case ("working normally").

Same care as in 4.4.5: fixed-width fields (`Governor %-9s`) are padded
first and colored afterward, so ANSI bytes never enter the alignment
calculation.

## 4.4.5 — color in the dashboard, reusing the palette that already existed

During the live console session: help the eye find the data in the
dashboard. Investigated before touching anything: a complete color
infrastructure already existed (`set_palette()`, `NO_COLOR`/`--no-color`/TTY
detection, and `paint()`, a colorizer for `[TAG]` labels in the log) —
but `paint()` only runs in `plain` mode, never in the live dashboard
(`log()` does not print anything line by line in `dash` mode, by
design). The dashboard itself only used color for its borders.

Two new, reusable pieces:
- **`cfield COLOR WIDTH VAL [FORCE]`** — colors a fixed-width numeric
  field without breaking alignment: first fills the plain text to the
  requested width, and only afterward wraps it in color from the
  outside — invisible ANSI bytes never enter a printf `%-Ns` width
  calculation (which is exactly what would break it if the value were
  colored *inside* the field). By default it does not color a value of
  `0` (a row at zero asking for attention is worse than one that does
  not); `FORCE=1` for cases that must always be colored.
- **`chealth ESTADO`** — maps `HEALTHY/BUSY/PRESSURE/CRITICAL/EMERGENCY/
  UNKNOWN` to the same color language `paint()` already uses for
  `CRITICAL` in the log, instead of inventing a parallel palette.

Applied to: the dashboard's counter line (Reescritos=green,
Fallidos=red if>0, Stale=yellow if>0, Omitidos/Ausentes=dim), the server
health line (color per real state), and the final summary title (`JOB
COMPLETADO`=green, yellow if there were failures or it stayed paused,
red if it stopped due to an environment change). Verified that the
visible width (without ANSI codes) stays exact even with color on, and
that a value of `0` is indeed left uncolored.

`cfield()`/`chealth()` remain as generic pieces for the next time
something else in the dashboard needs coloring, without repeating this
analysis.

## 4.4.4 — `[C]` changing recordsize/threshold could abort the running job

Found in the same live console session, testing section I: changing
`recordsize`/`threshold` from `[C]` (options 8/9, meant for "the next
job") ended up aborting the **current**, real, in-progress job, with
`[ERROR] El recordsize cambio durante la ejecucion` — even though the
dataset's real recordsize never changed.

### Root cause

`env_sane()` (the safety check that runs before every file) compared
the dataset's real recordsize against `$EXPECTED_RECORDSIZE` — the same
global variable that `[C]` option 8 mutates. The dashboard and the
closing summary had the same problem, showing the "for the next job"
value as if it were the current job's. All three were reading a
variable meant for two distinct purposes at once.

### Correction

New `RUN_RECORDSIZE`/`RUN_THRESHOLD` variables, frozen once as soon as
the job's configuration is resolved (creation or `--resume`), unaffected
by later changes via `[C]`. `env_sane()`, the dashboard header, and the
closing summary now use them instead of the variables `[C]` can still
freely mutate for the next job. Covered by a unit test that reproduces
the exact mechanism.

## 4.4.2 — live console session: the operator's keyboard competed with the inventory for stdin

Found live, pressing `[Q]` during a real copy: a file from the inventory
(never touched, always intact on disk) ended up marked `MISSING` with an
empty path in the journal — without ever having disappeared.

### Root cause

`run_loop()` reads the inventory with `while read line; do ... done
<"$INVENTORY"` — without specifying a descriptor, that read uses
**stdin (fd 0)**. `poll_keys()`, which handles `[P]`/`[Q]`/`[C]`/`[S]`
and is called from much deeper in that same call chain
(`process_one` → `run_rsync` → `poll_keys`, once per second while
copying), **also** reads from stdin, without its own descriptor. The two
ended up competing for the same source: every keystroke poll during a
copy silently consumed a byte of whatever came next in the inventory.
With multi-minute copies and once-per-second polls, that was enough to
completely corrupt the line of a later file — losing its path, never its
content (the original is never touched until the commit is verified).

### Correction

`run_loop()` now reads the inventory through descriptor 3
(`done 3<"$INVENTORY"`, `read -u 3`), leaving stdin completely free for
`poll_keys()`. Covered by a unit test that reproduces the exact
mechanism (simulated, aggressive keyboard polling during the read of a
5-line inventory) and fails reproducibly against the previous code.

## 4.4.1 — round 12: a real machine reboot, and an orphan `recover_temps()` never saw

A real machine reboot (`/sbin/reboot`) triggered mid-copy of a real 6
GiB file, in the dedicated test directory. The pool re-imported clean,
with no errors; the saved state (`PROCESSING`) reverted to `PENDING`
exactly as the contract documents; `--resume` rewrote the entire file,
hash identical to the original.

### Real bug found: rsync's partial temp file was never recovered

When the outage hits while `rsync` is still transferring (not
afterward, once it has already renamed its working file to the final
`.tmp` name), what's left on disk is rsync's own working name: the
worker's `.tmp` plus the six-character random suffix `rsync` prepends
while transferring (`.zrw-<job>-<token>.tmp.XXXXXX`). `recover_temps()`'s
glob looked for exactly `.zrw-*.tmp` — without the suffix, that file
never showed up. `--status` did count it (it uses a broader glob), so
the operator would see "1 temp file in the tree" forever, with
automatic recovery never touching it or quarantining it — violating
contract invariant #8 ("never promoted nor deleted, goes to
quarantine"). Fixed by widening the glob to `.zrw-*.tmp*`. Covered by a
new unit test that reproduces the exact shape of the real name found on
the NAS. Manually cleaned up the 1.24 GiB orphan file left over from the
original finding.

See `docs/testing/ronda-12-reinicio-real/` for the full evidence.

## Unreleased — round 11: first real run against production (`Musicales`)

No code changes. First time the worker ran on real production files, in
place (not a disposable copy), on `Musicales` (14.33 GiB, 199 files,
none in use). Only 1 file exceeded the default threshold and qualified
as a candidate; it was rewritten with 0 failures, `mtime` preserved
exactly (original date from 2007, not the run's date), identical NFSv4
ACL, and `zdb -O` confirming `dblk=1M`. All 199 files verified at the
end (size/mtime/hash identical to the initial inventory). Closes the
first three items of section J of `TEST-PLAN.md`; only "the full
dataset" remains, pending the operator's decision.

Two of our own mistakes (not the worker's), documented without
sugarcoating in `docs/testing/ronda-11-produccion-musicales/README.md`:
an unquoted `for` broke the automatic ACL comparison (fixed by hand
afterward, on the real file), and the script's cleanup deleted a paused
job's state before it could be closed with an explicit `--resume` (no
real consequence: there was no genuine pending work, and integrity had
already been verified independently).

## Unreleased — round 10: `--auto-resume` confirmed against real pressure, and `zrw-deep-observe.sh`

No code changes in `zfs-reblock-worker.sh`. Two new things:

- **`--auto-resume` validated against real pressure** (synthetic load
  with `fio`): paused at 35s of real `EMERGENCY`, stayed alive waiting,
  resumed on its own once the load was cut (40s / 3m19s depending on the
  file), finished with exit code 0 without ever invoking `--resume`.
  Identical SHA-256 on both files. Closes the only item still pending
  for `--auto-resume` in `docs/TEST-PLAN.md`.
- **`remote/zrw-deep-observe.sh`**: new, read-only tool, built entirely
  on `/proc` (no `strace`, not installed on the reference NAS and not
  installed on our own initiative). Subcommands `tree`, `io`, `fds`,
  `mem`, `cgroup`, `disk`, `snapshot`, `watch`. Verified against the
  real worker from this same round: process tree, real per-process I/O,
  open descriptors resolved to their exact path, memory, cgroup,
  `iostat`/`zpool iostat`. It is the foundation for
  [Live Console Protocol](https://github.com/hnacimiento/zfs-reblock-worker/wiki/Live-Console-Protocol) (the protocol for closing section I
  and the `[C]` cycle of H, which need a real interactive console) and
  for the design scheduled for `zrw-witness.sh` (see below).

See `docs/testing/ronda-10-auto-resume-carga-sintetica/` for the full
evidence.

## Scheduled pending item — `zrw-witness.sh` (observability companion)

**Do not build yet.** Full design in [Witness Design](https://github.com/hnacimiento/zfs-reblock-worker/wiki/Witness-Design): a
parallel, read-only tool that attaches by process name + PID to a
running `zfs-reblock-worker.sh` and produces structured evidence (live
visual + reproducible JSONL) of what happens at the system level — built
on `/proc`, evolving `remote/zrw-deep-observe.sh` (round 10) with PID
auto-discovery, correlation with `events.log`/`journal.tsv`, automatic
triggers on known events, and an anomaly-detection layer based on the
real findings from rounds 1-10. Resume once work on the main worker
(including the live console round, [Live Console Protocol](https://github.com/hnacimiento/zfs-reblock-worker/wiki/Live-Console-Protocol)) is
considered closed.

## Unreleased — round 9: root cause of `zdb -O`, idle governor, and closing POSIX ACL/`atime`

No code changes: the four fronts of this round closed investigation and
verification, not bugs.

- **`zdb -O` on freshly written files**: root cause found. It was not
  the scrub (round 7) — `zdb -O` reads the pool's on-disk labels, which
  only get updated on the next TXG sync cycle (`zfs_txg_timeout`, 5s by
  default). A freshly committed file is invisible to `zdb -O` for
  ~5-10s after its `sync`, confirmed with a staggered-delay test. With
  the right wait, `zdb -O` confirms `dblk=1M` on a real, freshly
  reblocked file — closing the original `TEST-PLAN.md` item.
  `zfs_hint()` remains advisory-only, unchanged: waiting out that cycle
  before every hint would be a bad tradeoff.
- **Governor with a genuinely idle server**: confirmed it climbs
  cleanly up to `--bw-max` (4 `INCREASE` events, 0 `THROTTLE`, exact
  final BW 80.0M). The first attempt was contaminated by the test setup's
  own load (generating the test files with `/dev/urandom` triggered
  real pressure that the baseline captured) — fixed by generating with
  `/dev/zero` and explicitly waiting for the system to settle before
  measuring.
- **Non-trivial POSIX ACL, xattr, and real `atime=on`**: closed using
  `zrw-lab-dataset.sh` against a disposable dataset (`acltype=posix
  atime=on`). Confirmed that dataset really has `atime=on` in effect
  (reading changes the atime) and that the worker restores it exactly
  despite that; identical ACL and xattr before/after.

Deliberately not touched in this round: `--auto-resume` against real
pressure, because validating it now would require generating synthetic
load on purpose against the production pool — it remains pending
explicit authorization.

See `docs/testing/ronda-9-hash-cascade-lab-dataset-governor-ocioso/` for
the full evidence.

## New tool — `remote/zrw-lab-dataset.sh`

Helper script, to be run by hand on the NAS, that creates and destroys a
disposable lab dataset (`--parent POOL --acltype posix|nfsv4 --atime
on|off`), to be able to close the two `docs/TEST-PLAN.md` items that
could not be tested on `toolbox/media` without touching production:
non-trivial POSIX ACL (the pool's only real `acltype=posix` datasets are
system ones) and `atime=on` (the real dataset has `atime=off`). It never
runs on its own — it is a tool for the operator to use when deciding to
close those two items. `destroy` only accepts names starting with
`zrw-lab` (a fixed safety floor, independent of what the operator typed
into `create`) and asks for confirmation by typing the full dataset
name, unless `--yes` is passed. Verified with a full real cycle
(`create` → `status` → `destroy`) against `toolbox`: creates with the
requested properties, confirms via `zfs list`, destroys cleanly.

## 4.4.0 — BLAKE2b as default, cascading to BLAKE3 and SHA-256

**Default behavior change.** The hash used to verify integrity switches
from `sha256` to `b2` (BLAKE2b, via GNU coreutils' `b2sum`). This is not
a security downgrade: BLAKE2b (RFC 7693) is a cryptographic hash with the
same collision/preimage-resistance guarantee as SHA-256 for the purpose
of this contract (detecting any difference between the source and the
temp file, whether accidental or deliberate), and it also avoids
SHA-256's weakness to length-extension. Measured on the reference NAS:
482 MB/s vs. 167 MB/s — nearly 3x faster across the two hash passes
`--integrity strict`/`maximum` performs on every file.

Selection now falls back in a cascade: **`b2` → `b3` (BLAKE3) →
`sha256`**, each step used only if the previous one is unavailable on
the host. `sha256sum` remains a critical dependency (the worker does not
start without it), so the cascade can never end up with no floor.
`--hash b3` also exists as an explicit option. `b3sum` is not yet
installed on the reference NAS; the logic and controls are already
implemented and tested (static/unit/integration), but the real output
format of `b3sum` still needs to be confirmed once it is installed — a
pending item in `docs/TEST-PLAN.md`, section D.

`--hash md5` still exists unchanged, for when the only thing available
is detecting accidental corruption, not deliberate tampering.

## 4.3.0 — `--auto-resume` and clarity improvements, from the opportunities of rounds 5-7

### `--auto-resume` (opt-in): the protective pause no longer has to end the process

Until now, when the governor detected sustained critical pressure and
triggered the "protective pause" (rounds 6 and 7), the worker exited
with code `13` and waited for a manual `--resume` — even if pressure
dropped a minute later. `TEST-PLAN.md` itself described "automatic
resumption once freed" as the expected behavior, and that was not what
the code did.

With `--auto-resume`, when the governor triggers a protective pause
(and **only** for that cause — a `[P]`/`[Q]` from the operator or a full
disk still stop the job for real, without exception) the worker waits
within the same process, resampling server health, and resumes on its
own as soon as it sees sustained health again — without exiting, without
needing `--resume`. It is bounded by `--pause-timeout MIN` (120 by
default): if pressure never yields, it gives up and exits exactly as
before, so it never hangs silently. The default behavior (without this
flag) does not change at all.

Validated with 5 deterministic unit tests (without waiting real time):
pressure that yields leaves the job running on its own, without
`PAUSE_REQ`; pressure that never yields gives up all the same with
`--pause-timeout=0`. Not yet confirmed against real server pressure —
the scrub that sustained pressure in rounds 5-7 finished before that
test could be run; it remains pending for the next time there is real
sustained load (or synthetic load, if generating it on purpose is
decided).

### Clarity in `--status`: an active temp file no longer reads as "leftover"

While a job is actively copying, its own in-progress temp file matched
the same `.zrw-*` pattern as a real orphan, and `--status` showed them
the same way ("residuos .zrw-* en el arbol"), even though one is
perfectly normal and the other indicates something to review. Now,
while the job is still `en ejecucion`, the text clarifies it could be
the active temp file, not necessarily a leftover. The JSON's
`orphan_temps` field did not change name or meaning, so as not to break
anything already consuming it.

### Correcting a misattributed root cause (`zdb -O`)

Round 7 attributed `zdb -O` hanging to the real scrub in progress. With
the scrub already finished, `zdb -O` still cannot resolve the path of a
freshly committed file (also confirmed via `--explain`, which reports
`dblk=UNKNOWN`) — the real cause is still not identified, and it is not
I/O contention. `zfs_hint()` remains strictly advisory (never decides
anything on its own), so this does not affect the worker's safety or
correctness, but the `TEST-PLAN.md` item still cannot be closed. See
`docs/TEST-PLAN.md` for details.

## Unreleased — round 7: the rest of the TEST-PLAN without a live console

No code changes: the six fronts of this round confirmed correct
behavior (one was left inconclusive due to an already-known external
cause, not a worker problem).

- **Hardlink → `SKIPPED`**, UID/GID of a real non-root user preserved,
  deep nested directory, and output without ANSI codes when redirected
  to a file: all four confirmed with no surprises.
- **Temp `.zrw-` file from ANOTHER job**: the run revealed that my own
  expectation when writing the test was wrong, not the worker — the
  code (`recover_temps()`) leaves a foreign temp file completely intact,
  without moving it to quarantine (quarantine is only for orphans from
  the same job). Confirmed via `[RECOVERY] Temporal de OTRO job; no se
  toca` in the log.
- **Corrupting the temp file before verification**: a watcher corrupted
  the temp file right when rsync finished, before the worker read it for
  the hash. Result: `FAILED` ("SHA-256 no coincide antes del commit"),
  no commit, original bit-for-bit intact.
- **`DONE` forced by hand + later modification**: `--resume` detected it
  (`RECOVERED`, "estado DONE no coincide con el filesystem"), re-evaluated
  from scratch, and reblocked while preserving the real modified content,
  not what the false state assumed.
- **Isolated `guarded`**: under real critical scrub pressure, 3
  `THROTTLE` events and zero `INCREASE` events across the whole run —
  the "goes down but never up" invariant held.
- **Post-commit `zdb -O`** (1M blocks after the reblock): inconclusive.
  It hung even with a 60s timeout, the same real I/O contention under
  scrub that already motivated round 4's fix. Pending for when the
  scrub finishes.

Non-trivial POSIX ACL and `atime=on` were deliberately left out of this
round: the real dataset (`toolbox/media`) has `atime=off`, and the
pool's only real `acltype=posix` is `toolbox/.ix-virt/*` (system
datasets, not fit for testing). Testing them for real requires touching
a production dataset's property or creating/destroying a lab one — an
infrastructure decision, not just writing files.

See `docs/testing/ronda-7-casos-limite-restantes/` for the full
evidence.

## Unreleased — round 6: literal backslash, `--workers 2` + `STALE`, and a real 3h20m job

No code changes: the three fronts of this round confirmed correct
behavior rather than finding bugs.

- **Literal backslash in a filename** (not just a newline): the
  `hash_of()` fix in 4.2.3 already covers this without additional
  changes, because `sha256sum` prepends the same escape slash in both
  cases.
- **`--workers 2` combined with `STALE`**: no problematic interaction. A
  file mutated midway with two active workers correctly ends up
  `STALE`, without being overwritten, while the rest is processed
  normally.
- **Real 293 GiB / 3h23m job, unsupervised, under real sustained server
  pressure** (the same background scrub that motivated round 4's
  finding): the governor paused the job on its own (`JOB PAUSADO`, exit
  code 13, already documented in the README) instead of forcing a
  saturated disk. This is the designed behavior working correctly under
  real load, not a bug — but it confirms an operational expectation
  worth keeping in mind: a long job with the default adaptive
  configuration can end up paused, waiting for a manual `--resume`,
  instead of completing on its own. Process RSS stable (~5.8 MB)
  throughout the whole run, with no signs of a memory leak.

See `docs/testing/ronda-6-backslash-workers-job-largo/` for the full
evidence.

## 4.2.3 — round 5: audit of `sync`/`sync -f` and two real bugs with newline filenames

### Two real bugs, found by the edge-case filename battery

Round 5's battery added a case no previous round had tested: a file
whose *name* contains a literal newline (something perfectly valid on
Linux/ZFS, though rare). That case revealed two real, independent bugs,
both with the same root cause: code that assumed a fixed shape in an
external tool's output, without accounting for that tool changing shape
when the filename has a newline.

- **`hash_of()` compared SHA-256 incorrectly.** GNU `sha256sum` prepends
  a backslash (`\`) to the hash when the name needs escaping (for
  example, for having a newline), and in that case it also prints the
  newline itself escaped as a literal `\n` inside the name — all on a
  single output line. `hash_of()` extracted the first field with `awk`
  without stripping that slash, so the hash ended up with one extra
  character and the comparison against the real hash always failed for
  these files. Fixed by stripping the leading slash if present.
- **`xattr_equal()` and `acl_equal_posix()` assumed a fixed-size
  header.** They used `sed '1d'` / `sed '1,3d'` to discard the `# file:
  PATH` line from `getfattr` (or the three lines `# file:` / `# owner:`
  / `# group:` from `getfacl`), assuming the header always takes up
  that many lines. When `PATH` itself contains a newline, the header
  splits across additional lines and the positional `sed` leaves header
  junk mixed in with the real attributes, or cuts real attributes by
  mistake. Fixed by replacing the positional cut with a filter that
  positively recognizes the shape of a real attribute/ACL-entry line,
  regardless of how many lines the header took up.

In both cases the effect for the operator was the same and was safe:
the file ended up `FAILED` after exhausting retries, the original stayed
intact (no data was ever lost), but the file was never reblocked. Any
real file whose name had a newline would have failed this way, silently,
until this fix.

Validated end-to-end: simulated lab (`tests/test_integration.sh`,
scenario 26) and a real run against ZFS with a newline-named file, in
the disposable test directory, with both fixes deployed.

### Audit: does `sync -f` really sync?

Every point in the code where the worker calls `sync`/`sync -f` before
declaring something durable was reviewed (`journal()`, `save_state()`,
`make_anchor()`, `rollback()`, the `sync` after the commit). **No bug
was found**: every call syncs the file it actually just wrote, in the
correct order.

Two clarifications worth making explicit in the code, because without
them a future auditor might suspect something that is actually fine:

- **`sync -f PATH` is not an `fsync()` of that specific file** — it is
  coreutils' `--file-system` option: it syncs *the entire filesystem*
  that contains `PATH`. Broader than the name suggests, never weaker.
- **The commit's rename (`mv -f -- "$CUR_TMP" "$f"`) has no explicit
  `sync` before it**, and it is correct that it does not: on ZFS, the
  rename and the data blocks it references are part of the same
  copy-on-write pointer graph, and can only be committed together, in
  the same transaction group. If the machine crashes before that TXG
  reaches disk, ZFS reverts to the last fully committed TXG — the
  rename can never "get ahead" of its own data. This is exactly why
  `discover_dataset()` requires the target to be inside a ZFS dataset:
  on any other filesystem that guarantee would not apply, and that
  commit would need its own `fsync` before the rename.

## 4.2.2 — a real job found what no dry-run could

First version validated with a **real** `--new-job` (not simulated, not
`--dry-run`) against our own copies of production files, inside a
dedicated, disposable test directory. The finding arrived by accident,
in the best possible way: a real scrub, running on the pool for hours,
exposed a bug no synthetic lab could have shown.

### `zdb -O` could hang the entire job, with no time limit

`zfs_hint()` calls `zdb -O` to get an advisory hint about a file's real
block size — a hint that, by the project's explicit design, **never
decides anything on its own**. What that design did not account for was
*time*: `zdb -O` walks the pool's metadata directly on disk, and on a
pool with a single physical disk (on the reference server, a USB HDD)
competing with a real scrub reading 12 TB, that metadata read can end up
queued behind the scrub's for several minutes.

Confirmed live: with `--workers 2`, both workers ended up blocked **for
more than 7 minutes**, each waiting on its own `zdb -O` call, without a
single byte being copied and without any error message — `--status`
kept reporting `"running":"si"` indefinitely. A hint that never decides
anything ended up, in practice, deciding the job made no progress.

**Fix**: the call is wrapped in `timeout 5` when the binary is
available (new, `timeout` is added to `OPT_CMDS` and appears in the
preflight; without it, it degrades to the previous behavior). A hung
`zdb` now returns `UNKNOWN` after 5 seconds instead of blocking
indefinitely.

### Side effect of the same bug: `--resume` failed with `EX_LOCKED` after a real outage

When interrupting a job with `kill -9` (simulating a power outage) and
calling `--resume` right away, the worker rejected the resume: *"El job
ya está en ejecución"*, pointing at a PID that was **already dead**.
Cause: if the process dies while `zdb -O` is still blocked, that orphan
`zdb` inherits the job lock's file descriptor (`exec
200>"$LOCK_FILE"` does not mark it `close-on-exec`, and no child forked
by the worker closes it either) and keeps holding it until it itself
finishes — which, under the same contention, can take minutes. The
timeout fix resolves this too: confirmed with an identical reproduction
on the same server, under the same scrub, `--resume` completed with
exit code 0 and identical SHA-256.

### Other operational findings from this round

- **Orphan processes from previous rounds**, some alive for more than 90
  minutes: the worker ignores `SIGHUP` on purpose (to survive an SSH
  disconnect during a real multi-day job), and a remote call wrapped in
  a local `timeout` that expires before the remote command finishes
  kills the SSH client without killing the remote process. Cleaned up;
  documented as an operational lesson for any future automation against
  this worker.
- The sustained pressure (`EMERGENCY`/`CRITICAL`) the governor had been
  reporting since the start of this round had a real, legitimate cause:
  a pool scrub, started at midnight, with an ETA of ~18 hours — not a
  governor bug nor (only) the orphan processes. The governor's behavior
  (`protective_pause`, progressive throttle) was correct the whole time.

### Validated with real data in this round

- Full real job (3 files, `maximum` integrity): identical SHA-256,
  `dblk` went from 128K to 1M, timestamps preserved.
- Real interruption (`kill -9` on the process tree) and `--resume`, with
  the fix deployed: exit code 0, identical SHA-256, no orphan temp files.
- Full `--workers 2` on 2 real files in parallel (3.20 GiB, 8.25 MiB/s
  average under the scrub, 6m37s), no leftover temp files.
- `sha256` vs. `b2` timed on a real 6.4 GB file: 13.9s vs. 11.0s (with
  the file already cached — CPU-bound, not I/O-bound; the gain measured
  against real disk in the previous round was larger, 167 vs. 482
  MB/s).

All within a single, identifiable test directory inside
`/mnt/toolbox/media/`, removed when finished — no pre-existing file was
modified.

## Unreleased — round 3: real round-trip against production data

Real write validation (outside the source directory, in identifiable
test directories removed when finished), without touching any existing
file:

- **`acltype=nfsv4` (toolbox/media)**: real copy of a 6 GiB file
  (`rsync -aAXS --no-compress`, same as the worker) to a dedicated test
  directory inside the same dataset. SHA-256, mode/uid/gid, xattr, and
  ACL (`nfs4xdr_getfacl -j`) **identical**. Allocated blocks (`%b`)
  differ slightly due to the dataset's `lz4` compression — expected,
  not a defect.
- **`acltype=posix` (transcode)**: first attempt was incorrect — it
  compared the `nfs4xdr_getfacl` view of an NFSv4 source file against
  its copy on a POSIX dataset, i.e. two different ACL systems that were
  never going to match. Fixed: repeated with a file that already lives
  natively on that POSIX dataset, verified with `getfacl`/`getfattr`
  (the correct tools for that policy). SHA-256, mode/uid/gid, ACL, and
  xattr **identical**.
- **`remote/zrw-discovery.sh --probe-write` now checks space before
  copying** (size + 20%, 1 GiB floor, the same margin the worker uses)
  — before it copied without checking anything.

## 4.2.1 — what actually ran on the real server

4.2.0 was validated by reading `remote/zrw-discovery.sh`'s report. This
version comes from running the worker, its tests, and its SSH runner
**for real** against the reference TrueNAS, in strictly read-only mode
(`--check`, `--dry-run`, `--explain`, and the test suites themselves).
None of this touched a single file in the media pool; every finding was
confirmed deterministically before touching code.

### `pipefail` + `grep -q`: the same bug, twice

- **`zfs-reblock-worker.sh`**: the preflight warned *"rsync sin soporte
  ACL declarado"* on an rsync 3.4.1 that does support it. Cause: `rsync
  --version | grep -qi 'ACLs'` — under `pipefail`, `grep -q` closes its
  end of the pipe as soon as it finds the match, and if `rsync` is
  still writing the rest of its output (Optimizations, Checksum list,
  Compress list…) it receives `SIGPIPE` and exits with 141, which
  `pipefail` reports as the pipeline's code — indistinguishable from
  "not found." Confirmed 5/5 times on the reference server. Fixed with
  `[[ "$(rsync --version)" == *ACLs* ]]`, which captures the whole
  output before comparing it.
- **`remote/zrw-discovery.sh`**: exactly the same pattern in `sync
  --help 2>&1 | grep -q -- '-f'`, which feeds `J_SYNCF` in the JSON. The
  probe itself already documented this bug (section "test of the OLD
  build") but the fix had never been ported to the rest of the code.
  Fixed the same way.
- New static test (`no_racy_grep_q`) that forbids `command | grep -q`
  without wrapping it in an explicit subshell, across every script in
  the project.

### Paths with an apostrophe broke the SSH runner

`remote/zrw-remote.sh` builds each remote command as a string and hands
it to `ssh`, wrapping `$ZRW_TARGET` in literal single quotes. With a
real directory containing an apostrophe (e.g. `O'Brien's Collection (2026)`) that breaks
the quoting and the command does not even get to run. Fixed with
`printf '%q'` to quote each value before interpolating it — it survives
the trip through `ssh` in both bash and zsh (root's login shell on this
TrueNAS).

### The test harness did not run on a host with `/tmp` mounted `noexec`

`tests/test_integration.sh` builds a lab with `zfs`/`zdb`/etc. as
executable scripts under `mktemp -d`, which defaults to `/tmp`. On the
reference TrueNAS, `/tmp` is `tmpfs` mounted `rw,nosuid,nodev,noexec` —
the stubs could not execute, bash silently fell back to the system's
real binaries (with no error message at all), and since those real
binaries do not know the lab's fake paths, all 63 tests failed with
`EX_NOT_ZFS`. No real data was ever at risk (the fallback also could not
see real datasets under the fake paths), but the whole suite went red
for a reason unrelated to the worker. Added `pick_lab_parent()`: it
tries `mktemp -d` and, if that turns out non-executable, falls back to
the script's own directory (which, by definition, allows execution,
since that is where the worker's binary lives).

### Tests that depended on what the host happened to have installed

- **`test_units.sh`**: the "idle server → HEALTHY" test did not stub
  `read_psi`/`read_swap`, so it read the **real** `/proc/pressure` and
  `/proc/meminfo` of the host running the suite. On a WSL without PSI it
  gave 0 by accident; on a production NAS with real load, the same test
  failed — not because the governor was wrong, but because it was never
  hermetic.
- **`test_integration.sh`**, ACL scenarios: they used `acltype=nfsv4` to
  simulate "this host cannot verify it," but `nfs4xdr_getfacl` and `jq`
  ship out of the box on TrueNAS SCALE, so on the real server that
  dataset actually WAS verifiable and the test lost its point. It was
  replaced with a made-up `acltype` (always falls into the *fail-closed*
  branch, regardless of what tools the host has), and the missing
  scenario was added: an `nfsv4` dataset that IS verifiable must be
  processed like any other. That new scenario also revealed a design
  flaw in the original test: it added the nfsv4 dataset as a *separate*
  child dataset, which was excluded anyway by the default
  `--cross-dataset=skip` policy — testing the wrong exclusion.

## 4.2.0 — what the real server said

This version does not come from a desk review: it comes from running
`remote/zrw-discovery.sh` against the destination TrueNAS and reading
the report. Two things we took for granted were not true, and both had
consequences.

### ACL: capabilities, policy, and verifier are three distinct questions

Up through 4.1 there was a single global `ACL_METHOD`, decided in the
preflight: if `getfacl` and `getfattr` were present, it was
`getfacl+getfattr`, and if not, it fell back to comparing with `rsync
--itemize-changes`. The server's report showed why that is not enough:
the datasets use `acltype=nfsv4`, which `getfacl` **does not know how
to read**. The preflight said READY and would then have failed file by
file, each one already copied and hashed.

The model now has three layers, answered separately:

| Layer | Question | When it's resolved |
|---|---|---|
| **Capabilities** | What does this host know how to do? | Once, in the preflight |
| **Dataset policy** | What does this dataset require? | `acltype`, from the dataset map |
| **Effective verifier** | What ran for *this* file? | Policy × capabilities |

- `acltype` is read **in the same query** as `recordsize` (`zfs list -o
  mountpoint,name,recordsize,acltype`): it is a dataset property, so
  asking once per dataset replaces one `zfs get` per file.
- `acltype=nfsv4` → `nfs4xdr_getfacl -j | jq -S -c
  'del(.path,.fhandle)'`. `fhandle` is excluded because it **has** to
  change: the rewritten file is a new inode, by design.
- `acltype=posix` → `getfacl` + `getfattr`. `acltype=off` → `getfattr`
  only.
- **The fallback to `rsync --itemize-changes` is removed.** It did not
  verify NFSv4 ACLs; it gave a reassuring, false answer.

**Contract change: it now fails closed.** A dataset whose `acltype` has
no verifier available on this host is excluded **before** copying
anything, naming the missing tool. If no dataset in the tree is
verifiable, the worker exits with `20` (`EX_DEP_MISSING`) without
touching a single file. Before, it went ahead with a comparison that
did not prove what it claimed to prove.

- `--explain` resolves the file's real verifier and shows it (before it
  did not even load the dataset map, so it answered about a different
  world than the run would see).
- `env_sane` watches `acltype` the same way it watches `recordsize`: a
  `zfs set acltype=` mid-way through a multi-day job stops the job
  instead of silently degrading the guarantee.
- The per-file error names the policy and the verifier
  (`acltype=nfsv4, verificador=nfs4xdr+jq`) instead of a global label
  that no longer meant anything.

### The `zdb` hint read the wrong column

It read `lsize`, which is the file's **logical size**: a 2 GiB file
reports 2 GiB whether it's in 128K or 1M blocks. It never answered the
question. The correct column is **`dblk`**, the on-disk block size, and
it is located by its header in `zdb -O`'s output.

- The dry-run shows the value (`dblk=128K`) in addition to the verdict,
  so the operator sees the evidence, not just our conclusion.
- The comparison is **by bytes**: `1024K` and `1M` are the same block.
- It remains **advisory only**: a hint never skips a file, neither
  before nor now.

### Hash

Measured on the destination server: `sha256sum` 167 MB/s, `b2sum` 482
MB/s, `md5sum` 489 MB/s. Under `strict`, every file is hashed twice, so
the difference is real.

**The default remains `sha256`**, because it is the algorithm the
contract documents and the one everyone recognizes. With `--bwlimit` at
its default (35M), the copy dominates the clock regardless. What
changes is that the preflight **warns** when `b2sum` is available:
anyone running without a bandwidth limit gains ~3× on the two hash
passes, with an equivalent cryptographic guarantee. A `--hash b2` and
done.

### Discovery probe (`remote/zrw-discovery.sh`)

- **`sparse`**: `stat -c %b` was run immediately after `rsync`, with the
  write still in an unconfirmed transaction group. Now it syncs first.
  And even so, on a compressing dataset, `%b` measures compression, not
  holes: in that case the result is reported as **indicative**
  (`sparse_preserved: null`) instead of a verdict.
- The `zdb` section validates reading **`dblk`**, not the old `lsize`
  regex, and reports the value and the dataset's `recordsize` so they
  can be compared.
- `try` uses the label it receives; `J_STATE_FLOCK`, which never had
  anyone write it, is removed.

### SSH runner (`remote/zrw-remote.sh`)

- **The `rsync` filter never copied `remote/`.** Since `discover` runs
  `remote/zrw-discovery.sh` on the NAS, that mode always failed
  whenever `rsync` was available — the normal case. It only worked
  through the `scp` fallback path. Now it is copied, and `stage`
  verifies it arrived instead of failing three steps later with a "No
  such file."
- `die` printed `"$*"`, so the exit code ended up stuck at the end of
  every error message (`... zrw-remote.conf. 2`).
- **CRLF tolerance in the `.conf`.** That file is edited from Windows,
  and a CRLF there is silent poison: `ZRW_ALLOW_WRITE` becomes `no<CR>`,
  which is not `no`, and every path drags along a carriage return. CRs
  are stripped on read, with a warning.
- New `ZRW_HASH` and `ZRW_WORKERS`.
- **New `remote/zrw-env.sh`.** The environment report used to be a
  one-liner embedded in the runner, needing three levels of quote
  escaping to survive the trip over SSH. That escaping hid a wrong
  `awk` filter: it only considered datasets mounted **under** the
  target, when the usual case is the opposite — the target is a common
  subdirectory of the dataset that contains it, so the table came out
  empty. It is now its own script, readable, using the same
  relationship the worker uses. It lists verification tools one by one
  and tabulates `recordsize`, `acltype`, `compression`, `xattr`, and
  `atime`.
- `all` closes with a **summary that translates each stage's exit
  code** (`20` → "a critical dependency is missing, or no dataset is
  verifiable").
- **`ZRW_SSH_BIN` / `ZRW_SCP_BIN`.** From Git Bash, MSYS's `ssh` applies
  POSIX permission rules to a key stored on an NTFS disk, where those
  bits mean nothing, and rejects it. Windows' OpenSSH reads the NTFS
  ACL and accepts the same key. Being able to name the binary turns
  "first copy your private key into the WSL home" into an option
  instead of a requirement.
- For the same reason, the key permissions warning is no longer emitted
  when the path is on a Windows disk — there it would be noise.
- `status` existed and was missing from the help text.

### `job_stats`

- Journal columns are located **by name**, from their own header row,
  instead of by position (`cut -f1`/`-f2`). A job is written by whatever
  worker version ran it, which is not necessarily this one.
- A journal that only has its header no longer reports the literal word
  `timestamp` as the last activity.
- The three process substitutions are removed: counts come from a
  single `awk` pass and `wc -l`, and a missing directory gives zero
  instead of leaving the counter where it was.

### Summary and reports

- `summary.tsv` / `summary.json`: `acl_method` (a global label, already
  meaningless) becomes **`acl_policy`**, the `acltype` of each dataset
  in the tree, plus `datasets_acl_verifiable` /
  `datasets_acl_unverifiable` and `datasets_recordsize_ok` /
  `datasets_recordsize_other`.
- New `paused_for_space`. A pause due to a full disk is no longer
  reported like any other pause: the banner says how much space is left
  free and that space must be freed **before** resuming, because
  resuming without doing so just hits the same file again.
- `survey_tree` also counts the target's own dataset. Pointing the
  worker at a common subdirectory used to report zero datasets in the
  tree.

### Tests

- The integration bank sets up `getfacl`/`getfattr` stubs and its `zfs
  list` publishes four columns, like the real query.
- New scenarios: an `nfsv4` dataset without `nfs4xdr_getfacl` (its files
  stay out of the inventory and **are not touched**), and an entire tree
  with no verifier (exits with `20` without copying anything).
- The `zdb` unit tests now fix `dblk`, and include the full matrix of
  capabilities × `acltype` × verifier.
- The static bank runs `bash -n` and `shellcheck` on `remote/*.sh` too:
  they get sent and run on the server, so a syntax error there is as
  fatal as one in the worker.
- `shellcheck -S warning` is clean across the whole project. The
  variables it flagged (`TREE_RS_OK`, `TREE_RS_BAD`, `SPACE_PAUSE`,
  `D_HASH`) were not silenced: they were being computed and thrown
  away, and now they are reported.

### Fixed

- 19 `printf` format strings where a literal `\n` had turned into a real
  line break, leaving the argument on the following line. They worked,
  but the dry-run block was unreadable exactly where it needs to be
  quick to modify.


## 4.1.0 — pool-aware, and readable at 3 in the morning

### ZFS: a path is not a filesystem

A directory like `/mnt/toolbox` can span child datasets, other pools,
non-ZFS mounts, and `.zfs` directories, each with its own `recordsize`
and its own free space. Treating the whole tree as "the top-level
directory's dataset" means checking the wrong recordsize and the wrong
space for most files. That is a design flaw of ours, not an operator
mistake.

- **Dataset map** built once and queried for *every* file
  (longest-prefix over `zfs list`).
- `recordsize` is checked against **the dataset that actually contains
  the file**.
- Free space is measured on that same dataset.
- **`.zfs` is never traversed** (`-prune` in `find` itself).
- Files in unfit datasets stay **out of the inventory**, with the
  reason in the summary — they do not go in only to fail later.
- `--cross-dataset skip|process|stop` and `--one-dataset` to set the
  policy.
- `survey_tree` reports, **before touching a single byte**, how many
  datasets the tree spans and which ones will be skipped.

### Color for the human eye

- Palette applied to log prefixes (`[OK]` green, `[FAILED]` red,
  `[STALE]` yellow, `[AUTO]` blue, `[RECOVERY]` cyan…), to server
  status, and to progress bars.
- Color is **never the only signal**: each one carries its word, so a
  monochrome terminal loses nothing.
- **The log on disk is always plain text**, without ANSI.
- `--no-color` and `NO_COLOR=1`.

### Integrity

- **The default becomes `strict`.** `maximum` remains available, but
  now **warns on stdout** that it rereads every full file after the
  commit (~+33% read I/O), and it is also stated in the documentation.
- **`--hash sha256|b2|md5`.** `b2` (BLAKE2b, coreutils' `b2sum`) is
  cryptographic *and* faster than MD5: it is the best option if SHA-256
  dominates the clock. `md5` remains a third option, and the worker
  explicitly warns that it detects accidental corruption but **does not
  resist deliberate tampering**.

### Governor

- **PSI** (`/proc/pressure/{io,cpu,memory}`): the fraction of the last
  10 s some task was blocked waiting for that resource. It's the
  closest thing to "how much am I bothering this server?", and it
  weighs as much as storage.
- **Swap** in use as a late but unambiguous signal.
- The baseline also learns PSI and uses it as a deviation reference.

### Control and interface

- **Decision menu on `STALE`** (revalidate / skip / update inventory /
  stop asking). `--stale-policy auto|ask|skip|retry|refresh`; `auto`
  only asks in a terminal and skips when unattended.
- **Hot stop-condition menu**: until completion, after this file, after
  N files, or at a given time.
- **Hot profile switching** (the DAY/NIGHT idea), which does not raise
  an already-imposed manual ceiling.
- **Detailed recovery panel** on resume: last activity, last event,
  progress bar, and what requires recovery (in-flight files, temp
  files, anchors).
- **Pointer to the current job**: `--resume` and `--retry-*` no longer
  require remembering the job id.
- **Complete journal** of every operator change and every AUTO lock.

### Dry-run

- Classifies **"possibly already at the target recordsize"** vs.
  **"needs reblocking"**, always marked as an advisory `zdb` hint.
- Reports files excluded per dataset.
- **`--estimate`**: duration estimation and the BW-limit comparison no
  longer print by default; the operator decides. `--quiet` and `--ui
  json` never print it as text.

### Fixed

- `local a=x b="${a}"`: bash expands every word of the `local` before
  assigning any of them, so `b` saw `a` as undefined. Fixed, with a scan
  added to the repository itself so it does not come back.

## 4.0.0 — consolidated rewrite

Complete rewrite of the worker incorporating the best of the six
previous deliverables, the improvements the design document was still
missing, and our own code audit. The line-by-line detail is in
[`docs/AUDIT-CODE.md`](docs/AUDIT-CODE.md).

### Adopted from the legacy code (v3.3 / v3.4)

- **Rollback anchor via hardlink.** The commit stops being a one-way
  door: a hardlink to the original inode keeps the previous data
  reachable, at zero space cost, until post-commit verification passes.
  If it fails, the replacement goes to quarantine and the original
  gets its name back.
- **`sync -f` on state and journal**, so the checkpoint survives a power
  outage and not just an orderly exit.
- **Post-commit ACL/xattr verification against the anchor**, which
  still holds the original's metadata.
- **Explicit `PENDING` for the whole inventory**: "pending" becomes a
  counted fact, not a subtraction.
- **Hardened `zdb` parsing**: it only counts an explicit `lsize`/"logical
  size" field.
- **Re-hashing the source after the copy**, which detects content
  changes that preserve size and mtime.

### Fixed relative to the legacy code

- v3.3 and v3.4 **abort on the very first file**
  (`orig_sha: unbound variable`). No previous version ever managed to
  process a single file.
- v3.4's rollback anchor never recovers: an outage during the commit
  leaves the original with `nlink=2` and the worker marks it `SKIPPED`
  forever. `recover_anchors` compares inodes and either completes or
  discards the rollback as appropriate.
- v3.3/v3.4 keep the global `IFS` that leaves `CPU` and `IOWAIT` at 0:
  their governor only reacts to load and memory.
- v3, v3.2, v3.3, and v3.4 have no `trap`: Ctrl+C left temp files and
  anchors in the data tree.
- `zdb` with a `1M` hint still produced `SKIP` in v3.4, contradicting
  its own `FINAL-ASSURANCE.md`.

### Added

- **Disk pressure in the health score** from `/proc/diskstats`:
  utilization and average latency, weighted above CPU and memory. A
  pool saturated by a scrub no longer looks like a "healthy server."
- **`EMERGENCY` level** above `CRITICAL`.
- **Initial BW recommended by the baseline**, instead of always assuming
  35M.
- **`--workers N`**: real parallelism with atomic claiming between
  workers and BW split so the operator's total ceiling is respected.
  Default 1.
- **`--adaptive-priority on`**: `nice`/`ionice` governed by server
  state, with the operator's value as an aggressive cap.
- **`--ui auto|dash|plain|quiet|json` output modes**, `--log-file`, and
  immunity to `SIGHUP` for SSH operation.
- **`--dry-sample N`**: reads N full candidates (read-only) and measures
  the pool's real throughput.
- **Estimated impact before applying a BW change**, and `Applies: NEXT
  FILE / JOB / INVENTORY` labels in the control panel.
- **Informative lock**: PID, start time, and target of the worker
  holding it.
- **`--status --json`** and pre-analyzed quarantine (size and SHA-256 of
  each item).
- **11 semantic exit codes**, documented in `--help`.
- **`remote/`**: read-only-by-default SSH runner, with configuration
  kept outside the repository.

### Quality

- Comments entirely in English, explaining the why; checked by the
  static test.
- 20 numbered sections with an index at the top.
- Test suites: 37 static checks, 60 unit asserts, and 41 end-to-end
  integration tests, all run on real Linux.

## 3.3.0 — Laboratory Candidate

First version that starts up, is complete, and ran end to end.
Consolidates V3.1 (the most complete but broken) with the hardening V3.2
promised (syntactically correct but regressive), and closes the open
items the design had left pending. Details are in
[`docs/AUDIT-V3.md`](docs/AUDIT-V3.md).

### Fixed

- **The script now runs.** V3.1 had a truncated `process_one()` and did
  not pass `bash -n`.
- **The governor works again.** Bandwidth was handled as
  `"36700160B"`, a format neither `rsync` accepts nor the parser itself
  can read back: after the first adjustment the governor froze. Now it
  works in bytes/s and only formats to KiB when invoking `rsync`.
- **The health score is no longer blind.** `read` on `/proc/stat` with
  the global `IFS` (which does not include space) never split the
  line: `CPU_UTIL` and `IOWAIT` stayed at 0 forever.
- **The `atime` invariant no longer always fails.** The temp file's
  hash was calculated after restoring timestamps, and that read altered
  atime again. The pipeline was reordered: hashes first, then
  restoration, then verification.
- **The source's atime is restored after reading it** to hash it, so a
  `FAILED` or `STALE` does not leave the original altered.
- **Recovery can no longer hijack another job's temp file.**

### Added

- `RECOVERED` state and an explicit rule that **the checkpoint is not
  the authority**: a `DONE` or `SKIPPED` is only accepted if the file
  still matches what was recorded.
- Lack of space now **pauses the batch** instead of marking hundreds of
  files as `FAILED`.
- `standard` / `strict` / `maximum` integrity levels (default
  `maximum`).
- `--retry-stale` to revalidate files modified after the inventory.
- `--explain PATH`: explains why a file would or would not be
  processed, and with what guarantees.
- `--check`: system preflight without touching any file.
- State-aware wizard: detects previous work, its progress, and its
  orphan temp files before offering options.
- Directory explorer with `whiptail`, `dialog`, and `fzf`, with an
  availability report in the preflight and a Bash selector always
  present as a fallback.
- ACL/xattr verification with `getfacl`/`getfattr` when present, and
  `rsync --itemize-changes` as a fallback. The method used is recorded
  in the summary.
- Snapshot inventory published atomically.
- Job ID with nanoseconds and PID in addition to date and hash.
- Temp files marked with the job's token; foreign ones are reported and
  not touched.
- Structured journal separate from the human-readable log.
- `--status` filterable by directory, with progress and status counts.
- Documented exit codes (0 / 1 / 2 / 3).
- Runnable test suite: static, unit, and **full integration** with
  simulated ZFS.

### Observability

The design chapter no previous deliverable had implemented.

- **Dual progress**: by files and by bytes. 98/238 does not mean the
  same thing if one file weighs 2 GiB and another 80 GiB.
- **Global ETA** from the job's real average speed, plus cumulative
  average speed and elapsed time.
- **Status line**: what is happening right now (ZFS inspection,
  SHA-256, rewriting, verifying, commit, sync, cooldown).
- **Last 5 completed files**, with size, speed, and duration.
- **Cooldown countdown**, so the screen does not look frozen during the
  `sleep`.
- **Mode in the header**: `NEW` / `RESUME` / `RETRY-FAILED` /
  `RETRY-STALE`.
- **Visible warning counter**, and `warn()` which also logs them to
  `events.log`.
- **Reason breakdown** (hardlink, changed, missing, no space) on
  screen, in TSV, and in JSON.
- **Final summary** with data rewritten, average speed, time, warnings,
  recoveries, system state, and the exact command for whatever is left
  pending.

### Operational control

- `--cooldown-mode adaptive`: the pause between files follows server
  state. `fixed` (V2's behavior) remains the default.
- `--stop-after N` and `--stop-at HH:MM`: unsupervised maintenance
  windows. The stop happens between files, never mid-copy.
- **Environment health check before every file**: if the dataset
  disappears, changes, or has its recordsize changed during execution,
  the worker stops safely instead of continuing blindly.
- **Profiles read from `examples/profiles.conf`**, so they are the
  user's values and not what the worker assumes about its hardware.
  The wizard can save the current configuration as a profile.
- **The wizard remembers the last directory used**, but never selects
  it silently: it always has to be confirmed.

### Packaging

- Guard against CRLF in the tests: a Bash script with Windows line
  endings does not start on TrueNAS (`bad interpreter`).

### Restored from V3.1

Functionality V3.2 had lost: per-job persistent configuration, journal,
ACL/xattr verification, recovery of interrupted states, profiles,
`--status`, directory explorer, option validation, `--refresh-inventory`,
and JSON escaping.

---

## 3.2 — not publishable

Announced as a hardening of V3.1, but built on the V3 skeleton:
syntactically correct and with several real improvements, though losing
much of V3.1's functionality.

## 3.1 — not runnable

The most feature-complete. The delivered file is truncated inside
`process_one()` and does not pass `bash -n`.

## 3.0 — skeleton

V3 architecture and documentation, with the implementation still
incomplete.

## 2.0 — base

Original script. Prior detection via `zdb`, `flock`, limited I/O,
`renice`/`ionice`, `-aAX` preservation, size verification, and
replacement via temp file. It is the conceptual base for everything
else, and its defaults remain V3's defaults.
