#!/usr/bin/env bash
# Project Zomboid dedicated server entrypoint.
#
# Starts as root only to fix volume ownership, then re-execs itself as the
# unprivileged `steam` user and:
#   1. installs/updates the server to the CURRENT Steam build
#   2. resolves the Steam Workshop mod list (downloads items, reads mod IDs)
#   3. writes the managed keys into the server .ini
#   4. runs the server, turning SIGTERM into a clean in-game `quit` (save)
#
# All configuration comes from environment variables (see README). Anything
# passed after the image name is appended verbatim to the server command line.
set -euo pipefail

log() { echo "[entrypoint] $*"; }
die() { echo "[entrypoint] ERROR: $*" >&2; exit 1; }

# gosu preserves the caller's HOME (/root); force it to steam's home so
# SteamCMD and the server write their caches/config where steam can.
export HOME=/home/steam

PZ_DIR="${PZ_DIR:-/home/steam/pz/server}"
PZ_DATA="${PZ_DATA:-/home/steam/pz/data}"
STEAMCMD=/home/steam/steamcmd/steamcmd.sh
SERVER_APPID=380870   # Project Zomboid Dedicated Server
GAME_APPID=108600     # Project Zomboid (owns the Workshop items)
SERVER_NAME="${PZ_SERVER_NAME:-servertest}"
INI="${PZ_DATA}/Server/${SERVER_NAME}.ini"
WORKSHOP_CONTENT="${PZ_DIR}/steamapps/workshop/content/${GAME_APPID}"

# ---------------------------------------------------------------------------
# 0. Fix ownership of the (possibly root-owned) mounted volume, drop to steam.
#    SteamCMD reports "Missing file permissions" if run as root.
# ---------------------------------------------------------------------------
if [ "$(id -u)" = "0" ]; then
    for dir in "${PZ_DIR}" "${PZ_DATA}"; do
        mkdir -p "${dir}"
        # Only recurse when needed — the install is several GB.
        if [ "$(stat -c %U "${dir}")" != "steam" ]; then
            log "Fixing ownership of ${dir}"
            chown -R steam:steam "${dir}"
        fi
    done
    exec gosu steam "$0" "$@"
fi

mkdir -p "${PZ_DIR}" "${PZ_DATA}/Server"

# split_list <value> <separator chars> -> one trimmed, de-duplicated entry per line
split_list() {
    printf '%s\n' "$1" | tr "$2" '\n' | tr -d '\r' \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
        | awk 'NF && !seen[$0]++'
}

# SteamCMD self-updates and re-execs on first run, so retry a few times to
# ride out its transient non-zero exits.
steamcmd_retry() {
    local attempt
    for attempt in 1 2 3; do
        "${STEAMCMD}" "$@" +quit && return 0
        log "steamcmd attempt ${attempt} failed, retrying..."
        sleep 5
    done
    return 1
}

# ---------------------------------------------------------------------------
# 1. Install / update the server.
#    The install lives on the volume, so it is only ever downloaded once; what
#    PZ_VERSION controls is WHEN SteamCMD is allowed to touch it again:
#      latest      -> check Steam on every start, always track the current build
#      anything else (e.g. 42.21.0) -> a label. SteamCMD runs only when the
#                     label (or branch) differs from the one recorded on the
#                     volume, i.e. the server updates when YOU bump the value.
#    Steam only serves the newest build of a branch, so a label cannot fetch
#    an older build — it holds the installed one. The real version is checked
#    against the label once the server is up (see the watch loop).
# ---------------------------------------------------------------------------
PZ_VERSION="${PZ_VERSION:-latest}"
install_marker="${PZ_DIR}/.pz-installed"
wanted="version=${PZ_VERSION} branch=${PZ_BETA_BRANCH:-default}"

needs_update=true
if [ "${PZ_VERSION}" != "latest" ] && [ "${PZ_VALIDATE_ON_START:-false}" != "true" ] \
    && [ -x "${PZ_DIR}/start-server.sh" ] && [ "$(cat "${install_marker}" 2>/dev/null)" = "${wanted}" ]; then
    needs_update=false
fi

if [ "${needs_update}" = "true" ]; then
    update_args=("${SERVER_APPID}")
    if [ -n "${PZ_BETA_BRANCH:-}" ]; then
        update_args+=(-beta "${PZ_BETA_BRANCH}")
        [ -n "${PZ_BETA_PASSWORD:-}" ] && update_args+=(-betapassword "${PZ_BETA_PASSWORD}")
    fi
    [ "${PZ_VALIDATE_ON_START:-false}" = "true" ] && update_args+=(validate)
    log "Installing/updating Project Zomboid server (app ${SERVER_APPID}, branch ${PZ_BETA_BRANCH:-default})..."
    # force_install_dir MUST precede login.
    steamcmd_retry +force_install_dir "${PZ_DIR}" +login anonymous +app_update "${update_args[@]}" \
        || die "SteamCMD could not install the server."
    echo "${wanted}" > "${install_marker}"
else
    log "Server install for version '${PZ_VERSION}' is cached on the volume — skipping SteamCMD."
fi
[ -x "${PZ_DIR}/start-server.sh" ] || die "start-server.sh not found in ${PZ_DIR} — install failed."

# ---------------------------------------------------------------------------
# 2. Steam Workshop mods.
#    The .ini needs TWO things per mod: the Workshop item ID (what to download)
#    and the mod ID(s) inside that item (what to enable). Only the first is
#    visible in a Workshop URL, so unless PZ_MOD_IDS is given we download the
#    items with SteamCMD and read the mod IDs (and any map folders) out of them.
# ---------------------------------------------------------------------------
# info_value <mod.info> <key> -> trimmed value of the first "key=" line
info_value() {
    { grep -i -m1 "^[[:space:]]*$2[[:space:]]*=" "$1" || true; } \
        | sed -e 's/^[^=]*=//' | tr -d '\r' \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# required_items <workshop id> -> the Workshop IDs Steam lists under
# "Required items". The keyless Steam Web API does not expose these, so they
# are read from the public Workshop page. That fetch fails now and then, so it
# is retried, and the last good answer is cached on the volume as a fallback.
# (Runs inside $(...), so messages go to stderr.)
DEPS_CACHE="${PZ_DATA}/.workshop-deps"
required_items() {
    local id="$1" page="" attempt cache="${DEPS_CACHE}/$1"
    for attempt in 1 2 3; do
        page="$(curl -fsSL --compressed --max-time 20 -A 'Mozilla/5.0' \
            "https://steamcommunity.com/sharedfiles/filedetails/?id=${id}" 2>/dev/null || true)"
        # Only trust a real item page; an error/rate-limit page lacks the title.
        grep -q 'workshopItemTitle' <<< "${page}" && break
        page=""
        sleep 3
    done
    if [ -n "${page}" ]; then
        mkdir -p "${DEPS_CACHE}"
        { printf '%s\n' "${page}" | sed -n '/id="RequiredItems"/,/<!--/p' \
            | grep -oE 'filedetails/\?id=[0-9]+' | grep -oE '[0-9]+$' | awk '!seen[$0]++' || true; } > "${cache}"
    elif [ -f "${cache}" ]; then
        log "  WARNING: could not reach the Workshop page for ${id}; using its cached required items." >&2
    else
        log "  WARNING: could not reach the Workshop page for ${id} — its required items were NOT checked." >&2
        return 0
    fi
    cat "${cache}"
}

# resolve_item <workshop id>: depth-first, appends dependencies then the item
# itself to `resolved`.
declare -A visited=() requested=()
resolve_item() {
    local id="$1" dep
    [ -n "${visited[${id}]:-}" ] && return 0
    visited["${id}"]=1
    for dep in $(required_items "${id}"); do
        [ -n "${visited[${dep}]:-}${requested[${dep}]:-}" ] || log "  ${id} requires Workshop item ${dep} — adding it."
        resolve_item "${dep}"
    done
    resolved+=("${id}")
}

workshop_ids=()
mod_ids=()
maps=()
declare -A mod_requires=()
if [ "${PZ_MANAGE_MODS:-true}" = "true" ]; then
    mapfile -t workshop_ids < <(split_list "${PZ_WORKSHOP_IDS:-}" ';, ')
    mapfile -t mod_ids      < <(split_list "${PZ_MOD_IDS:-}" ';,')
    mapfile -t maps         < <(split_list "${PZ_MAPS:-}" ';')   # map names may contain commas
    for id in "${workshop_ids[@]}"; do
        [[ "${id}" =~ ^[0-9]+$ ]] || die "PZ_WORKSHOP_IDS entry '${id}' is not a numeric Workshop ID."
    done

    if [ "${#workshop_ids[@]}" -gt 0 ] && [ "${#mod_ids[@]}" -eq 0 ]; then
        # Pull in each item's Steam "Required items" (and theirs), placing a
        # dependency before the item that needs it.
        if [ "${PZ_RESOLVE_DEPENDENCIES:-true}" = "true" ]; then
            resolved=()
            for id in "${workshop_ids[@]}"; do requested["${id}"]=1; done
            for id in "${workshop_ids[@]}"; do resolve_item "${id}"; done
            workshop_ids=("${resolved[@]}")
        fi

        log "Downloading ${#workshop_ids[@]} Workshop item(s) to discover mod IDs: ${workshop_ids[*]}"
        for attempt in 1 2 3; do
            missing=()
            for id in "${workshop_ids[@]}"; do
                [ -d "${WORKSHOP_CONTENT}/${id}" ] || missing+=("${id}")
            done
            # Re-request everything on the first pass so existing items get updated.
            [ "${attempt}" -eq 1 ] && missing=("${workshop_ids[@]}")
            [ "${#missing[@]}" -eq 0 ] && break
            dl_args=()
            for id in "${missing[@]}"; do
                dl_args+=(+workshop_download_item "${GAME_APPID}" "${id}")
            done
            "${STEAMCMD}" +force_install_dir "${PZ_DIR}" +login anonymous "${dl_args[@]}" +quit \
                || log "steamcmd workshop download attempt ${attempt} reported an error."
        done

        for id in "${workshop_ids[@]}"; do
            item="${WORKSHOP_CONTENT}/${id}"
            [ -d "${item}" ] || die "Workshop item ${id} failed to download (private, removed, or wrong ID?)."
            # One item can hold several mods (mods/<Name>/). Build 42 reads
            # mod.info from a version folder (42/, 42.13/, ...) and ignores the
            # Build 41 one at the mod root — and the two may carry DIFFERENT
            # ids — so use the newest version folder when there is one.
            found=()
            for moddir in "${item}"/mods/*/; do
                [ -d "${moddir}" ] || continue
                info="$(find "${moddir}" -mindepth 2 -maxdepth 2 -type f -name mod.info \
                    | grep -E '/[0-9]+(\.[0-9]+)*/mod\.info$' | sort -V | tail -n1 || true)"
                if [ -z "${info}" ]; then
                    info="${moddir}mod.info"
                    [ -f "${info}" ] || continue
                    legacy=true
                else
                    legacy=false
                fi
                mod_id="$(info_value "${info}" id)"
                [ -n "${mod_id}" ] || continue
                [ "${legacy}" = "true" ] && log "  WARNING: '${mod_id}' (item ${id}) has no Build 42 folder — it will NOT load on a Build 42 server."
                found+=("${mod_id}")
                mod_requires["${mod_id}"]="$(info_value "${info}" require)"
            done
            [ "${#found[@]}" -gt 0 ] || die "Workshop item ${id} contains no mod.info — is it a Project Zomboid mod?"
            log "  ${id} -> ${found[*]}"
            [ "${#found[@]}" -gt 1 ] && log "  NOTE: item ${id} holds ${#found[@]} mods and ALL are enabled; drop optional ones with PZ_MOD_IDS_EXCLUDE."
            mod_ids+=("${found[@]}")

            if [ -z "${PZ_MAPS:-}" ]; then
                # Map mods ship media/maps/<MapName>/map.info
                mapfile -t found < <(find "${item}" -type f -name map.info -path '*/media/maps/*' \
                    | sed -e 's|/map\.info$||' -e 's|.*/||' | awk 'NF && !seen[$0]++')
                if [ "${#found[@]}" -gt 0 ]; then
                    log "  ${id} -> map(s): ${found[*]}"
                    maps+=("${found[@]}")
                fi
            fi
        done
        mapfile -t mod_ids < <(printf '%s\n' "${mod_ids[@]}" | awk 'NF && !seen[$0]++')

        # Drop excluded mods (optional sub-mods of a multi-mod item).
        mapfile -t excluded < <(split_list "${PZ_MOD_IDS_EXCLUDE:-}" ';,')
        if [ "${#excluded[@]}" -gt 0 ]; then
            kept=()
            for mod_id in "${mod_ids[@]}"; do
                skip=false
                for ex in "${excluded[@]}"; do [ "${mod_id}" = "${ex}" ] && skip=true; done
                if [ "${skip}" = "true" ]; then log "  excluded: ${mod_id}"; else kept+=("${mod_id}"); fi
            done
            mod_ids=("${kept[@]}")
        fi

        # A mod whose dependency is missing is silently skipped by the server
        # ("required mod ... not found"), so call it out here instead.
        for mod_id in "${mod_ids[@]}"; do
            mapfile -t reqs < <(split_list "${mod_requires[${mod_id}]:-}" ',;')
            for req in "${reqs[@]}"; do
                req="${req#\\}"
                have=false
                for other in "${mod_ids[@]}"; do [ "${other}" = "${req}" ] && have=true; done
                [ "${have}" = "true" ] || log "  WARNING: '${mod_id}' requires mod '${req}', which is not in the list — add its Workshop item or '${mod_id}' will not load."
            done
        done

        if [ "${#maps[@]}" -gt 0 ]; then
            mapfile -t maps < <(printf '%s\n' "${maps[@]}" | awk 'NF && !seen[$0]++')
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 3. Server .ini — only the keys below are managed; everything else is left
#    exactly as the server (or you) wrote it. The server fills in defaults for
#    any key that is missing, so a fresh volume starts from a minimal file.
# ---------------------------------------------------------------------------
# Fresh volume: UPnP is useless in a container and costs ~12s per boot.
[ -s "${INI}" ] || echo "UPnP=false" > "${INI}"
[ -z "$(tail -c1 "${INI}")" ] || echo >> "${INI}"

set_ini() {
    local key="$1" value="$2"
    if grep -q "^${key}=" "${INI}"; then
        # ENVIRON (not -v) so backslashes in values survive untouched.
        K="${key}" V="${value}" awk \
            'index($0, ENVIRON["K"] "=") == 1 { print ENVIRON["K"] "=" ENVIRON["V"]; next } { print }' \
            "${INI}" > "${INI}.tmp"
        mv "${INI}.tmp" "${INI}"
    else
        printf '%s=%s\n' "${key}" "${value}" >> "${INI}"
    fi
}

join_by() { local sep="$1"; shift; local out="" item; for item in "$@"; do out+="${out:+${sep}}${item}"; done; printf '%s' "${out}"; }

set_ini DefaultPort "${PZ_PORT:-16261}"
set_ini UDPPort "${PZ_UDP_PORT:-16262}"
[ -n "${PZ_PUBLIC_NAME:-}" ]     && set_ini PublicName "${PZ_PUBLIC_NAME}"
[ -n "${PZ_MAX_PLAYERS:-}" ]     && set_ini MaxPlayers "${PZ_MAX_PLAYERS}"
[ -n "${PZ_SERVER_PASSWORD:-}" ] && set_ini Password "${PZ_SERVER_PASSWORD}"
if [ -n "${PZ_RCON_PASSWORD:-}" ]; then
    set_ini RCONPassword "${PZ_RCON_PASSWORD}"
    set_ini RCONPort "${PZ_RCON_PORT:-27015}"
fi

if [ "${PZ_MANAGE_MODS:-true}" = "true" ]; then
    # The env/Helm list is the source of truth: removing a mod there removes it here.
    # Verified on 42.21: plain mod IDs load. Some early Build 42 versions wanted
    # a leading backslash — PZ_MOD_ID_PREFIX='\' restores that if ever needed.
    prefixed=()
    for id in "${mod_ids[@]}"; do prefixed+=("${PZ_MOD_ID_PREFIX:-}${id}"); done
    set_ini WorkshopItems "$(join_by ';' "${workshop_ids[@]}")"
    set_ini Mods "$(join_by ';' "${prefixed[@]}")"
    # Map mods must load BEFORE the base map.
    set_ini Map "$(join_by ';' "${maps[@]}" "Muldraugh, KY")"
    log "Mods: WorkshopItems=$(join_by ';' "${workshop_ids[@]}") Mods=$(join_by ';' "${prefixed[@]}")"
else
    log "PZ_MANAGE_MODS=false — leaving Mods/WorkshopItems/Map in the .ini untouched."
fi

# Freeform Key=Value lines, applied last so they win.
if [ -n "${PZ_INI_OVERRIDES:-}" ]; then
    while IFS= read -r line; do
        line="${line%$'\r'}"
        [[ "${line}" =~ ^[[:space:]]*([A-Za-z0-9_]+)[[:space:]]*=(.*)$ ]] || continue
        set_ini "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    done <<< "${PZ_INI_OVERRIDES}"
fi

# ---------------------------------------------------------------------------
# 3b. Sandbox (gameplay) options live in <name>_SandboxVars.lua, not the .ini.
#     PZ_SANDBOX_OVERRIDES is newline-separated `Key=Value`, with a dot for
#     options inside a group (`ZombieLore.Transmission=2`). Values are raw Lua
#     literals (numbers, true/false). Only the listed options are touched.
# ---------------------------------------------------------------------------
SANDBOX="${PZ_DATA}/Server/${SERVER_NAME}_SandboxVars.lua"

# set_sandbox <group or ""> <name> <value>: rewrite one option in place,
# keeping the file's comments/indentation. Exit 3 when the option isn't there.
set_sandbox() {
    SEC="$1" NAME="$2" VAL="$3" awk '
        BEGIN { sec = ""; done = 0 }
        {
            if ($0 ~ /^[ \t]*[A-Za-z0-9_]+ = \{[ \t]*$/) {
                s = $0; sub(/^[ \t]*/, "", s); sub(/ = \{.*/, "", s)
                if (s != "SandboxVars") sec = s
            } else if ($0 ~ /^[ \t]*\},?[ \t]*$/) {
                sec = ""
            } else if (sec == ENVIRON["SEC"] && index($0, ENVIRON["NAME"] " = ") > 0 \
                       && $0 ~ ("^[ \t]*" ENVIRON["NAME"] " = ")) {
                indent = $0; sub(/[^ \t].*/, "", indent)
                print indent ENVIRON["NAME"] " = " ENVIRON["VAL"] ","
                done = 1
                next
            }
            print
        }
        END { exit done ? 0 : 3 }' "${SANDBOX}" > "${SANDBOX}.tmp" \
        && mv "${SANDBOX}.tmp" "${SANDBOX}"
}

if [ -n "${PZ_SANDBOX_OVERRIDES:-}" ]; then
    sb_groups=(); sb_names=(); sb_values=()
    while IFS= read -r line; do
        line="${line%$'\r'}"
        [[ "${line}" =~ ^[[:space:]]*(([A-Za-z0-9_]+)\.)?([A-Za-z0-9_]+)[[:space:]]*=[[:space:]]*(.*[^[:space:]])[[:space:]]*$ ]] || continue
        sb_groups+=("${BASH_REMATCH[2]}"); sb_names+=("${BASH_REMATCH[3]}"); sb_values+=("${BASH_REMATCH[4]}")
    done <<< "${PZ_SANDBOX_OVERRIDES}"

    if [ -f "${SANDBOX}" ]; then
        for i in "${!sb_names[@]}"; do
            label="${sb_groups[$i]:+${sb_groups[$i]}.}${sb_names[$i]}"
            if set_sandbox "${sb_groups[$i]}" "${sb_names[$i]}" "${sb_values[$i]}"; then
                log "Sandbox: ${label} = ${sb_values[$i]}"
            else
                rm -f "${SANDBOX}.tmp"
                log "WARNING: sandbox option '${label}' not found in $(basename "${SANDBOX}") — check the name (mod options only appear after the mod has loaded once)."
            fi
        done
    else
        # Fresh world: seed a minimal file; the server fills in every other
        # option with its default and rewrites the file in full.
        log "Sandbox: seeding ${#sb_names[@]} option(s) for a new world."
        {
            echo "SandboxVars = {"
            for i in "${!sb_names[@]}"; do
                [ -z "${sb_groups[$i]}" ] && echo "    ${sb_names[$i]} = ${sb_values[$i]},"
            done
            mapfile -t sb_unique < <(printf '%s\n' "${sb_groups[@]}" | awk 'NF && !seen[$0]++')
            for group in "${sb_unique[@]}"; do
                echo "    ${group} = {"
                for i in "${!sb_names[@]}"; do
                    [ "${sb_groups[$i]}" = "${group}" ] && echo "        ${sb_names[$i]} = ${sb_values[$i]},"
                done
                echo "    },"
            done
            echo "}"
        } > "${SANDBOX}"
    fi
fi

# ---------------------------------------------------------------------------
# 4. JVM heap — lives in a game file that every update resets, so re-apply.
# ---------------------------------------------------------------------------
if [ -n "${PZ_MEMORY:-}" ]; then
    [[ "${PZ_MEMORY}" =~ ^[0-9]+[gGmM]$ ]] || die "PZ_MEMORY must look like 8g or 6144m (got '${PZ_MEMORY}')."
    sed -i -E "s/-Xmx[0-9]+[gGmM]/-Xmx${PZ_MEMORY}/" "${PZ_DIR}/ProjectZomboid64.json"
    grep -q -- "-Xmx${PZ_MEMORY}" "${PZ_DIR}/ProjectZomboid64.json" \
        || log "WARNING: could not set -Xmx in ProjectZomboid64.json; server will use its default heap."
fi

# ---------------------------------------------------------------------------
# 5. Assemble the server command line
# ---------------------------------------------------------------------------
if [ ! -f "${PZ_DATA}/db/${SERVER_NAME}.db" ] && [ -z "${PZ_ADMIN_PASSWORD:-}" ]; then
    die "First boot needs PZ_ADMIN_PASSWORD (the server would otherwise wait forever at a password prompt)."
fi

args=(
    "-cachedir=${PZ_DATA}"
    -servername "${SERVER_NAME}"
    -adminusername "${PZ_ADMIN_USERNAME:-admin}"
)
[ -n "${PZ_ADMIN_PASSWORD:-}" ] && args+=(-adminpassword "${PZ_ADMIN_PASSWORD}")
# shellcheck disable=SC2206
[ -n "${PZ_EXTRA_ARGS:-}" ] && args+=(${PZ_EXTRA_ARGS})

# ---------------------------------------------------------------------------
# 6. Run. The server only saves cleanly when told to `quit` on its console,
#    so its stdin is a FIFO and SIGTERM/SIGINT are translated into that command.
# ---------------------------------------------------------------------------
# The FIFO sits on the volume (not /tmp) so the backup job, which mounts the
# same volume, can ask a running server to `save`.
fifo="${PZ_DATA}/console.fifo"
rm -f "${fifo}"
mkfifo "${fifo}"
exec 3<>"${fifo}"

# When startup fails (typically a broken/outdated mod) the game logs
# "Server Terminated." but the JVM never exits, which would leave a dead
# container looking healthy. Poll the game's own console log for that line;
# the marker file tells this boot's log apart from a stale one.
console_log="${PZ_DATA}/server-console.txt"
boot_marker=/tmp/pz-boot-marker
touch "${boot_marker}"

cd "${PZ_DIR}"
log "Starting server '${SERVER_NAME}' (data: ${PZ_DATA}, heap: ${PZ_MEMORY:-default})"
# setsid -> own process group, so the whole launcher+JVM tree can be killed.
setsid ./start-server.sh "${args[@]}" "$@" <&3 &
server_pid=$!

shutdown() {
    log "Stop signal received — sending 'quit' so the world is saved..."
    echo quit >&3
}
trap shutdown TERM INT

# `wait` returns early when a trapped signal arrives; keep polling until the
# server process has really exited.
rc=0
version_checked=false
while kill -0 "${server_pid}" 2>/dev/null; do
    # Report the build that actually booted, and flag a pinned label that
    # doesn't match it (Steam moved on, or the label was mistyped).
    if [ "${version_checked}" = "false" ] && [ "${console_log}" -nt "${boot_marker}" ]; then
        actual="$(grep -m1 -oE 'version=[0-9]+(\.[0-9]+)+' "${console_log}" 2>/dev/null | cut -d= -f2 || true)"
        if [ -n "${actual}" ]; then
            version_checked=true
            if [ "${PZ_VERSION}" = "latest" ] || [[ "${actual}" == "${PZ_VERSION}"* ]]; then
                log "Running Project Zomboid ${actual}."
            else
                log "WARNING: PZ_VERSION is '${PZ_VERSION}' but the installed build is ${actual}. Steam only offers the newest build of a branch — set the version to ${actual} (or pick a branch with PZ_BETA_BRANCH)."
            fi
        fi
    fi
    if [ "${console_log}" -nt "${boot_marker}" ] && grep -q 'Server Terminated\.' "${console_log}"; then
        log "Server reported 'Server Terminated.' but did not exit — see the errors above. Killing it."
        sleep 5
        kill -KILL -- "-${server_pid}" 2>/dev/null || true
        wait "${server_pid}" 2>/dev/null || true
        exit 1
    fi
    sleep 5 &
    wait $! || true
done
wait "${server_pid}" && rc=0 || rc=$?
log "Server exited with code ${rc}."
exit "${rc}"
