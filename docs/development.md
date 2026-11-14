# Development

How to build, test and release Capy TV. The Samsung TV app has its own guide in
[tizen/README.md](../tizen/README.md), the sync server in [server/README.md](../server/README.md),
and the public site in [site/README.md](../site/README.md).

## Getting started

You need Flutter 3.47 (stable), and for the sync tests Go or Docker.

```sh
cd app
flutter pub get
flutter test                 # unit and widget tests
flutter run -d windows       # or linux, macos, or an Android device id
```

## Keys built in

Some features need values given at build time, never written in the code. `.env.example`, at the
repository root, lists them: copy it to `.env` (git-ignored) and fill in what you use.

| Value | What it is for |
|---|---|
| `TMDB_API_KEY` | Trending titles, posters and trailers. Free for non-commercial use (themoviedb.org → Settings → API). It is the short "API Key" (32 letters and digits), not the long "API Read Access Token", which the apps cannot use. |
| `SYNC_SERVER` | The sync server the sign-in form starts with, so your own builds come ready for your server. Anyone can still type another one. |
| `AI_BASE_URL`, `AI_MODEL`, `AI_API_KEY` | A language model for recommendations, for your own copies (see [features.md](features.md#recommendations-for-each-profile-optional-with-ai)). |

```sh
flutter run -d windows --dart-define-from-file=../.env
```

The build scripts below take only these values from `.env`, never the provider accounts there for
the tests. A key built in ends up inside the app, as with any app that calls such services
directly: each one who builds the app uses their own.

## Android, Android TV and Fire TV

One APK serves phones, tablets and TVs: it shows up on the TV home screen (leanback launcher and
banner) and does not require a touchscreen. It needs Android 7.0 or later, so Fire OS 5 (Android
5.1) does not install it. On phones and tablets the app runs in landscape and full screen, like on
a TV. Building needs JDK 17 or later and the Android SDK
(`flutter config --android-sdk <sdk> --jdk-dir <jdk>`, and `ANDROID_HOME` for the scripts).

```sh
cd app
tool/build_apk.sh            # CapyTV.apk at the repository root, for every device
tool/build_apk.sh small      # or one per processor: CapyTV-64bit.apk and CapyTV-32bit.apk
```

The 32-bit APK is for Fire TV, TVs and Android boxes, many of which run a 32-bit Android on a
64-bit chip. Do not use `--split-per-abi`: it multiplies the version code by processor, and devices
stop receiving updates.

Builds are signed with `app/android/key.properties` (git-ignored: never commit it or the keystore).
Without it the script stops, unless `ALLOW_DEBUG_KEY=1` asks for the debug key, which is fine for
local testing only.

```properties
storeFile=release.jks          # relative to app/android/
storePassword=...
keyAlias=release
keyPassword=...
```

Each build gets a higher number than the last: the count of commits, or one more than the last
build in `release/app/`. That folder gets the same APKs with an `app.json`, which is what a sync
server serves for its devices to update themselves (see
[server/README.md](../server/README.md#app-updates)).

Video on Android uses the device's hardware decoder, drawing straight to the screen
(`vo=mediacodec_embed`), which keeps modest TV boxes smooth. Settings → Playback → Video decoder
switches to software for devices whose decoder chokes on a stream; the player suggests it when a
stream arrives but its picture never starts.

To drive a TV like a remote while developing: `adb shell input keyevent KEYCODE_DPAD_DOWN` (`_UP`,
`_LEFT`, `_RIGHT`, `_CENTER`, `KEYCODE_BACK`), and `adb exec-out screencap -p > shot.png` to see it.

Icons and the TV banner are drawn from code: edit `app/tool/generate_icons.dart` and run
`flutter test tool/generate_icons.dart`. The adaptive icon and the launch logo are vector drawables in
`app/android/app/src/main/res/drawable/`.

## Windows

Building needs Visual Studio's **Desktop development with C++** workload with the **C++ ATL**
component (the secure storage plugin uses it), and `nuget.exe` on the `PATH`
(`winget install Microsoft.NuGet`), which fetches the WebView2 SDK the trailers play in.

The installer, `CapyTV-Setup.exe`, needs Inno Setup 6 (`winget install JRSoftware.InnoSetup`):

```sh
cd app
tool/build_apk.sh small      # first: the installer takes the same build number
tool/build_windows.sh        # CapyTV-Setup.exe at the repository root, and in release/app/
```

It installs for the person using the computer, with no administrator asked. Code:
`app/windows/installer/capy_tv.iss`.

## Linux and macOS

```sh
flutter build linux --release    # needs libmpv-dev, libgtk-3-dev, libsecret-1-dev and libepoxy-dev
flutter build macos --release
```

Linux and macOS keep their own title bar; Linux shows posters instead of trailers, as it has no web
view.

## Tests

```sh
app/tool/test_all.sh         # format, analysis, unit tests, the server, the TV app, each integration test
```

- **Unit and widget tests** (`app/test/`): `flutter test`. The sync tests run the real server,
  built with Go or, failing that, with Docker (the first time, with no Go cache, that takes a few
  minutes). `cd server && go test ./...` tests the server alone.
- **Integration tests** (`app/integration_test/`) run the real app, one file at a time: on Windows,
  several files in a single `flutter test` hang when the second app instance starts.
  `app_flow_test.dart` is the whole journey with a real provider from `.env`: adding the playlist,
  live TV, a movie, a series episode, Home, Search and Account, with a screenshot per step in
  `app/build/screenshots/`. `companion_flow_test.dart` plays the phone, and `sync_flow_test.dart`
  signs in and receives another device's playlists.
- **On Android**, `app/tool/test_android.sh [device]` runs the integration tests on a phone, TV or
  emulator. Emulators are not representative for video: their hardware decoder stalls on some
  streams, so the tests use the software decoder there (`HW_DECODER=1` tests the hardware one on a
  real device). With the software decoder, an emulator cannot draw a second video in the same
  player, so zapping and the next episode stay black there.
- **The Samsung TV app**: `test_all.sh` builds it and checks its types, its remote's focus and its
  player in Edge, against a panel of its own, with no TV and no provider.
- **Real services**: `app/test/live_*_test.dart` log in to real providers and services, so a plain
  `flutter test` skips them. Run them with `LIVE_TESTS=1 flutter test test/live_provider_test.dart`.
  They read the git-ignored `.env`, where more providers are numbered:

  ```
  XTREAM_CODE=https://your-provider.example     # the server
  XTREAM_USERNAME=...
  XTREAM_PASSWORD=...
  XTREAM_CODE_2=http://another-provider.example:8080
  XTREAM_USERNAME_2=...
  XTREAM_PASSWORD_2=...
  ```

- **Screenshots** of key screens, without opening a window, with real provider data:
  `SCREENSHOTS=1 flutter test test/screenshot_test.dart`.

CI (`.github/workflows/ci.yml`) checks every push to `main` and every pull request: the sync server
(and that its image starts and answers), the app's formatting, analysis and tests on Linux and
Windows, the Samsung TV app, and that no key got into the code. Changes to text alone do not run it.

## Releases

Pushing a version tag builds and publishes a release (`.github/workflows/release.yml`):

```sh
git tag v1.2.3 && git push origin v1.2.3
```

The release has:
- the Android APKs (64 and 32 bits);
- the Windows installer;
- the Linux build, `CapyTV-linux-x64.tar.gz`, which needs the system's libmpv (`libmpv2` on Debian
  and Ubuntu);
- `SHA256SUMS.txt`;
- `app.json`.

The APKs, the installer and `app.json` are what a sync server's `app` folder takes for its devices
to update themselves. The sync server's image goes to `ghcr.io/<owner>/capy-tv-sync`, for amd64 and
arm64. Run by hand (Actions → Release → Run workflow), the workflow builds everything and keeps it
as artifacts, publishing nothing.

The build number comes from the version (1.2.3 is 10203), and Android only installs a higher one,
so versions only go up, with minor and patch below 100. The repository's secrets (Settings →
Secrets and variables → Actions):

| Secret | What |
|---|---|
| `ANDROID_KEYSTORE` | The release keystore, in base64 (`base64 -w0 release.jks`) |
| `ANDROID_KEY_ALIAS` | Its key alias |
| `ANDROID_KEY_PASSWORD` | Its password (PKCS12: the store and the key share it) |
| `TMDB_API_KEY` | Optional: trending titles, posters and trailers |

A release without the keystore stops: APKs signed with another key could never update the ones
already installed. No sync server and no language model go into these builds: whoever uses them
sets up their own.
