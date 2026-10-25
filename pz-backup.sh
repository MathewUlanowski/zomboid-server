#!/usr/bin/env bash
# World backup for the Project Zomboid server.
#
# Run by the chart's backup CronJob (same image, the server's volume mounted
# read-only), or by hand. It:
#   1. asks the running server to save, through the console FIFO on the volume
#   2. archives the data folder (world, player db, .ini, sandbox vars)
#   3. keeps only the newest PZ_BACKUP_KEEP archives
#
# The game install and Workshop content are NOT archived — they re-download.
set -euo pipefail

log() { echo "[backup] $*"; }
die() { echo "[backup] ERROR: $*" >&2; exit 1; }

PZ_DATA="${PZ_DATA:-/home/steam/pz/data}"
SERVER_NAME="${PZ_SERVER_NAME:-servertest}"
DEST="${PZ_BACKUP_DIR:-/backups}"
KEEP="${PZ_BACKUP_KEEP:-7}"
fifo="${PZ_DATA}/console.fifo"
console_log="${PZ_DATA}/server-console.txt"

[ -d "${PZ_DATA}/Saves" ] || die "No world found under ${PZ_DATA} — is the server volume mounted?"
[[ "${KEEP}" =~ ^[1-9][0-9]*$ ]] || die "PZ_BACKUP_KEEP must be a positive number (got '${KEEP}')."
mkdir -p "${DEST}"

count_saves() { { grep -c 'Saving finish' "${console_log}" 2>/dev/null || true; } | head -n1; }

# ---------------------------------------------------------------------------
# 1. In-game save, so the archive holds what players just did. A stopped
#    server has nobody reading the FIFO, hence the timeout on the write.
# ---------------------------------------------------------------------------
saved=false
if [ -p "${fifo}" ]; then
    before="$(count_saves)"
    if timeout 5 bash -c 'echo save > "$0"' "${fifo}"; then
        for _ in $(seq 1 30); do
            now="$(count_saves)"
            if [ "${now:-0}" -gt "${before:-0}" ]; then saved=true; break; fi
            sleep 2
        done
    fi
fi
if [ "${saved}" = "true" ]; then
    log "Server saved the world."
else
    log "WARNING: no save confirmation from the server (stopped, or still starting) — archiving the files as they are on disk."
fi

# ---------------------------------------------------------------------------
# 2. Archive. tar exits 1 when a file changed while being read, which happens
#    on a live server and still yields a usable archive.
# ---------------------------------------------------------------------------
out="${DEST}/${SERVER_NAME}-$(date -u +%Y%m%d-%H%M).tgz"
data_name="$(basename "${PZ_DATA}")"
rc=0
tar -C "$(dirname "${PZ_DATA}")" -czf "${out}.partial" \
    --exclude="${data_name}/Logs" \
    --exclude="${data_name}/backups" \
    --exclude="${data_name}/console.fifo" \
    --exclude="${data_name}/.workshop-deps" \
    "${data_name}" || rc=$?
if [ "${rc}" -gt 1 ]; then
    rm -f "${out}.partial"
    die "tar failed with code ${rc}."
fi
[ "${rc}" -eq 1 ] && log "Note: some files changed while being archived (players online)."
gzip -t "${out}.partial" || { rm -f "${out}.partial"; die "Archive failed its integrity check."; }
mv "${out}.partial" "${out}"
log "Wrote ${out} ($(du -h "${out}" | cut -f1))."

# ---------------------------------------------------------------------------
# 3. Rotate: newest KEEP archives of this server stay. Anything in a
#    sub-folder (e.g. manual/) is never touched.
# ---------------------------------------------------------------------------
mapfile -t old < <(ls -1t "${DEST}/${SERVER_NAME}"-*.tgz 2>/dev/null | tail -n "+$((KEEP + 1))")
for file in "${old[@]}"; do
    rm -f "${file}"
    log "Removed old backup $(basename "${file}")."
done
log "Done. $(ls -1 "${DEST}/${SERVER_NAME}"-*.tgz | wc -l) backup(s) kept in ${DEST}."
