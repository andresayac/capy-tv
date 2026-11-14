# Capy TV sync server

Keeps a user's playlists, favorites and watch progress the same on all their devices. It is
optional: the app works fully without it.

The server only ever stores **encrypted blobs**. The app encrypts everything on the device before
sending it, with keys the server only ever gets locked with the user's password or recovery key,
neither of which leaves the device. The server cannot read IPTV credentials, playlist URLs,
favorites or history, and cannot tell which item is which.

One static Go binary with SQLite built in. It needs no runtime and no CGO, and the Docker image is
about 16 MB.

## How the encryption works

An account's data are encrypted with two random keys, made on the device that creates the
account:

- the **encryption key**: AES-256-GCM for every item, after gzip, with the item id as associated
  data, so the server cannot swap one item for another;
- the **id key**: HMAC that names items, so ids reveal nothing.

Then, on each device, from the email and password:

| Step | Result |
|---|---|
| Argon2id (64 MiB, 3 passes), salt derived from the email | master key (stays on the device) |
| HKDF(master, `auth`) | **auth key**: sent to the server to sign in, in place of the password |
| HKDF(master, `wrap`) | **wrap key**: locks the two account keys (AES-256-GCM); never sent |

The account also gets a **recovery key**: 160 random bits, shown to the user once, as 32
letters and digits to write down. HKDF gives it an auth key and a wrap key of its own.

The server keeps a salted HMAC of each auth key (never the keys), and the account keys locked
twice: with the password's wrap key and with the recovery key's. Signing in hands back the copy
locked with the secret used. So:

- **changing the password** locks the same account keys again with the new one: nothing is
  re-encrypted, and the other devices sign in again with it;
- **a forgotten password** is replaced with the recovery key, and everything synced stays
  readable;
- **a new recovery key** replaces the old one, which stops working.

Both take the current password or the recovery key, not just a session, and both are limited
like signing in.

If the database leaks, it exposes:

- emails, device names, and when each device was last seen;
- the number of items and their sizes.

Guessing a password costs one Argon2id run per guess; the recovery key cannot be guessed. If a
user loses both the password and the recovery key, nobody can recover what was synced, not even
the server owner. Each device still keeps its own copy.

## Run it

### With Docker and automatic HTTPS (Caddy)

Point a DNS name at the machine, with ports 80 and 443 open, then write the settings once, in a
`.env` file beside `docker-compose.yml`, so every later `docker compose up` (an update) keeps them:

```sh
cp .env.example .env    # then set SYNC_DOMAIN and SIGNUP_CODE in it
docker compose up -d --build
```

Caddy gets and renews the Let's Encrypt certificate. The data lives in the `sync-data` volume.
With `SIGNUP_CODE`, only people you give the code to can create an account (they type it when
creating it in the app). Empty, nobody can make a new one (those there are keep working), unless
`SIGNUP_OPEN=1`: then anyone who finds the server can. Compose refuses to start with no
`SIGNUP_CODE` at all, so you say which on purpose.

### Behind a reverse proxy you already run

Publish the container on localhost only, and let the proxy handle HTTPS. Each release publishes
the image, for amd64 and arm64 (a Raspberry Pi too):

```sh
docker run -d --name capy-tv-sync --restart unless-stopped \
  -p 127.0.0.1:8080:8080 -e TRUST_PROXY=1 -e SIGNUP_CODE=a-code-you-share \
  -v capy-tv-sync:/data ghcr.io/andresayac/capy-tv-sync:latest
```

To build it yourself instead: `docker build -t capy-tv-sync .` in this folder, and `capy-tv-sync`
as the image above.

For nginx, WebSockets need the upgrade headers:

```nginx
location / {
    proxy_pass http://127.0.0.1:8080;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_read_timeout 1h;
    client_max_body_size 16m;
}
```

The server takes the last `X-Forwarded-For` address as the client's, for its limits (sign-ins,
install codes, the phone bridge). With Cloudflare in front of nginx, that would be Cloudflare's own
address, shared by everyone who comes through the same Cloudflare node: tell nginx to take the
visitor's from Cloudflare, in the `server` block, with one `set_real_ip_from` for each range on
[cloudflare.com/ips](https://www.cloudflare.com/ips/):

```nginx
set_real_ip_from 173.245.48.0/20;   # ...and the others, IPv4 and IPv6
real_ip_header CF-Connecting-IP;
```

`$remote_addr` is then the visitor's address. Caddy and Traefik pass WebSockets through without
extra configuration.

### Without Docker

```sh
go build -o sync-server .                              # this machine
GOOS=linux GOARCH=arm64 go build -o sync-server .     # e.g. a Raspberry Pi, from any OS
./build_release.sh                                    # both Linux ones, into ../release/sync/
```

`build_release.sh` leaves `sync-server-linux-amd64` and `sync-server-linux-arm64` in
`release/sync/` at the repository root, beside the app's release in `release/app/`, with the source
they came from and their commit.

A systemd unit:

```ini
[Unit]
Description=Capy TV sync server
After=network.target

[Service]
ExecStart=/opt/iptv-sync/sync-server
# On this machine only, for the proxy in front: trusting its X-Forwarded-For is safe only so
Environment=HOST=127.0.0.1 PORT=8080 DATA=/var/lib/iptv-sync/sync.db TRUST_PROXY=1
Environment=SIGNUP_CODE=a-code-you-share
DynamicUser=yes
StateDirectory=iptv-sync
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

## Configuration

| Variable | Default | |
|---|---|---|
| `PORT` | `8080` | `0` picks a free port and prints it at startup |
| `HOST` | all addresses | The address to listen on. `127.0.0.1` when a proxy on the same machine is the way in (as with `TRUST_PROXY`) |
| `DATA` | `data/sync.db` | SQLite file. `:memory:` keeps nothing (tests) |
| `TRUST_PROXY` | off | Set to `1` (or `true`) only when the server is reachable **only** through your proxy: `HOST=127.0.0.1`, a container published on `127.0.0.1`, or a firewall. Rate limits then use the last `X-Forwarded-For` address. The server says at startup whether it is on |
| `SIGNIN_LIMIT` | `10` | Sign-up and sign-in attempts per minute, per address and per email. Failed sign-ins to one account from one network also stop at 30 an hour and 100 a day |
| `SIGNUP_CODE` | none | Invitation code needed to create an account. With none, no new accounts are made (unless `SIGNUP_OPEN`); those there are keep working |
| `SIGNUP_OPEN` | off | `1` (or `true`) with no `SIGNUP_CODE`: anyone who reaches the server can create an account. The server says at startup which it is |
| `MAX_DATA_MB` | `2048` | The whole database's cap. Past it no new accounts nor more data are taken (the devices say to ask you for space); what is there stays, and deleting still works. `0` is no limit |
| `MAX_ACCOUNTS` | `0` (none) | No more accounts than this are created: a cap for a server open to anyone. A device asking past it is told the server says no |
| `QUOTA_MB` | `50` | Space per account for all its items. `0` is no limit |
| `SESSION_DAYS` | `180` | Devices unused for this many days are signed out. `0` is never |
| `AI_MODEL` | none | A language model for the recommendations each profile gets. None: the server offers no AI |
| `AI_BASE_URL` | `https://ollama.com/v1` | Any service with the OpenAI chat completions API: Ollama (cloud or your own), OpenAI, OpenRouter, vLLM... |
| `AI_API_KEY` | none | The service's key. It stays on the server: devices never get it |
| `AI_PER_HOUR` | `30` | Requests to the model per account and hour, so nobody runs through your quota |
| `AI_PER_HOUR_TOTAL` | `300` | Requests to the model from all accounts together in an hour; `0` for no such cap |
| `AI_MAX_TOKENS` | `4000` | The longest answer asked of the model: room for a reasoning model and the picks, not for a chat |
| `APP_DIR` | `app` beside `DATA` (`/data/app` in Docker) | The app's releases, for devices to update themselves: see [App updates](#app-updates) |

### Recommendations through the server

With `AI_MODEL` set, devices signed in to an account here get recommendations from that model
without setting anything up and without the key, which only the server has. A device asks
`GET /v1/ai` when it signs in; if the server offers no model, the app shows no recommendations
(unless the device has a service of its own, set up in Account, which comes first).

This is the one exception to the server not being able to read what devices send: to get
recommendations, a device sends the titles the profile watched and a list of candidates, and
the server forwards them to the model in the clear. It neither stores nor logs them, and it is
opt-in: without `AI_MODEL`, nothing of the kind exists.

`sync-server healthcheck` exits 0 when the server on `PORT` answers. The Docker image uses it as
its health check.

Logs show method, path, status and duration. They never contain bodies, tokens or query
strings.

## App updates

The Android app is installed from an APK and the Windows one from an installer, so this server is
where their updates come from. A release needs the APKs, the Windows installer and an `app.json`
naming them:

```json
{"version": "1.0.0", "build": 10000, "files": {"windows-x64": "CapyTV-Setup.exe", "arm64-v8a": "CapyTV-64bit.apk", "armeabi-v7a": "CapyTV-32bit.apk"}}
```

Each of the project's [GitHub releases](https://github.com/andresayac/capy-tv/releases) has all
four files. Your own builds leave them in `release/app/` at the repository root: the app's
`tool/build_apk.sh` writes the APKs and `app.json`, and `tool/build_windows.sh`, run after it, adds
the installer as `windows-x64`. Releases and your own builds must be signed with the same key as
the apps installed (see below).

Copy those files into `APP_DIR`, `app.json` last, once the APKs and the installer are all
there: it is what makes a release, and a device that asks while a file is still being copied is
offered it as far as it has come (its SHA-256 too), which then fails as damaged.

```sh
# with docker compose
for f in ../release/app/CapyTV-*; do docker compose cp "$f" sync:/data/app/; done
docker compose cp ../release/app/app.json sync:/data/app/

# with docker run, as above
for f in ../release/app/CapyTV-*; do docker cp "$f" capy-tv-sync:/data/app/; done
docker cp ../release/app/app.json capy-tv-sync:/data/app/

# without Docker, as above
scp ../release/app/CapyTV-* server:/var/lib/iptv-sync/app/
scp ../release/app/app.json server:/var/lib/iptv-sync/app/
```

No restart: devices signed in to an account here ask `GET /v1/app` when they start (and every
few hours while open), and those with an older build offer the update. A device takes the file
for its processor (Android's ABI names; `universal` for one APK for all; `windows-x64` for
Windows), downloads it, checks it against the SHA-256 the server works out, and hands it to
Android's installer, or on Windows runs the installer, which installs over the app and opens it
again. `build` is what
counts: a device updates when the server's is higher than its own. An optional `"notes"` is shown
as is when the update is offered.

Releases are for signed-in devices only: the APKs carry the keys built into your builds (TMDB's).
The APKs must be signed with the key of the installed app, or Android refuses them.

To install the app on a device that has no session yet, such as a Fire TV with Downloader, a
signed-in device asks for an **install link** (Settings → About → *Install on another device*):
an address like `sync.example.com/i/K7Q3X` to type there, and its QR. The code is 5 letters and
digits without look-alikes (no `0`/`O`, `1`/`I`/`L`), in any case (`/I/K7Q3X` works too, as does
a slash at the end), and works for 30 minutes, kept in memory only. The page it opens needs no
session: it shows the app's version and a link per file of the release ("Phones and tablets
(64-bit)", "Fire TV, TVs and Android boxes (32-bit)" — many TVs and boxes run a 32-bit Android on a
64-bit chip — and "if it does not install, try the other one", or one link for a `universal` APK), in Spanish or
English as the browser asks, with nothing loaded from elsewhere. An account makes up to 10 links an
hour, the server keeps up to 100 at a time, and an address that tries 10 unknown codes in 10
minutes is stopped for a while (by its `X-Forwarded-For` with `TRUST_PROXY`; an IPv6 one with its
whole `/64`, which one host usually has to pick addresses from). After 1,000 unknown codes in 10
minutes from all addresses together, every install link answers the same "too many tries" page,
known or not, for a while. Downloader adds `http://` to what is typed, so the server, or the proxy in
front of it, should redirect plain HTTP to HTTPS, as Caddy does. Neither the page nor the APKs are
cached (`Cache-Control: private, no-store`), and codes are left out of the logs.

## Phone bridge

The companion page (add playlists with the phone's keyboard, the phone as a remote, sign a TV in,
move backups, vote on a movie night) normally comes from the TV itself, on the local network. The
Samsung TV app cannot listen on a port, so it uses this server as a relay: it opens a room, and the
QR it shows takes the phone to `/companion` here with the room and the session key in the
address's `#fragment`, which browsers never send. From then on, the phone and the TV post messages
for each other and long-poll for their own.

Every message is sealed on the phone or the TV with that key (ChaCha20-Poly1305), so the server
only ever carries text it cannot read, and could not alter without the other side noticing. It
needs no account: knowing a room's id is what lets a phone in, so ids are 128 random bits and
never logged. Rooms live in memory only, and end 15 minutes after the TV last used them (a phone left
on the page does not keep a room going: with the TV switched off, the page says the room expired),
2 minutes after they open if the TV never reads from them, after 12 hours in any case (the TV then
opens another, and the phone scans the new code), when the TV closes them, or when the server
restarts. Nothing is stored. The page says "connected" only while the TV reads, which it does every
half minute at most.

No one can take the whole bridge: one client network (an IPv4 address, an IPv6 `/64`) opens up to 20
rooms a minute and keeps up to 8 at a time, whose messages take up to 64 MB together; it has up to
32 long-polls waiting and 8 messages being received at once. Behind a proxy that needs the
client's real address: see the Cloudflare note above.

## Backups

Everything is in the `DATA` file. `sync-server backup FILE` writes a consistent copy of it, also
while the server runs (the target must not exist yet):

```sh
docker compose exec sync /server backup /data/backup-$(date +%F).db   # with docker compose
docker exec iptv-sync /server backup /data/backup-$(date +%F).db      # with docker run, as above
```

Or stop the server and copy `sync.db*`.

To restore, stop the server, **delete `sync.db-wal` and `sync.db-shm`** if they are there, and put
the copy in place of `sync.db`. Left behind (after a power cut or a crash), SQLite would apply that
old `-wal` onto the copy and damage it. With Docker, whose image has no shell, through a helper
container (the volume is `server_sync-data` with docker compose, `iptv-sync` with docker run):

```sh
docker compose stop sync
docker run --rm -v server_sync-data:/data -v "$PWD":/b alpine sh -c \
  'rm -f /data/sync.db-wal /data/sync.db-shm && cp /b/backup.db /data/sync.db && chown 65532:65532 /data/sync.db'
docker compose start sync
```

Devices notice that the server went back in time and send it what it is missing. Apart from emails
and device names, the contents are encrypted.

## The app

Users type the server address in **Sync** on the playlists screen or in Settings. The address
must be `https://`; plain `http://` is accepted only for local-network addresses.

To prefill the address in your builds:

```sh
flutter build apk --dart-define=SYNC_SERVER=https://sync.example.com
```

What gets synced:

- **One item per playlist**, named after the playlist's id on the device that added it; the
  other devices take it on, so editing a playlist's server or user keeps it the same playlist.
  On conflict, the latest change wins, and that includes removals.
- **One item per playlist library and profile** (favorites, history and their removal markers).
  Libraries are merged rather than overwritten, so changes from devices that were offline meet
  without loss.
- **One item with the profiles and the parental PIN** (a salted hash of it). For each profile and
  for the PIN, the latest change wins; a profile deleted on one device is deleted on the others,
  with its libraries. Progress noted during playback goes out every two minutes at most; starting, stopping
  and anything else, a moment later.

Writes say which revision they build on and are refused if another device wrote since, so a
device always fetches the others' changes before sending its own. When a device joins an
account (its first sync), what the account has comes first, a provider account it already has
becomes the same playlist, and its other playlists are added to the account.

The epoch tells an account apart from an earlier one with the same email (deleted, then created
again). A device that sees another epoch, or a revision lower than the one it had seen, joins
again and sends everything.

## API

All bodies are JSON. Authenticated calls take `Authorization: Bearer <token>`, never the token in the
URL.

| Call | Body → answer |
|---|---|
| `GET /healthz` | `ok` |
| `POST /v1/accounts` | `{email, authKey, recoveryKey, passwordKeys, recoveryKeys, device, invite?}` → 201 `{token, rev, epoch}` · 403 `invite` · 409 `exists` · 429 |
| `POST /v1/sessions` | `{email, authKey, device}` or `{email, recoveryKey, device}` → `{token, rev, epoch, keys}`: the account keys locked with that secret · 401 `credentials` · 429 |
| `PUT /v1/account/password` | `{proof, authKey, passwordKeys}` → 204: a new password; `proof` is the auth key of the current one or of the recovery key. Signs the other devices out · 403 `credentials` · 429 |
| `PUT /v1/account/recovery` | `{proof, recoveryKey, recoveryKeys}` → 204: a new recovery key · 403 `credentials` · 429 |
| `DELETE /v1/sessions/current` | → 204 (signs this device out) |
| `GET /v1/devices` | → `{devices: [{id, device, created, seen, current}]}` |
| `DELETE /v1/devices/{id}` | → 204: signs another device of the account out · 404 |
| `GET /v1/items?since=N` | → `{rev, epoch, items: [{id, rev, deleted, payload?}]}`: what changed after revision N |
| `PUT /v1/items` | `{base?, items: [{id, payload} or {id, deleted: true}]}` → `{rev}`: one new revision for the whole batch · 409 `stale` when the account is no longer at revision `base` · 413 `quota` |
| `DELETE /v1/account` | → 204 (removes the account, its sessions and items) |
| `GET /v1/live` | WebSocket: `{"type":"hello","rev":n}`, then `{"type":"changed","rev":n}` whenever another device writes |
| `GET /v1/ai` | → `{model}`: the language model the server offers · 404 `no_ai` |
| `GET /v1/app` | → `{version, build, notes?, files: {abi: {name, size, sha256}}}`: the app release in `APP_DIR` · 404 `no_app` |
| `GET /v1/app/{file}` | the APK, with `Range` to go on with a download that was cut · 404 `no_file` |
| `POST /v1/app/link` | → 201 `{code, expires}`: an install link, `/i/{code}`, for 30 minutes · 404 `no_app` · 429 (10 an hour per account) · 503 `busy` (100 alive) |
| `GET /i/{code}` | no session: an HTML page (by `Accept-Language`, Spanish or English) with the app's version and a link per file of the release; the code in any case, `/I/` too · 404 page when unknown or expired · 429 page after 10 unknown codes in 10 minutes from an address (an IPv6 `/64`), or 1,000 from all of them |
| `GET /i/{code}/{abi}` | no session: that file of the release, as an attachment, with `Range` · 404 page, 429 page as above |
| `POST /v1/ai/chat` | `{messages: [{role, content}], json?}` → `{content}`: the model's answer; the server picks model and key · 404 `no_ai` · 429 · 502 `ai_key`, `ai_model`, `ai_unavailable` |
| `POST /v1/relay` | → 201 `{room, secret}`: a phone bridge room; no account needed · 429 · 503 `busy` |
| `POST /v1/relay/{room}/{to}` | `to`: `tv` or `phone`; the message as plain text → `{seq}`, counted per room and direction from 1 · 400 `to` · 404 `room` · 413 · 503 `busy` |
| `GET /v1/relay/{room}/{to}?after=N` | long-poll → `{messages: [{seq, body}], next}`: the messages after N, as soon as there are any, else none after 25 s; `next` is the last seq returned, or N. Reads take nothing away · 404 `room` |
| `DELETE /v1/relay/{room}` | header `X-Relay-Secret` → 204 · 403 `secret` · 404 `room` |
| `GET /companion` | the companion page, for phones that reach their TV through the relay |
| `GET /trailer?v=<YouTube id>` | an HTML page with YouTube's player, muted, playing seconds 8 to 33; it tells the page that frames it its state (`postMessage({trailer})`). For the Samsung TV app, whose `file://` pages YouTube refuses to play in · 404 for anything but a video id |

Limits:

- `authKey`, `recoveryKey` and `proof`: 32 bytes, base64; `passwordKeys` and `recoveryKeys`: up to
  1 KiB, base64;
- a payload: up to 1 MiB, a request body up to 16 MiB, a batch up to 500 items;
- signing up or in: `SIGNIN_LIMIT` (10) tries per minute per address and per email; proofs for
  a new password or recovery key, as many per address and per account;
- the model: `AI_PER_HOUR` (30) requests per account and hour and `AI_PER_HOUR_TOTAL` (300) from all
  of them, a system message and one from the user (no conversation), 256 KiB in all, answers up to
  `AI_MAX_TOKENS` (4000);
- install links: 10 per account and hour, 100 alive at a time, 10 unknown codes per address (an
  IPv6 `/64`) in 10 minutes and 1,000 from all addresses together;
- the relay: 500 rooms at a time, 20 new ones per minute per address; a message up to 8 MiB; a room
  keeps the last 64 messages each way and 16 MiB in all, dropping the oldest first; all the rooms
  together keep up to 256 MiB, past which new messages are refused (503) until some room ends.

## Development

The companion page served at `/companion` is a copy of `app/assets/companion` (`index.html`,
`seal.js`) in `internal/syncserver/companion`, as Go embeds files from this module only. A test
fails when the copies differ: copy them over after changing the page. It is served with
`no-transform` and its scripts marked `data-cfasync="false"`, so proxies such as Cloudflare (its
Rocket Loader) leave them alone: the page's policy allows its own scripts only.

```sh
go test ./...                                                       # API tests
docker run --rm -v "$PWD:/src" -w /src golang:1.26.11 go test -race ./...  # with the race detector
```

The app's tests (`app/test/sync_test.dart`, `app/integration_test/sync_flow_test.dart`) build
this server with Go, or with Docker when that fails. Windows Defender sometimes flags freshly
built Go executables as malware, which is a known false positive.
