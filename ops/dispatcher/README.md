# SuperDev Dispatcher v2

Scripts hardened in response to five production bugs. The three v2 source files
here are installed over their production counterparts by `install.sh`.

---

## Bugs corregidos

| # | Nombre | Script | Descripción |
|---|--------|--------|-------------|
| 1 | Normalización org/repo | `dispatch-queue-v2.sh` | Briefs con formato `org/repo` ahora se normalizan con `basename` antes de bifurcar el worker. Un repo inexistente se clasifica como error permanente (`status=blocked`) en el primer intento, sin reintento storm. |
| 2 | CLI auth (GH_TOKEN no heredado) | `run-brief-v2.sh` | Los env files asignan sin `export`. Ahora se re-exportan explícitamente `GH_TOKEN`, `SUPABASE_URL`, `SUPABASE_SERVICE_KEY`, etc. para que `gh` y `curl` los hereden. |
| 3 | `pr_url` no escrito | `run-brief-v2.sh` | La URL del PR se escribe en BD en el momento de creación del PR, no al final del script. Evita que un crash posterior al merge deje el campo vacío en Supabase. |
| 4 | Falso `ok` sin commits | `run-brief-v2.sh` | Si Claude sale con código 0 pero no produjo commits pusheados ni PR, el estado final en BD es `partial` (no `ok`). El PATCH `status=ok` del dispatcher filtra `status=eq.running`, que ya no aplica. |
| 5 | Tabla rasa sin commits locales | `run-brief-v2.sh` | Guard anti-tablarasa: antes de `git reset --hard` / `git clean`, comprueba cambios sin commitear o commits locales no pusheados. Si los hay, sale con código 6 (`status=blocked`) sin tocar el árbol. |

---

## Instalación

```bash
# 1. Actualizar el repo
git pull

# 2. Dry-run (ver qué se haría sin ejecutar nada)
bash ops/dispatcher/install.sh --dry-run

# 3. Instalar
bash ops/dispatcher/install.sh
```

El script imprime el STAMP al final — guárdalo para rollback si algo falla.

---

## Rollback

```bash
STAMP=v2-YYYYMMDD-HHMMSS bash ops/dispatcher/install.sh --rollback STAMP=v2-YYYYMMDD-HHMMSS
```

Sustituye `v2-YYYYMMDD-HHMMSS` por el STAMP que imprimió `install.sh`.

---

## Observabilidad

```bash
# Seguir el log del dispatcher en tiempo real
journalctl -u superdev-dispatcher.service -f

# Ver las últimas 100 líneas del log de ciclo
tail -n 100 /opt/superxavi/logs/dispatch.log

# Log de un brief concreto
tail -n 200 /opt/superxavi/logs/<brief_id>.log

# Estado del timer
systemctl status superdev-dispatcher.timer
systemctl list-timers superdev-dispatcher.timer
```

---

## Tunables

Todas las variables son opcionales; los valores por defecto son los mostrados.

| Variable | Defecto | Dónde se usa | Descripción |
|----------|---------|--------------|-------------|
| `BRIEF_TIMEOUT` | `5400` | `dispatch-queue-v2.sh` | Tiempo máximo (segundos) para la invocación de Claude. Pasado a `run-brief-v2.sh`. |
| `RUNBRIEF_LOCK_MAX_AGE` | `1800` | `dispatch-queue-v2.sh` | Tiempo (segundos) tras el cual un lock de run-brief sin proceso asociado se limpia. |
| `WORKTREE_MAX_AGE_DAYS` | `14` | `dispatch-queue-v2.sh` | Worktrees con mtime mayor a este valor (días) se eliminan en el GC horario. |
| `WORKTREE_GC_INTERVAL` | `3600` | `dispatch-queue-v2.sh` | Frecuencia mínima (segundos) del GC de worktrees. |
| `AUTO_MERGE_ENABLED` | `true` | `auto-merge-pr-v2.sh` | Poner a cualquier otro valor para deshabilitar el auto-merge globalmente. |
| `AUTO_MERGE_POLL_INTERVAL` | `30` | `auto-merge-pr-v2.sh` | Segundos entre iteraciones del poll loop. |
| `AUTO_MERGE_MAX_UPDATE_ATTEMPTS` | `2` | `auto-merge-pr-v2.sh` | Máximo de llamadas a `gh pr update-branch` por PR. |
| `AUTO_MERGE_UPDATE_GRACE` | `300` | `auto-merge-pr-v2.sh` | Segundos extra añadidos al timeout tras un `update-branch` exitoso. |
| `AUTO_MERGE_GH_RETRY_SLEEP` | `5` | `auto-merge-pr-v2.sh` | Pausa (segundos) antes del reintento en errores 5xx de GitHub. |

---

## Archivos

| Archivo fuente | Destino en producción | Descripción |
|----------------|-----------------------|-------------|
| `dispatch-queue-v2.sh` | `/opt/superxavi/scripts/dispatch-queue.sh` | Ciclo principal del dispatcher: fetch de briefs, fork de workers, GC. |
| `run-brief-v2.sh` | `/opt/superxavi/scripts/run-brief.sh` | Wrapper por brief: guard tablarasa, timeout, crash trap, BD writes. |
| `auto-merge-pr-v2.sh` | `/opt/superxavi/scripts/auto-merge-pr.sh` | Poll loop de merge: espera checks, update-branch, squash merge, notificación. |
| `install.sh` | _(ejecutar desde el repo)_ | Instala/hace rollback de los tres scripts anteriores. |
| `test-guards.sh` | _(ejecutar desde el repo)_ | Suite de tests para el guard anti-tablarasa y syntax check. |
