# Ronda 6 — backslash literal, `--workers 2` + `STALE`, y un job real de 3h20m

**[Leer en español ↓](#español)** · **[Read in English ↓](#english)**

---

# Español

Continuación autónoma de la ronda 5, con el mismo protocolo: chequeo de
espacio antes de cada prueba, todo dentro de `ZRW-PRUEBAS-TEMPORAL-20260919`
(eliminado al final de cada corrida), y logs traídos a este repositorio.
Ejecutada contra `toolbox/media` con el mismo scrub real todavía activo (pasó
de 20% a 23% durante esta ronda). Tres frentes, los tres propuestos al cierre
de la ronda 5:

1. **Backslash literal en el nombre de archivo** (no solo salto de línea).
   Confirmado: `sha256sum` antepone la misma barra de escape que ya se había
   corregido en 4.2.3 para el caso del salto de línea, así que el fix de
   `hash_of()` cubre este caso también sin cambios adicionales. 3/3 archivos
   (barra sola, barra+tab, barra+salto de línea combinados) reblockeados
   correctamente.

2. **`--workers 2` combinado con `STALE`**: cinco archivos, dos workers
   activos, uno de los archivos modificado a mano a mitad de camino. El
   archivo modificado quedó correctamente `STALE` (no fue pisado, su cambio
   propio se preservó) mientras los otros cuatro se reblockearon con
   contenido intacto. Sin interacción problemática entre concurrencia y
   detección de cambios.

3. **Job real grande (293 GiB, dos películas de producción), configuración
   por defecto, sin supervisión**. El hallazgo de mayor peso de esta ronda:
   tras reescribir la primera película (144.24 GiB, 3h00m, verificado
   SHA-256 OK), el governor detectó presión sostenida real del servidor
   (score 6, disco 100%, bajo el mismo scrub de fondo) y el worker **se
   pausó a sí mismo** (`JOB PAUSADO`, código de salida 13) en vez de seguir
   forzando un disco ya saturado — dejando el job resumible con `--resume`,
   sin tocar la segunda película (verificada intacta después). Comportamiento
   correcto por diseño, pero con una implicancia operativa real: un job largo
   "sin supervisión" con la configuración adaptativa por defecto puede
   terminar pausado esperando intervención manual, no necesariamente
   completo, si la presión real del servidor es sostenida. RSS del proceso
   se mantuvo estable (~5.8 MB) durante las más de 3 horas de ejecución, sin
   señales de fuga de memoria.

## Índice

- `01-batchG-backslash-literal-en-nombre.txt` — tres nombres con backslash
  literal (solo, combinado con tab, combinado con salto de línea), corrida
  real, 3/3 OK.
- `02-batchH-workers2-y-stale.txt` — cinco archivos con `--workers 2`, uno
  mutado a mitad de camino: 4 reblockeados, 1 `STALE` correctamente
  preservado, 0 fallidos.
- `03-batchI-job-largo-horas-pausa-protectiva.txt` — el job de 293 GiB,
  3h23m de transcurrido real, muestreo de memoria/governor cada 10 minutos,
  y el hallazgo de la pausa protectiva bajo presión sostenida.

## Por qué esto importa

El hallazgo de la pausa protectiva no es un bug — es exactamente la
propiedad de seguridad que el worker promete (no forzar un pool bajo presión
real) funcionando como se diseñó. Pero cambia la expectativa operativa de
"corré esto y volvé en unas horas": bajo carga real sostenida, el operador
(o un cron/wrapper) necesita revisar `--status` y, si corresponde, emitir
`--resume`, en vez de asumir que el job termina solo. Vale la pena
documentarlo explícitamente en el README principal del proyecto.

---

# English

Autonomous continuation of round 5, with the same protocol: a space
check before each test, everything inside `ZRW-PRUEBAS-TEMPORAL-20260919`
(deleted at the end of each run), and logs brought back into this repository.
Run against `toolbox/media` with the same real scrub still active (it went
from 20% to 23% during this round). Three fronts, all three proposed at the
close of round 5:

1. **Literal backslash in a file name** (not just a newline).
   Confirmed: `sha256sum` prepends the same escape slash already fixed
   in 4.2.3 for the newline case, so the `hash_of()` fix covers this
   case too with no additional changes. 3/3 files
   (backslash alone, backslash+tab, backslash+newline combined) correctly
   reblocked.

2. **`--workers 2` combined with `STALE`**: five files, two workers
   active, one of the files modified by hand midway through. The
   modified file correctly ended up `STALE` (it wasn't overwritten, its own
   change was preserved) while the other four were reblocked with
   intact content. No problematic interaction between concurrency and
   change detection.

3. **Large real job (293 GiB, two production movies), default
   configuration, unsupervised**. The most significant finding of this
   round: after rewriting the first movie (144.24 GiB, 3h00m, verified
   SHA-256 OK), the governor detected sustained real server pressure
   (score 6, disk 100%, under the same background scrub) and the worker
   **paused itself** (`JOB PAUSADO`, exit code 13) instead of continuing
   to force an already-saturated disk — leaving the job resumable with
   `--resume`, without touching the second movie (verified intact afterward).
   Correct behavior by design, but with a real operational implication: a
   long "unsupervised" job with the default adaptive configuration can
   end up paused waiting for manual intervention, not necessarily
   complete, if real server pressure is sustained. Process RSS
   stayed stable (~5.8 MB) during the more than 3 hours of execution, with
   no sign of a memory leak.

## Index

- `01-batchG-backslash-literal-en-nombre.txt` — three names with a literal
  backslash (alone, combined with tab, combined with newline), a
  real run, 3/3 OK.
- `02-batchH-workers2-y-stale.txt` — five files with `--workers 2`, one
  mutated midway through: 4 reblocked, 1 `STALE` correctly
  preserved, 0 failed.
- `03-batchI-job-largo-horas-pausa-protectiva.txt` — the 293 GiB job,
  3h23m of real elapsed time, memory/governor sampling every 10 minutes,
  and the finding of the protective pause under sustained pressure.

## Why this matters

The protective-pause finding isn't a bug — it's exactly the
safety property the worker promises (not forcing a pool under real
pressure) working as designed. But it changes the operational expectation of
"run this and come back in a few hours": under sustained real load, the
operator (or a cron/wrapper) needs to check `--status` and, if warranted,
issue `--resume`, rather than assume the job finishes on its own. It's
worth documenting this explicitly in the project's main README.
