# Ronda 4 — job real, interrupción/resume, `--workers 2`, y un hallazgo serio

**[Leer en español ↓](#español)** · **[Read in English ↓](#english)**

---

# Español

Primera ronda que ejecuta un `--new-job` **real** (no `--dry-run`) contra
copias propias de archivos de producción, dentro de un directorio de prueba
dedicado (`ZRW-PRUEBAS-TEMPORAL-20260919`, eliminado al terminar). Encontró
tres cosas de peso, en este orden:

1. Un **proceso huérfano de una ronda anterior** (`--dry-run --dry-sample 3`
   sobre el árbol completo) seguía vivo desde hacía más de 90 minutos: el
   worker ignora `SIGHUP` a propósito para sobrevivir a un corte de SSH, y un
   `timeout` local que mata el cliente antes de que el comando remoto termine
   deja exactamente ese rastro. Ver `01-orfanos-encontrados-y-limpiados.txt`.

2. Un **scrub real del pool** (`zpool status`, iniciado a las 00:00:02, ETA
   ~18h) explicaba la presión sostenida que el governor venía reportando —
   comportamiento correcto del governor, no un bug. Ver
   `02-scrub-confirmado-zpool-status.txt`.

3. El hallazgo real: **`zdb -O` puede colgarse varios minutos** compitiendo
   por I/O de metadata con el scrub, en un disco único (USB), y al no tener
   timeout, bloqueaba el job entero — pese a que su propio diseño dice que es
   "solo advisory" y nunca debería decidir nada, mucho menos bloquear trabajo
   real. Corregido en 4.2.2 con `timeout 5` alrededor de la llamada. Ver
   `03-zdb-colgado-7-minutos.txt` y `04-fix-confirmado-resume-ok.txt`.

## Índice

- `01-orfanos-encontrados-y-limpiados.txt` — el primer proceso huérfano, su
  árbol de procesos, y la limpieza.
- `02-scrub-confirmado-zpool-status.txt` — `zpool status` confirmando el scrub.
- `03-zdb-colgado-7-minutos.txt` — diagnóstico completo del cuelgue: `ps`,
  `wchan`, `pstree`, hasta encontrar `zdb -O` como el proceso realmente
  bloqueado.
- `04-fix-confirmado-resume-ok.txt` — reintento de interrupción/resume con el
  fix desplegado: `--resume` ya no falla con `EX_LOCKED`, SHA-256 idéntico,
  código de salida 0.
- `05-workers-2-y-hash-timing.txt` — `--workers 2` completo y comparación real
  `sha256` vs `b2` sobre un archivo de producción.

## Por qué esto importa

Ninguno de estos tres hallazgos era reproducible sin un servidor real bajo
carga real: el laboratorio simulado de `tests/test_integration.sh` no tiene
disco físico que contendir, y WSL no corre un scrub de ZFS. Es exactamente el
tipo de hallazgo que esta ronda de pruebas existe para buscar.

---

# English

First round to run a **real** `--new-job` (not `--dry-run`) against
copies of production files, inside a dedicated test directory
(`ZRW-PRUEBAS-TEMPORAL-20260919`, deleted when finished). It found
three things of note, in this order:

1. An **orphaned process from a previous round** (`--dry-run --dry-sample 3`
   over the full tree) was still alive after more than 90 minutes: the
   worker deliberately ignores `SIGHUP` to survive an SSH disconnection, and a
   local `timeout` that kills the client before the remote command finishes
   leaves exactly that kind of trace. See `01-orfanos-encontrados-y-limpiados.txt`.

2. A **real pool scrub** (`zpool status`, started at 00:00:02, ETA
   ~18h) explained the sustained pressure the governor had been reporting —
   correct governor behavior, not a bug. See
   `02-scrub-confirmado-zpool-status.txt`.

3. The real finding: **`zdb -O` can hang for several minutes**
   competing for metadata I/O with the scrub, on a single (USB) disk, and
   having no timeout, it blocked the entire job — even though its own design
   says it is "advisory only" and should never decide anything, let alone
   block real work. Fixed in 4.2.2 with `timeout 5` around the call. See
   `03-zdb-colgado-7-minutos.txt` and `04-fix-confirmado-resume-ok.txt`.

## Index

- `01-orfanos-encontrados-y-limpiados.txt` — the first orphaned process, its
  process tree, and the cleanup.
- `02-scrub-confirmado-zpool-status.txt` — `zpool status` confirming the scrub.
- `03-zdb-colgado-7-minutos.txt` — full diagnosis of the hang: `ps`,
  `wchan`, `pstree`, until finding `zdb -O` as the process actually
  blocked.
- `04-fix-confirmado-resume-ok.txt` — retrying interrupt/resume with the
  fix deployed: `--resume` no longer fails with `EX_LOCKED`, identical SHA-256,
  exit code 0.
- `05-workers-2-y-hash-timing.txt` — full `--workers 2` run and a real
  `sha256` vs `b2` comparison on a production file.

## Why this matters

None of these three findings was reproducible without a real server under
real load: the simulated lab in `tests/test_integration.sh` has no physical
disk to contend for, and WSL doesn't run a ZFS scrub. This is exactly the
kind of finding this round of testing exists to look for.
