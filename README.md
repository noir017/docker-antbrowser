# docker-antbrowser

Run [Ant Browser](https://github.com/black-ant/Ant-Browser) in a container and use it
from a browser over noVNC. Built after [noir017/docker-brave](https://github.com/noir017/docker-brave).

Ant Browser is a Wails desktop app (GTK3 + WebKit2GTK), not a web service — it needs a
real X display. This image puts it on a TurboVNC display served through noVNC, using
[`ich777/novnc-baseimage`](https://github.com/ich777/docker-novnc-baseimage) as the base.

- Image: `ghcr.io/noir017/ant-browser:latest` (public, `linux/amd64` + `linux/arm64`)
- Built by GitHub Actions from source — the app is never compiled on the target host

## Quick start

```bash
mkdir -p /mnt/cache/appdata/antbrowser/data
cd /mnt/cache/appdata/antbrowser
curl -fsSLO https://raw.githubusercontent.com/noir017/docker-antbrowser/master/deploy/docker-compose.yml
curl -fsSL  https://raw.githubusercontent.com/noir017/docker-antbrowser/master/deploy/.env.example -o .env
$EDITOR .env          # at minimum, set ANT_IP to a free address on your LAN
docker compose up -d
```

Then open `http://<ANT_IP>:8080` **from another machine on the LAN** — an ipvlan
container is not reachable from its own host by L2 design unless a shim interface
is configured.

## Layout

```
image (read-only)   /opt/ant-browser/{ant-chrome, config.yaml, bin/xray, bin/sing-box, chrome/}
host (writable)     ./data  ->  /user/.local/share/ant-browser
                                 ├── config.yaml        seeded on first run
                                 ├── data/app.db        instances, proxies, scripts
                                 ├── data/<profile>/    per-instance browser profiles
                                 ├── chrome/            browser cores (you supply these)
                                 └── logs/
```

Only one directory is mounted. `/opt/ant-browser` stays root-owned and read-only, which
makes the app relocate its writable state to `$XDG_DATA_HOME/ant-browser` and seed
`config.yaml` and `chrome/` there on first run — see `backend/internal/apppath/apppath.go`
in the app repo. `bin/` always resolves against the install root, so `xray` and `sing-box`
ship with the image and update with it.

Do not bind-mount `config.yaml` on its own: the app rewrites it, and a single-file
bind mount breaks when the inode is replaced.

## Installing a browser core

The image ships **no Chromium core** — upstream releases only include a placeholder
README under `chrome/`. Without a core the UI starts fine but instances cannot launch.

```bash
cd /mnt/cache/appdata/antbrowser/data/chrome
curl -fsSLO https://github.com/adryfish/fingerprint-chromium/releases/download/148.0.7778.215/ungoogled-chromium-148.0.7778.215-1-x86_64_linux.tar.xz
tar -xJf ungoogled-chromium-*.tar.xz
mv ungoogled-chromium-*-x86_64 fp-148
rm ungoogled-chromium-*.tar.xz

docker exec antbrowser antctl core ls    # confirm the executable is detected
```

Then in the UI: **内核管理 → 新增**, path `chrome/fp-148`, backend
`fingerprint-chromium`, mark it default.

For the Cloak backend, register a directory containing `chromium-<version>/` instead, and
put `CLOAKBROWSER_LICENSE_KEY=...` in the core's environment-variables field.

## `antctl`

Manage the app from the host. Ant Browser handles its own browser instances, so this
covers the app process and the pieces around it.

```bash
docker exec antbrowser antctl status
docker exec antbrowser antctl restart
docker exec antbrowser antctl logs -f
docker exec antbrowser antctl api /api/profiles
docker exec antbrowser antctl core ls
docker exec antbrowser antctl unlock       # after an unclean shutdown
```

## Launch API

The app's Launch API listens on `127.0.0.1:19876` and rejects every caller whose
`RemoteAddr` is not `127.0.0.1`. With `ANT_API_RELAY=1` a socat relay inside the
container forwards `:19877` to it, which re-originates the connection locally:

```bash
curl http://192.168.2.201:19877/api/health      # {"ok":true}
curl http://192.168.2.201:19877/api/profiles
curl http://192.168.2.201:19877/json/version    # CDP of the active instance
```

**This intentionally bypasses the app's localhost-only restriction.** Anyone who can
reach the port can create instances, launch them, and attach a debugger. Set
`ANT_API_RELAY=0` to turn it off, or enable API-key auth (`launch_server.auth`) in the
app's settings page before leaving it exposed.

## Environment

| Variable | Default | Purpose |
|---|---|---|
| `TZ` | `Asia/Shanghai` | Timezone |
| `CUSTOM_RES_W` / `CUSTOM_RES_H` | `1600` / `900` | Display size; floored at 1280x800 |
| `CUSTOM_DEPTH` | `24` | Colour depth |
| `NOVNC_PORT` / `RFB_PORT` | `8080` / `5900` | noVNC / VNC ports |
| `NOVNC_RESIZE` | `scale` | `off`, `scale`, `remote` |
| `NOVNC_QUALITY` / `NOVNC_COMPRESSION` | `6` / `2` | noVNC tuning, 0-9 |
| `ANT_AUTOSTART` | `1` | Start the GUI on boot |
| `ANT_API_RELAY` | `1` | Expose the Launch API to the LAN |
| `ANT_API_RELAY_PORT` | `19877` | Relay listen port |
| `UID` / `GID` / `UMASK` | `99` / `100` / `000` | Unraid `nobody:users` |

## Building

CI checks out the container definition and the app source separately, builds with the
app's own `publish/linux/publish-linux.sh`, and pushes to GHCR. Run it manually to pick a
different source ref:

```bash
gh workflow run build.yml -f app_ref=v1.6.0 -f image_tag=1.6.0
```

## Notes

- **amd64 + arm64.** Each architecture builds on a native runner (`ubuntu-24.04-arm` for arm64); cross-building the Wails/CGO binary is unreliable. The app tarball/.deb of every build is attached to the workflow run as an artifact. Images built before 2026-10-09 are amd64 only.
- **VNC server differs by arch.** amd64 uses the base image's TurboVNC. ich777's arm64 base has no TurboVNC and its x11vnc is broken (links `libssl.so.1.1`), so arm64 installs Debian's TigerVNC and runs `Xtigervnc` directly.
- **ipvlan L2.** Verify from a separate LAN host, not from the Docker host itself.
- **`shm_size: 2gb`.** The base image defaults to 64M and Chromium renderers crash on it.
- **`seccomp=unconfined`.** Chromium's sandbox needs syscalls the default profile blocks.

## Migrating from a Brave container

Brave profiles are plain Chromium user-data-dirs, so they transfer directly. If both
trees sit on the same btrfs pool, `deploy/migrate-brave.sh` copies them with
`--reflink=always`: 18G of profiles migrate in seconds and cost no extra disk, and the
originals stay untouched as a rollback path.

```bash
./migrate-brave.sh --dry-run                                  # inventory first
./migrate-brave.sh --core-id <id> --preserve-ua               # copy + register
./migrate-brave.sh --core-id <id> --only wlxbpc1              # one profile
```

Cookies survive because Linux Chromium encrypts them with a key derived from a
hardcoded passphrase (the `v10` tag) whenever no keyring is present — as in these
images. `v11` cookies would be bound to a keyring and would *not* survive.
Verify decryption in the running browser, not just on disk:

```bash
python3 deploy/verify-cookies.py <debug-port> <browser-ws-path>   # VERDICT=DECRYPT_OK
```

`--preserve-ua` keeps the spoofed user agent the profile's cookies were issued under
and skips Ant Browser's own fingerprint args. Without it the cookies still load but
UA, canvas and platform all change at once, which can trigger re-verification.

Not migrated: Brave-specific prefs (Shields, Wallet, Rewards) and proxy settings —
Brave took a `--proxy-server` flag, Ant Browser manages proxies itself.

Note that launching a migrated profile mutates it (Chromium expires stale cookies and
rewrites `Last Version`), so the copy stops being byte-identical to the original after
first run. That is expected; the originals are never written to.

### Migrating extensions

Extensions are **not** carried by the profile copy alone. A profile stores an
extension's *data* (userscripts, settings) but not its *code*, and it keys that data
to the extension ID.

For an unpacked extension (`--load-extension`, `location: 4` in `Preferences`), the
manifest usually has no `key` field, so Chromium derives the ID from the install path:

```
extension_id = sha256(absolute_install_path)[:32], mapped 0-9a-f -> a-p
```

So the path is load-bearing. Loading the same code from a different directory produces
a different ID, and the migrated profile data — keyed to the old ID — is invisible.
Verified on this deployment:

| Install path | Resulting ID |
|---|---|
| `/opt/scripts/tampermonkey_stable` (Brave) | `flnphpojdiemllbjcohodppdogbampon` |
| `…/data/extensions/flnphpojdiemllbjcohodppdogbampon` | `djecknifepohipedmifabgkaphndcjgo` |

Mount the code at the path the source browser used, then register it:

```bash
# 1. stage the unpacked extension on the host
cp -a /mnt/cache/appdata/braveScripts/tampermonkey_stable \
      /mnt/cache/appdata/antbrowser/extensions/
chown -R 99:100 /mnt/cache/appdata/antbrowser/extensions

# 2. bind-mount it at the ORIGINAL container path (see docker-compose.yml)
#    - .../extensions/tampermonkey_stable:/opt/scripts/tampermonkey_stable:ro

# 3. register it, with install_dir set to the container path
docker exec antbrowser antctl stop
sqlite3 .../data/data/app.db "INSERT INTO browser_extensions
  (extension_id,name,version,manifest_json,install_dir,enabled,installed_at,updated_at)
  VALUES ('<id>','Tampermonkey','5.2.3','{}','/opt/scripts/tampermonkey_stable',1,
          datetime('now'),datetime('now'));"
```

Then bind it per profile — `browser_profile_extensions` (`profile_id`, `extension_id`)
plus a `browser_profile_extension_settings` row with `configured=1`. The app turns those
into `--load-extension` / `--disable-extensions-except` at launch
(`backend/app_instance_start_prepare.go`).

Confirm from inside the browser, not from the filesystem — the extension must be able to
*read* its storage:

```bash
curl -s http://127.0.0.1:<debug-port>/json | jq -r '.[]|select(.type=="service_worker")|.url'
# chrome-extension://<id>/background.js  <- must be the ORIGINAL id
```

An ID mismatch shows up as a working-but-empty extension: `chrome-extension://<old-id>/…`
fails with `ERR_BLOCKED_BY_CLIENT` while the dashboard offers only `<New userscript>`.

Extensions installed from the Web Store (`location: 1`) behave differently — their code
lives in `Default/Extensions/<id>/` inside the profile and their ID comes from the store
signing key, so those *do* travel with a profile copy.
