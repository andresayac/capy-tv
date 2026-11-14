# movi

The browser build plays files (films, episodes) with [movi-player](https://github.com/mrujjwalg/movi-player):
FFmpeg compiled to WebAssembly reads the container and the browser's WebCodecs decode, so MKV,
AC-3/E-AC-3 sound, several languages and HEVC play where a plain `<video>` cannot.

| File | What it is |
|---|---|
| `element.js`, `movi.wasm` | movi-player 0.4.1, copied unchanged from the npm package's `dist/` |
| `LICENSE` | movi-player's licence (Apache-2.0) with its third-party notices (FFmpeg as LGPL, dav1d) |
| `capy-movi.js` | Ours: the host the Dart side talks to (`lib/player/movi_player_web.dart`), the HEVC label fix and the hardware → software guard |

To update movi, install the new version in an empty folder (`npm install movi-player@<version>`),
copy `node_modules/movi-player/dist/element.js`, `dist/movi.wasm` and `LICENSE` here, and play
an H.264 film, a 10-bit HEVC one and a live channel in the browser build before committing.
