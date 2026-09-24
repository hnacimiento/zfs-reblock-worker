# Ronda 12 — reinicio real de la máquina a mitad de copia, y un bug real encontrado

**[Leer en español ↓](#español)** · **[Read in English ↓](#english)**

---

# Español

Autorizado explícitamente por el operador. Único ítem del `TEST-PLAN.md`
que necesita apagar la máquina de verdad, así que se dejó para el final de
la sesión, después de confirmar que nadie más estaba usando el NAS (sin
conexiones SMB activas, sin servicios de streaming corriendo, un solo
usuario conectado — el propio).

## Protocolo

1. Archivo de prueba de 6 GiB, en el directorio descartable de siempre.
2. Worker lanzado con `--bwlimit 15M` (deliberadamente lento, para tener
   ventana de sobra) en background.
3. Espera activa hasta que el temporal alcanzara al menos 2 GiB (mitad de
   camino real, no un supuesto).
4. `/sbin/reboot` disparado en ese momento exacto.
5. Polling hasta que el NAS volviera a responder SSH.
6. Verificación del estado post-reinicio, `--resume`, verificación final.

## Resultado

- El NAS volvió a responder en 25 segundos de polling (`uptime` confirmó
  el reinicio real: de 8+ días a 1 minuto).
- El pool `toolbox` volvió a importar **sin errores** (`ONLINE`, scrub
  previo intacto).
- El archivo original (`reinicio-test.bin`, 6 GiB) quedó **completamente
  intacto** — nunca se tocó, tal como garantiza el contrato.
- El estado guardado mostraba `PROCESSING`; al correr `--resume`, el log
  mostró exactamente lo que el contrato promete: `[RECOVERY]
  reinicio-test.bin vuelve a PENDING (estaba en PROCESSING)`.
- `--resume` reescribió el archivo completo (5.59 GiB efectivos tras
  redondeo del umbral), verificó hash `b2` idéntico, inode cambió, código
  de salida final **0**.
- Verificación externa final: SHA-256 antes/después idéntico.

## El hallazgo: un huérfano que `recover_temps()` nunca veía

El archivo temporal parcial de `rsync` —el nombre de trabajo propio de
`rsync` mientras transfiere, antes de renombrarse al `.tmp` final del
worker— quedó en el árbol después del reinicio:
`.zrw-<job>-<token>.tmp.k6oOCo` (1.24 GiB, justo donde se cortó la
transferencia).

`recover_temps()` busca exactamente `.zrw-*.tmp` — ese sufijo aleatorio de
seis caracteres que antepone `rsync` lo dejaba invisible para esa lógica.
`--status` sí lo contaba (usa un glob distinto, más amplio: `.zrw-*`), así
que el operador *veía* "1 temporal en el árbol" pero no tenía ninguna
recuperación automática ni indicación de qué hacer con él — quedaba ahí
para siempre, violando la invariante #8 del contrato de seguridad ("un
temporal huérfano nunca se promueve ni se borra: se pone en cuarentena").

Corregido en 4.4.1: el glob pasó de `.zrw-*.tmp` a `.zrw-*.tmp*`. Cubierto
con un test unitario nuevo que reproduce la forma exacta del nombre real
(`tests/test_units.sh`), confirmando que el propio se pone en cuarentena
con contenido intacto y el de otro job se deja sin tocar. Limpiado a mano
el archivo huérfano real de 1.24 GiB que había quedado en el NAS del
hallazgo original, antes del fix.

## Índice

No hay logs crudos separados para esta ronda — la evidencia completa
(comandos, salidas, verificaciones) está documentada en este README y en
el `CHANGELOG.md`/`TEST-PLAN.md`, dado que la corrida involucró una
pérdida real de conectividad SSH durante el reinicio (no hay una única
sesión de log continua para archivar, como en las rondas anteriores).

## Cierre

Con esto, el último ítem verificable sin consola interactiva en vivo del
`TEST-PLAN.md` queda cerrado, con un bug real encontrado y corregido en el
proceso — exactamente el tipo de hallazgo que un reinicio real, y no un
`kill -9` simulado, podía sacar a la luz.

---

# English

Explicitly authorized. The only item in `TEST-PLAN.md` that requires
actually powering off the machine, so it was left for the end of the
session, after confirming no one else was using the NAS (no active SMB
connections, no streaming services running, a single connected user — the
operator himself).

## Protocol

1. A 6 GiB test file, in the usual disposable directory.
2. Worker launched with `--bwlimit 15M` (deliberately slow, to have plenty
   of margin) in the background.
3. Active waiting until the temp file reached at least 2 GiB (real halfway
   point, not an assumption).
4. `/sbin/reboot` triggered at that exact moment.
5. Polling until the NAS responded to SSH again.
6. Verification of the post-reboot state, `--resume`, final verification.

## Result

- The NAS started responding again after 25 seconds of polling (`uptime`
  confirmed the real reboot: from 8+ days to 1 minute).
- The `toolbox` pool imported again **with no errors** (`ONLINE`, previous
  scrub intact).
- The original file (`reinicio-test.bin`, 6 GiB) was left **completely
  intact** — never touched, exactly as the contract guarantees.
- The saved state showed `PROCESSING`; running `--resume`, the log showed
  exactly what the contract promises: `[RECOVERY] reinicio-test.bin vuelve
  a PENDING (estaba en PROCESSING)`.
- `--resume` rewrote the entire file (5.59 GiB effective after threshold
  rounding), verified an identical `b2` hash, inode changed, final exit
  code **0**.
- Final external verification: SHA-256 identical before/after.

## The finding: an orphan `recover_temps()` never saw

`rsync`'s partial temp file — `rsync`'s own working name while transferring,
before being renamed to the worker's final `.tmp` — was left in the tree
after the reboot: `.zrw-<job>-<token>.tmp.k6oOCo` (1.24 GiB, exactly where
the transfer was cut off).

`recover_temps()` looks for exactly `.zrw-*.tmp` — that random six-character
suffix `rsync` prepends left it invisible to that logic. `--status` did
count it (it uses a different, broader glob: `.zrw-*`), so the operator
*saw* "1 temp file in the tree" but had no automatic recovery or indication
of what to do with it — it would have stayed there forever, violating
invariant #8 of the safety contract ("an orphaned temp file is never
promoted or deleted: it gets quarantined").

Fixed in 4.4.1: the glob went from `.zrw-*.tmp` to `.zrw-*.tmp*`. Covered
with a new unit test that reproduces the exact shape of the real file name
(`tests/test_units.sh`), confirming that a job's own orphan gets quarantined
with its content intact and another job's orphan is left untouched. The
real 1.24 GiB orphan file left on the NAS by the original finding was
cleaned up by hand, before the fix.

## Index

There are no separate raw logs for this round — the complete evidence
(commands, output, verifications) is documented in this README and in
`CHANGELOG.md`/`TEST-PLAN.md`, since the run involved a real loss of SSH
connectivity during the reboot (there is no single continuous log session
to archive, unlike in previous rounds).

## Close-out

With this, the last item verifiable without a live interactive console in
`TEST-PLAN.md` is closed, with a real bug found and fixed in the process —
exactly the kind of finding that a real reboot, and not a simulated
`kill -9`, could bring to light.
