# Project Zomboid Dedicated Server
#
# Unlike a "bake the game in" image, this one ships NO game files. The
# entrypoint installs/updates the OFFICIAL dedicated server (SteamCMD app
# 380870, anonymous login) into the mounted volume on every start, so the
# server always tracks the current Project Zomboid build without rebuilding
# or re-tagging the image. The server binary is x86-64 only -> amd64 image.
#
# Everything stateful lives on ONE volume at /home/steam/pz:
#   server/  game install + downloaded Steam Workshop content
#   data/    the "Zomboid" folder: server .ini, saves, logs, player db
#
# Base: cm2network/steamcmd ships SteamCMD + the 32/64-bit runtime libs and a
# non-root `steam` user (uid 1000). The game bundles its own Java runtime.
FROM cm2network/steamcmd:root

LABEL org.opencontainers.image.title="Project Zomboid Dedicated Server" \
      org.opencontainers.image.description="Self-updating Project Zomboid dedicated server (SteamCMD app 380870) with Steam Workshop mod support" \
      org.opencontainers.image.source="https://pzwiki.net/wiki/Dedicated_server" \
      org.opencontainers.image.licenses="Proprietary-ProjectZomboid"

ENV PZ_DIR=/home/steam/pz/server \
    PZ_DATA=/home/steam/pz/data \
    DEBIAN_FRONTEND=noninteractive

# gosu for clean privilege drop at runtime (present-or-install, base is Debian)
RUN set -eux; \
    if ! command -v gosu >/dev/null 2>&1; then \
        apt-get update; \
        apt-get install -y --no-install-recommends gosu; \
        rm -rf /var/lib/apt/lists/*; \
    fi

# Pre-create the install/data dirs owned by the steam user.
RUN mkdir -p "${PZ_DIR}" "${PZ_DATA}" \
    && chown -R steam:steam /home/steam/pz

COPY entrypoint.sh pz-backup.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/pz-backup.sh

# 16261 game, 16262 direct connection (both UDP); 27015 RCON (TCP, optional)
EXPOSE 16261/udp 16262/udp 27015/tcp

VOLUME ["/home/steam/pz"]

# Entrypoint starts as root (to chown the volume), then re-execs as `steam`.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
