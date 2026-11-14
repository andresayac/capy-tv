# Capy TV for Samsung TVs

Samsung TVs run Tizen, where the Flutter app cannot go: Flutter's Tizen port needs Tizen 6.0 or
later, and the player the app is built on (libmpv) does not exist there. This is the same app for
them, as a web app: TypeScript and Preact built for the oldest of their browsers (Chromium 69, on
Tizen 5.5), playing with the TV's own player (AVPlay). It has been used on a 2020 TV and a 2026
one. It uses the Flutter app's
strings (`app/lib/l10n/*.arb`), font and design, and the same playlist format.

It has what the Flutter app has on a TV remote: playlists (Xtream, M3U, combined), profiles with
the parental PIN, Home, movies and series (featured carousels with their trailers, genres, the
week's most watched, title pages with versions), Live TV with the guide and catch-up, search,
Surprise me, movie night, end-to-end encrypted sync (titles sent from another device play here),
the phone companion and the screensaver. In the player: the queue's channels or episodes, a
series' intro marked once and skipped after, and the stream's technical details.

## Building

Requires Node 20+. The TV part requires the Tizen SDK (`~/tizen-studio`, CLI is enough) and a
certificate profile (`tizen certificate` + `tizen security-profiles add`; set `TIZEN_PROFILE`).

```sh
npm ci
npm run build                       # build/www
node scripts/shot.mjs out.png       # a 1920x1080 screenshot in Edge (--seed, --keys=down,enter)
node scripts/tv.mjs deploy          # package, install on the TV at $TV and start it in debug mode
node scripts/tv.mjs seed            # add the .env provider as a playlist on the TV
node scripts/tv.mjs logs            # what the app logged
node scripts/tv.mjs key down enter  # press remote keys
```

`node scripts/build.mjs` reads `TMDB_API_KEY` and `SYNC_SERVER` from the repository's `.env` (see
`.env.example`), as the Flutter app takes them with `--dart-define-from-file`.

The TV must be in developer mode (Apps, then 1 2 3 4 5 on the remote) with this computer's IP
as the host.

The version in the package is the Flutter app's (`app/pubspec.yaml`, without the build number),
written into `build/www/config.xml` at each build: raise it there for a release.

## Installing on another TV

Samsung offers no way to install a web app like this one without a computer: every install and
every update goes through developer mode and the Tizen tools, from a computer on the same network.

1. **On the computer**, once: Node 20+, the Tizen SDK (the CLI is enough) and a certificate profile
   (`tizen certificate`, then `tizen security-profiles add`), with an author certificate of your
   own; some models may ask for a Samsung certificate tied to the TV instead.
2. **On the TV**: Apps, then 1 2 3 4 5 on the remote. Turn Developer mode on, type the computer's
   IP as the host and restart the TV as it asks. The computer and the TV must reach each other
   (the same network, or a route to it).
3. **On the computer**, in `tizen/`: `npm ci`, `npm run build`, then
   `TV=<the TV's IP> TIZEN_PROFILE=<profile> node scripts/tv.mjs deploy`. The app starts on the TV
   and stays in its Apps. Or, without building it: download `CapyTV.wgt` from the latest
   [release](https://github.com/andresayac/capy-tv/releases/latest) and run
   `TV=<the TV's IP> node scripts/tv.mjs install CapyTV.wgt` (no certificate profile needed).
4. **On the TV**, in the app: add the playlist, or sign in to sync to bring the lists, profiles and
   libraries of the other devices. The phone's companion (QR) adds a playlist without typing it.

To **update** it: build again and run `tv.mjs deploy`, or install a newer release's package, with
the TV in developer mode. What it has saved stays, as long as the new package is signed with the
same author certificate as the one installed: releases carry the project's ("Capy TV"), and the TV
refuses a package signed with another until the app is removed (`sdb shell 0 vd_appuninstall
CapyTvApp1.CapyTV`), which deletes what it saved.

## Known limits on these TVs

- AVPlay does not decode DTS audio (no Samsung TV since 2018 does).
- AVPlay refuses some AES-128 encrypted HLS channels (`PLAYER_ERROR_NOT_SUPPORTED_FILE`); those
  play through hls.js on the page's `<video>`, and the TV remembers them for 30 days.
- YouTube's embedded player refuses pages without a web origin (error 153), and this app is a
  `file://` page. The silent trailers behind heroes and title pages play in the sync server's
  `/trailer` page instead (the sync server in use, else `SYNC_SERVER` from `.env`): without a
  reachable sync server only the artwork shows. A title's Trailer button opens the whole trailer
  in the TV's YouTube app.
- A web app cannot listen on a port, so the phone companion (QR) goes through the sync server's
  bridge (`/v1/relay`), sealed end to end: it needs a reachable sync server too.
- A web page cannot set its User-Agent: an Xtream playlist's own (set in the Flutter app) goes to
  AVPlay for the streams, but its lists and guide are asked for with the browser's.
