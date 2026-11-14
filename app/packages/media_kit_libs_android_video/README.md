# [package:media_kit_libs_android_video](https://github.com/media-kit/media-kit)

[![](https://img.shields.io/discord/1079685977523617792?color=33cd57&label=Discord&logo=discord&logoColor=discord)](https://discord.gg/h7qf2R9n57) [![Github Actions](https://github.com/media-kit/media-kit/actions/workflows/ci.yml/badge.svg)](https://github.com/media-kit/media-kit/actions/workflows/ci.yml)

Android package providing video (& audio) native libraries for [`package:media_kit`](https://github.com/media-kit/media-kit).

## In Capy TV

This copy of 1.3.8 (`dependency_overrides` in `app/pubspec.yaml`) does not download media-kit's
v1.1.7 jars, whose libmpv carries FFmpeg 6.0, mbedTLS 3.4.0, FreeType 2.13.0 and libxml2 2.10.3 of
2023, with flaws known since. It takes the jars in `android/libs`, built by `build_libmpv.sh`: the
same jars, each with its `libmpv.so` built anew from media-kit's build scripts, mpv at the same
commit, the libraries under it brought up to date (the versions are at the top of the script).
Only `arm64-v8a` and `armeabi-v7a`, the two APKs the app ships, and `x86_64`, the emulator's.

To update them, set the versions in `build_libmpv.sh` and run it in Linux or WSL
(`WORK=/var/tmp/capy-build bash build_libmpv.sh`), then build the app and play a few things
before shipping it: a live channel, an HLS one, an MKV with subtitles.

## License

Copyright © 2021 & onwards, Hitesh Kumar Saini <<saini123hitesh@gmail.com>>

This project & the work under this repository is governed by MIT license that can be found in the [LICENSE](./LICENSE) file.
