# Installing Capy TV

For anyone installing Capy TV, step by step. Capy TV has no channels of its own: you add the
playlist your provider gave you (an Xtream Codes account or an M3U link).

## Which file

The files are on the project's [Releases](https://github.com/andresayac/capy-tv/releases) page, or on
the install page of a sync server, if someone runs one for you. Pick the one for your device:

| Device | On Releases | On an install page |
| --- | --- | --- |
| Phone or tablet | `CapyTV-64bit.apk` | **Phones and tablets (64-bit)** |
| Fire TV, Android TV, Android box | `CapyTV-32bit.apk` | **Fire TV, TVs and Android boxes (32-bit)** |
| Windows | `CapyTV-Setup.exe` | |
| Linux | `CapyTV-linux-x64.tar.gz` | |

Many TVs and boxes run a 32-bit Android on a 64-bit chip, which is why they get their own file.
If the one you chose does not install, try the other one. When the page shows a single file, it
works on every device.

## Android phone or tablet

1. Open the link (or scan the QR code) on the phone, and tap the file for phones and tablets.
2. When the download ends, open it. Android asks to allow installing apps from the browser the
   first time: allow it, go back, and tap **Install**.
3. Open Capy TV. It runs sideways and full screen, like on a TV.

## Fire TV

1. From the Fire TV's app store, install **Downloader** (by AFTVnews).
2. In Settings, My Fire TV, Developer options, allow **Install unknown apps** for Downloader. (If
   Developer options is missing: Settings, My Fire TV, About, then press the select button on the
   device name seven times.)
3. Someone with Capy TV already signed in to sync opens Settings, About, **Install on another
   device**. It shows a short address, like `sync.example.com/i/K7Q3X`, that works for 30 minutes.
4. Type that address into Downloader and go. On the page, choose the file for Fire TV and
   install it.

## Android TV and Android boxes

As on Fire TV: an app that downloads files (Downloader is on Google Play too), allowed to install
unknown apps in the TV's settings (usually Settings, Device preferences, Security and
restrictions), and the address from *Install on another device*. Capy TV then shows up on the TV's
home screen.

## Samsung TV (2020 and earlier)

Each release has `CapyTV.wgt`. Samsung has no way to install it without a computer: turn on the
TV's developer mode with that computer's address, then, on the computer, with the Tizen SDK's
command-line tools:

```sh
sdb connect <the TV's IP>
sdb devices                                 # the TV's name is the last word on its line
tizen install -n CapyTV.wgt -t <that name>
```

The package is signed with the project's certificate, so the next release installs over it and
keeps what the app saved. A package built and signed by someone else does not: the TV refuses it
until the app is removed. TVs from 2021 on may ask for a Samsung certificate tied to the TV, and
the app has not been tried on them. Developer mode and the tools, step by step:
[tizen/README.md](../tizen/README.md#installing-on-another-tv).

## Windows

1. Download `CapyTV-Setup.exe` and open it. It installs for you alone, with no administrator
   needed, and adds Capy TV to the Start menu.
2. The installer is not signed, so the first time Windows SmartScreen may say it does not know it:
   choose **More info**, then **Run anyway**.
3. The first time you connect your phone, Windows asks whether to let Capy TV on private networks:
   allow it.

## Linux

Unpack `CapyTV-linux-x64.tar.gz` anywhere and run `capy_tv` inside it. It needs the system's libmpv:
`sudo apt install libmpv2` on Debian and Ubuntu.

## macOS and iOS

There is no download yet: the app is built from this repository (see
[development.md](development.md)).

## First steps

1. **Add your playlist**: the server address, user and password your provider gave you, or the M3U
   link. Typing on a TV is slow: choose *Use your phone* and scan the QR code with a phone on the
   same Wi-Fi, which types it there.
2. **Or sign in to sync**, if someone already set it up for you: your playlists, profiles,
   favorites and progress come from your other devices.
3. The lists take a while the first time (big catalogs, a few minutes on a TV stick); after that
   they open at once and update in the background.

## Updates

Devices signed in to sync are offered each new version on Home, at most once a day. The first time
Android asks to allow Capy TV to install apps: the app takes you to that setting. Devices not
signed in are updated as they were installed, from a new link.

## Questions

**A channel or movie shows no picture, but there is sound or it says the signal arrived.** In
Settings, Playback, Advanced, set **Video decoder** to **Software (compatibility)**. Some TV
sticks' hardware decoders cannot take every stream.

**There is no sound, or it is in the wrong language.** Choose another track in the player's
**Audio** menu. Some streams carry DTS audio, which many TVs cannot play: another track usually works.

**It says the account expired, or another device is using the connection.** That is the provider:
most accounts allow one stream at a time. Stop it on the other device, or ask your provider.

**It says it cannot reach the provider.** Check the device's internet. If other apps work, the
provider's server may be down for a while.

**The install page says the link was not found.** The address lasts 30 minutes: get a new one from
*Install on another device*.
