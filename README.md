# Project Zomboid Dedicated Server (self-updating, Workshop mods)

A small container image plus Helm chart for a Project Zomboid dedicated server that:

- **installs Project Zomboid at startup, onto the volume** — nothing is baked into the image, and the install is downloaded once and then cached
- **lets a chart variable decide the version**: `latest` to always track the current build, or a label such as `42.21.0` to hold a build until you bump it
- **takes a list of Steam Workshop IDs** and works out the mod IDs (and map folders) itself
- saves the world cleanly on `docker stop` / pod termination
- exits (so it gets restarted and is visibly failing) when a broken mod kills the game at startup

Verified 2026-10-10 against Build **42.21.0** on Docker Desktop: fresh install, modded boot, clean stop.

## How a boot works

```
container start
   |
   1. chown volume (root) -> drop to `steam`
   2. SteamCMD: app_update 380870        <- skipped when the pinned version is already installed
   3. look up Steam "Required items"     <- dependencies added automatically
      SteamCMD: download Workshop items  <- only when mod IDs must be discovered
        read id= from each mod.info      -> Mods=
        find media/maps/*/map.info       -> Map=
   4. write managed keys into <name>.ini
   5. set JVM heap in ProjectZomboid64.json
   6. run server (stdin = FIFO)
        SIGTERM -> "quit" -> world saved -> exit 0
        "Server Terminated." in log -> kill -> exit 1
```

Everything stateful is on **one volume** at `/home/steam/pz`:

| Path | Contents |
|---|---|
| `server/` | game install (~7 GB) + downloaded Workshop content |
| `data/` | `Server/<name>.ini`, sandbox vars, saves, logs, player db |

The first boot downloads ~7 GB. Later boots only fetch what changed.

## Game version and the cached install

The game is never re-downloaded on a restart: it sits in `server/` on the volume. `server.version` decides when SteamCMD may change it.

| `server.version` | On each start |
|---|---|
| `latest` (default) | SteamCMD checks Steam and applies any update (a few seconds when there is none) |
| a label, e.g. `"42.21.0"` | SteamCMD is skipped entirely while the label matches the one recorded on the volume |

- To update a pinned server, change the label and restart. SteamCMD then installs the **newest** build of the branch.
- Steam cannot serve an older build, so a label can't downgrade or fetch a specific past version. The boot log prints `Running Project Zomboid <version>` and warns when that isn't the label you set.
- `server.betaBranch` picks a different Steam branch (e.g. `legacy41`); changing it also triggers an install.
- Workshop mods are still refreshed on every start, because players' copies update automatically and must match.

## Mods

Give it Workshop IDs — the number at the end of a Workshop URL
(`steamcommunity.com/sharedfiles/filedetails/?id=`**`2544353492`**).

| You set | Result |
|---|---|
| `workshopIds` only | Every mod inside each item is enabled; map mods are detected and put before `Muldraugh, KY` |
| `workshopIds` + `modIds` | Exactly those mod IDs are enabled (use this to pick one mod out of a multi-mod item). The server downloads the items itself; no map auto-detection |
| `excludeModIds` | Drops those mod IDs from the auto-discovered list (optional sub-mods of a multi-mod item) |
| `maps` | Overrides the detected map list (`Muldraugh, KY` is always appended) |
| nothing | `Mods=` / `WorkshopItems=` are cleared — the list is the source of truth |

Things to know:

- **Read the boot log after changing mods.** The `[entrypoint]` lines list what each item resolved to and warn about the three common problems:
  - *missing dependency* — `'KI5trailers' requires mod 'damnlib', which is not in the list`. Normally you won't see this: Steam's "Required items" are added for you (see below). It appears when that lookup failed or the author never declared the requirement on Steam; add the Workshop ID yourself.
  - *Build 41-only mod* — `has no Build 42 folder — it will NOT load`. The server boots, but without that mod. Look for a Build 42 version on the Workshop.
  - *multi-mod item* — `item ... holds 4 mods and ALL are enabled`. Items like More Traits bundle optional toggles; drop the ones you don't want with `excludeModIds`.
- **Dependencies are added automatically.** Each item's Steam "Required items" (and theirs) are looked up on its public Workshop page and installed ahead of the item that needs them; the boot log says `requires Workshop item ... — adding it`. Turn it off with `resolveDependencies: false`. Every mod inside a pulled-in item is enabled, so `excludeModIds` applies to those too.
- Build 42 mod IDs can differ from the Build 41 ones inside the same item (e.g. `1299328280/ToadTraits` vs `ToadTraits`). Discovery uses the Build 42 ID when a version folder exists.
- **Order matters.** List library mods before the mods that need them.
- **Build 41-only mods crash a Build 42 server.** The container then exits with code 1 and the Lua/script error is in the log just above `Server Terminated.` Example seen in testing: `2875848298` (Common Sense) fails on 42.21.
- Add mods a few at a time, and back up the volume before changing the list on a world you care about.
- Mod IDs are written without a backslash prefix (correct for 42.21). If a future build wants one, set `PZ_MOD_ID_PREFIX='\'`.
- Set `PZ_MANAGE_MODS=false` (`mods.manage: false`) to hand-edit the `.ini` instead.

## Gameplay (sandbox) settings

Zombie behaviour, loot, alarms and the like live in `data/Server/<name>_SandboxVars.lua`, not the `.ini`. Set them with `sandbox:` in Helm values:

```yaml
sandbox:
  CharacterFreePoints: 8
  Alarm: 3                 # Rare
  ZombieLore:
    Transmission: 2        # Saliva Only
    TriggerHouseAlarm: false
```

- Only the listed options change; they are re-applied on every start, so the values file wins over in-game admin edits.
- That `.lua` file documents every option name and what each number means — read it off the volume to find the one you want.
- A misspelt option is reported in the boot log (`sandbox option '...' not found`) and skipped.
- A mod's own sandbox options only exist in the file after the mod has loaded once, so they take effect from the second boot.

## Run locally (Docker)

```bash
docker compose up -d --build
```

```bash
docker compose logs -f
```

Ready when the log shows `*** SERVER STARTED ****`. Connect to `localhost:16261`.
Set `PZ_ADMIN_PASSWORD` in your shell or a `.env` file first — the compose default is `changeme`.

## Deploy with Helm

The server is **amd64-only** (no ARM build); the chart pins `kubernetes.io/arch: amd64`.

Both the image and the chart are published to GitHub Container Registry:

| Artifact | Location |
|---|---|
| Image | `ghcr.io/mathewulanowski/zomboid-server` (`latest`, short-SHA and release tags) |
| Chart | `oci://ghcr.io/mathewulanowski/charts/zomboid` |

The chart already points at the published image. Install straight from the registry:

```bash
helm install zomboid oci://ghcr.io/mathewulanowski/charts/zomboid -n zomboid --create-namespace -f my-values.yaml
```

Or from a clone of this repo:

```bash
helm upgrade --install zomboid ./charts/zomboid -n zomboid --create-namespace -f my-values.yaml
```

To use your own build instead, push it anywhere your cluster can pull from and set `image.repository` / `image.tag`
(add `imagePullSecrets` for a private registry). On k3s you can also skip the registry and import the image onto the node:

```bash
docker save zomboid-server:latest | ssh <node> "sudo k3s ctr images import -"
```

Example `my-values.yaml`:

```yaml
server:
  publicName: "My Zomboid Server"
  maxPlayers: 16
  memory: 8g
  iniOverrides:
    PVP: false
    PauseEmpty: true
mods:
  workshopIds:
    - 2544353492   # Has Been Read
    - 2847184718   # Proximity Inventory
```

Changing the mod list is just editing `mods.workshopIds` and re-running that command, then restarting the pod.

### Helm values

| Value | Default | Purpose |
|---|---|---|
| `server.name` | `servertest` | Config-set / save name. Changing it starts a new world |
| `server.publicName` | `""` | Name in the server browser |
| `server.maxPlayers` | `16` | |
| `server.memory` | `8g` | JVM heap. Keep `resources.limits.memory` ~2Gi above it |
| `server.version` | `latest` | `latest` = update on every boot; a label like `42.21.0` = hold the installed build until the label changes |
| `server.validateOnStart` | `false` | Also re-verify every game file (slow; repairs a corrupt install) |
| `server.betaBranch` | `""` | Steam branch, e.g. `legacy41`; empty = current stable |
| `server.iniOverrides` | `{}` | Any `Key: value` for the server `.ini`, applied last |
| `sandbox` | `{}` | Gameplay options for `<name>_SandboxVars.lua`; nest one level for groups (`ZombieLore: { Transmission: 2 }`) |
| `auth.adminPassword` | `""` | Empty = random, generated once and kept |
| `auth.serverPassword` | `""` | Password players need to join |
| `auth.rconPassword` | `""` | Setting it enables RCON in the `.ini` |
| `auth.existingSecret` | `""` | Use your own Secret (`admin-password`, `server-password`, `rcon-password`) |
| `mods.workshopIds` | `[]` | Workshop item IDs |
| `mods.modIds` | `[]` | Explicit mod IDs; empty = auto-discover |
| `mods.excludeModIds` | `[]` | Mod IDs to drop from the auto-discovered list |
| `mods.resolveDependencies` | `true` | Also install each item's Steam "Required items" |
| `mods.maps` | `[]` | Explicit map folders; empty = auto-discover |
| `mods.manage` | `true` | `false` = leave mod lines in the `.ini` alone |
| `persistence.size` | `30Gi` | Game install + mods + saves |
| `service.type` | `LoadBalancer` | Exposes 16261/udp + 16262/udp |
| `service.rcon.enabled` | `false` | Also expose 27015/tcp |

Read the generated admin password:

```bash
kubectl -n zomboid get secret zomboid -o jsonpath='{.data.admin-password}' | base64 -d
```

## Environment variables (image)

| Variable | Default | Purpose |
|---|---|---|
| `PZ_SERVER_NAME` | `servertest` | Config-set / save name |
| `PZ_ADMIN_USERNAME` | `admin` | |
| `PZ_ADMIN_PASSWORD` | — | **Required on first boot** |
| `PZ_SERVER_PASSWORD` | — | Join password |
| `PZ_PUBLIC_NAME` | — | Server browser name |
| `PZ_MAX_PLAYERS` | — | |
| `PZ_MEMORY` | game default | JVM heap, e.g. `8g` |
| `PZ_VERSION` | `latest` | `latest`, or a label that holds the installed build |
| `PZ_VALIDATE_ON_START` | `false` | |
| `PZ_BETA_BRANCH` / `PZ_BETA_PASSWORD` | — | Steam branch |
| `PZ_WORKSHOP_IDS` | — | Separated by `;` or `,` |
| `PZ_MOD_IDS` | — | Separated by `;` or `,`; empty = auto-discover |
| `PZ_MOD_IDS_EXCLUDE` | — | Mod IDs to drop from auto-discovery |
| `PZ_RESOLVE_DEPENDENCIES` | `true` | Also install each item's Steam "Required items" |
| `PZ_MAPS` | — | Separated by `;` only (names contain commas) |
| `PZ_MANAGE_MODS` | `true` | |
| `PZ_MOD_ID_PREFIX` | — | Prepended to each mod ID |
| `PZ_PORT` / `PZ_UDP_PORT` | `16261` / `16262` | |
| `PZ_RCON_PASSWORD` / `PZ_RCON_PORT` | — / `27015` | |
| `PZ_INI_OVERRIDES` | — | Newline-separated `Key=Value` lines |
| `PZ_SANDBOX_OVERRIDES` | — | Newline-separated `Key=Value` / `Group.Key=Value` sandbox options |
| `PZ_EXTRA_ARGS` | — | Extra server command-line args |

## Ports

| Port | Protocol | Purpose |
|---|---|---|
| 16261 | UDP | Game (what players connect to) |
| 16262 | UDP | Direct connection |
| 27015 | TCP | RCON (optional) |

## Backups

Turn on the scheduled backup in Helm values:

```yaml
backup:
  enabled: true
  schedule: "0 10 * * *"     # nightly, cluster time (usually UTC)
  keep: 7
  hostPath: /root/backups/zomboid
```

Each run asks the running server to save, archives the data folder to `<hostPath>/<server.name>-<date>.tgz`, checks the archive, and deletes all but the newest `keep`. The archive holds the world, player database, `.ini` and sandbox file — not the game install or mods, which re-download.

Run one right now:

```bash
kubectl -n zomboid create job --from=cronjob/zomboid-backup manual-backup
```

Things to know:

- Archives sit **on the same node as the world**. Copy them off the machine if losing it matters.
- Files directly in `hostPath` named `<server.name>-*.tgz` are rotated. Put anything you want kept forever in a sub-folder (e.g. `manual/`).
- With players online, some files change while being archived. The run notes it and the archive is still usable, but a quiet hour gives the cleanest copy.
- If the server is stopped, the run still archives what is on disk.

Restore (the server must be stopped so it doesn't overwrite the files):

```bash
kubectl -n zomboid scale sts zomboid --replicas=0
```

Then, on the node, replace the `data` folder inside the server's volume with the one from the archive (`tar -xzf <archive> -C <volume dir>`), make sure it is owned by uid 1000, and scale back to 1.

## Good to know

- **`version: latest` means clients must be current too.** A game update applies on the next pod restart, not while the server is running.
- **A pinned version works the other way round:** Steam updates players' games automatically, so after a game release they can't join until you bump `server.version` and restart.
- **Major builds can break saves** (41 -> 42 did). Pin `server.version` and back up the volume before bumping it across a big release.
- The log is noisy with vanilla `ERROR`/`WARN` lines (`ThumpSound`, `libjsig.so`, duplicate textures). Those are normal; `*** SERVER STARTED ****` is the line that matters.
- No Kubernetes probes are defined: the game ports are UDP and the first boot can take many minutes.

## Building and releasing

| Workflow | Runs on | Publishes |
|---|---|---|
| `build.yml` | push to `main` touching the image files, `v*` tags | the image (`latest`, short SHA, semver on tags) |
| `chart.yml` | push to `main` touching `charts/` | `helm lint` on every change; packages and pushes the chart at the version in `Chart.yaml` |

Pull requests run the image build and `helm lint` but publish nothing. Bump `version` in `Chart.yaml` for each chart change.

## License

[MIT](LICENSE). Project Zomboid is a trademark of The Indie Stone; this project is not affiliated with or endorsed by
them. The image downloads the free dedicated server (Steam app 380870) at startup and does not redistribute any game files.
