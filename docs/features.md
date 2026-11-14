# Features

What Capy TV does, feature by feature, and where each one lives in the code. The player has a page
of its own: [player.md](player.md).

## Your phone as a companion (no cloud)

On a TV or a computer, **Use your phone** (welcome screen) and **Settings → Connect your phone**
show a QR code. The phone's camera opens a page served by the app itself, where the phone can:

- **add a playlist** with its keyboard (the TV checks it with the provider and saves it);
- **sign the TV in to the sync account** (Account tab), so nobody types an email and a password
  with a remote;
- act as a **remote** over a WebSocket: arrows, OK, back, play/pause, channel ±, typing into the
  focused field or searching, and seeing what is playing;
- **download or restore a backup** (playlists with their passwords, favorites, history, settings);
- open the app on the phone, if installed, through a `capytv://open/pair?...` link, to send
  or bring lists between the two devices.

There is no server or database anywhere else: the two devices talk directly over the local
network (port 8765, or any free one). The page is plain HTTP, so passwords, the sync account and
backups never cross the network readable: they are sealed (ChaCha20-Poly1305) with a key made for
each session that only the QR code carries, in the address's `#fragment`, which browsers never
send. Opened by typing the address instead, the page works as a remote but sends nothing
private. The sealing code is `app/assets/companion/seal.js` on the page and
`app/lib/remote/companion_seal.dart` in the app; `app/test/companion_seal_test.dart` checks both
against RFC 8439 and against each other (with Node, when installed). The server only runs while that screen is open or a phone
is connected as a remote, and every request needs the session code in the QR, which changes each
time (it locks after 20 wrong attempts). Code: `app/lib/remote/`, the page is
`app/assets/companion/index.html`, its texts come from the app's translations.

On each device, playlists live in the app's preferences and their passwords in the system's
secure storage (Android Keystore, Apple Keychain, Windows DPAPI, libsecret on Linux).

## Sync across devices (optional, on your own server)

**Sync** (welcome screen, and Settings) signs a device in to an account on a sync server you run
(`server/`, one Docker command with automatic HTTPS: see [server/README.md](../server/README.md)).
Playlists with their passwords, favorites and watch progress then follow the user to every
device, and changes from one device reach the others within a second or two over a WebSocket.

Everything is encrypted on the device before it leaves (AES-256-GCM, with account keys the server
only gets locked with the password, stretched with Argon2id): the server stores blobs it cannot
read and never sees the password. A new account gets a recovery key to write down: with it, a
forgotten password is replaced and nothing synced is lost. The password and the recovery key can
be changed from the Sync screen. Libraries merge
instead of overwriting, so devices that were offline catch up without losing anything; for
playlists, the latest change wins. Signing out keeps everything on the device. Code:
`app/lib/sync/`, the screen is `app/lib/ui/sync_screen.dart`.

The server can be private (an invitation code to create accounts), limits each account's space,
and signs out devices nobody used for months. From the Sync screen, any device of an account can
sign another one out, a lost phone say: it keeps what it already had but gets nothing new.

### Send to another device

With sync on, **Send to…** (in the player, and on a movie's page) lists the account's other devices
and plays what is chosen on the one picked, from where it was: a TV, from the phone in hand. It is an
item of the account like the rest, sealed end to end and addressed to that device; the server only
passes it on, and the device it is for gets it at once over its live connection. There, whatever was
open closes and it plays, the playlist opening first if another one was; a request older than two
minutes (a device that was off) is not played. It has its own version, which devices on an older
version of the app leave alone. Code: `app/lib/sync/cast.dart`, `app/lib/ui/send_to.dart`.

### Chromecast

**Send to…** also lists the Chromecasts on this network (found by mDNS; *Connect by address…* reaches
one the search cannot see, over a VPN say, and is remembered), on every platform, with no Google
Play Services, so Fire TV and Windows cast too. The app speaks the Cast protocol itself to the
Default Media Receiver; once the TV plays, this device shows its remote (play/pause, ±10 s and the
progress bar for movies, volume, *Play here* back from where the TV was, *Stop casting*) and Back
leaves it casting: Home's rail leads back to it. Progress is saved as if watched here. On phones a
notification with its controls stays while it casts.

- **Movies and episodes** go to the TV as they are (mp4 first among a title's versions; mkv may not
  play, and says so). The TV fetches them itself, so it gets the provider's address with the
  account in it. A copy that needs the app's own headers goes through the relay below.
- **Live channels** from Xtream accounts are asked for as HLS and go through a relay on this device,
  which adds what the TV's player needs (CORS) and leaves out what trips it up. This device must
  stay on and on the TV's network meanwhile. Channels only offered as plain TS, catch-up and
  recordings cannot be cast yet, and the dialog says why. When the TV cannot reach the relay, the
  app says so: on Windows, the first time, allow Capy TV through the firewall on private networks
  (Windows asks; if it was refused, Windows Security → Firewall → Allow an app), and a Wi-Fi that
  keeps its devices apart (guest networks often do) stops it too. When the provider refuses the
  stream (often one connection too many), the app says that instead.
- A profile with a time per day sends nothing elsewhere (a Chromecast or another device of the account), as that time would not be counted.

Beta: tested against a fake receiver that speaks the protocol (`app/test/support/fake_cast_receiver.dart`)
and the relay in a real browser with Shaka Player, not yet on a real Chromecast. Whether a plain
`http://` stream plays is the TV's call. Code: `app/lib/chromecast/`, `app/lib/ui/cast_screen.dart`.

### Updates from your server

The app is installed from an APK (on Windows, from an installer), with no store to update it, so
the sync server does: leave the APKs and the Windows installer of a new build in its releases
folder (see [server/README.md](../server/README.md#app-updates)) and the account's Android devices
and Windows computers offer it on Home, once a day at most, never over the player. On Windows the
installer then runs by itself, with only its progress on screen: it closes the app, installs over
it (playlists, settings and recordings stay) and opens it again.
Settings → About shows the version and *Update to…*, or *Check for updates*. The device downloads
the file for its processor (going on from a download that was cut), checks its SHA-256 against
the server's, and hands it to Android's own installer, which asks. The first time, Android wants
the app allowed to install apps: the app explains it and opens that setting, and goes on once the
user is back. Only for signed-in devices, as the APKs carry the keys built into them. To install
the app on a device with no session yet, *Install on another device* (Settings → About, on any
signed-in device) shows a short address valid for 30 minutes, such as `sync.example.com/i/K7Q3X`,
to type into Downloader on a Fire TV, and its QR for a phone: a page with a link per APK. Code:
`app/lib/sync/app_update.dart`, `app/lib/ui/app_update_dialog.dart`,
`app/lib/ui/install_link_dialog.dart`.

## Profiles and parental control

**Profiles** (welcome screen, and Settings) give each person their own favorites, history and
"Continue watching", per playlist. With more than one, the app opens on **Who's watching?**. The
first profile keeps what was there before profiles existed. Live channels have their own place in
the history, so zapping does not push movies and series out of "Continue watching".

- **Kids** profiles never show adult content, and of the rest only what something says is for
  children: a category named so ("Infantiles", "Kids", "Dibujos animados"...) or a genre of the kind
  (family, children), and never a horror, erotic, thriller, crime or war genre or an adult age
  rating. With a provider that sends neither such categories nor genres, a kids profile is left
  with little or nothing: better that than guessing. An M3U only has its groups to go by.
- **Adult content** is hidden in every profile unless the profile turns it on: categories named for
  adults ("XXX", "Adultos", "+18"...), categories where the provider marks most items as adult
  (`is_adult`), and items marked so.
- A four-digit **parental PIN** opens the profiles that ask for it and protects these settings. It
  keeps children out; it is not meant to stop an adult with the device and time to spare. It is
  stored as a salted hash.
- A kids profile may have a **time per day** (30 minutes to 3 hours), counted on each device: when
  it is up the player stops ("That's all for today", the stream closed), and the PIN gives 30 more
  minutes. Code: `app/lib/data/watch_time.dart`.
- Each profile may have its own **audio and subtitle languages**, before the ones in Settings.
- A device may open with **a profile of its own** without asking who is watching (a kids' TV): set
  in Profiles with the PIN, kept on that device only.

Profiles, the PIN and each profile's libraries go with backups and account sync (encrypted like the
rest). Code: `app/lib/data/profiles.dart`, `app/lib/ui/profiles_screen.dart`.

## Lists, guides and playback that hold up

- **Lists come from the device.** The full lists of a playlist (channels, movies, series and their
  categories) are fetched once per session, decoded off the UI thread and shared by every screen;
  categories are filtered from them instead of asked for one by one. They are kept on disk: for
  six hours a playlist opens from there, and after that it still does when the provider cannot be
  reached. The same goes for M3U playlists. Guides are cached for six hours and parsed off the UI
  thread too; caches of playlists not opened for a while are deleted.
- **Lists that keep up.** *Update list* in Settings asks the provider for its lists and guide again
  whatever their age, in the background: once they are in, Home shows them instead (and says how
  many movies, series and channels are new); if the provider cannot be reached the old ones stay.
  Back to the app after six hours away (a TV that slept), it happens by itself. Settings also says
  how many movies (a title with several versions once), series and channels the list has.
- **Live TV comes back by itself.** A stream that breaks off is reopened by FFmpeg at once; one
  that freezes with its connection open is noticed after a few seconds and opened again, with
  growing pauses, before the player says the channel is not available.
- **M3U entries keep their identity** when the provider reorders the list: ids come from the
  stream URL (the stream id of panel URLs, which also survives a password change), and a user
  agent the playlist asks for (`#EXTVLCOPT:http-user-agent`) is sent with the stream.
- **No bare black screens.** The screens outside a playlist (welcome, profiles, sync, phone
  pairing, account) sit on posters under a dark veil, kept on disk: see below.

## Movies and series first, from the first start

Live TV is there, but movies and series lead: Home's tabs are Home, Movies, Series, Live TV, and
Home shows what to watch before the channels.

With a [TMDB](https://www.themoviedb.org) key built in (see [development.md](development.md#keys-built-in)), the app shows what is
trending this week from the very first start, before any playlist:

- the **welcome screen** shows one trending backdrop after another, each slowly coming closer,
  with its title, year and rating;
- the other screens outside a playlist sit on a **wall of trending posters** drifting slowly
  upwards, each column at its own pace (still when the system asks for reduced motion);
- **Home** opens on a carousel of the trends the provider has, playable right away, matched by
  TMDB id or by title (in the app's language or the original one) and year. A couple of seconds
  into each page its **trailer** comes to life behind it: silent, without controls, 25 seconds
  past the studio logos, then the next title. It is
  YouTube's own embedded player (YouTube's terms allow no other), in a web view: on Android,
  iOS, macOS and Windows; Linux shows the backdrops only. Trailers stop when another tab or screen
  covers Home;
- **Most watched movies** and **most watched series** of the week, on Home, Search and the
  Movies and Series tabs: the trends the provider has, numbered large beside their posters, up to
  ten; only from three on (a ranking of one or two says little); *See all* lists every one;
- each **movie's and series' page** plays its trailer once behind the title the same way: the
  provider's own (`youtube_trailer`), else TMDB's, found by the TMDB id the provider gives or by
  title and year (only a result with the same title counts, so a namesake lends nothing).

Each trend's **age rating** is asked of TMDB until it answers (R, NC-17 or TV-MA in the US; without
a real US rating, 18 or more anywhere). Only titles known not to be for adults show on the welcome
screen and the poster walls, which the whole family sees; kids profiles' carousel and most watched
rows only have those with a US rating for children (G, PG, TV-Y, TV-Y7, TV-G or TV-PG).

TMDB is asked at most once a day, in the device's language and country (titles differ between
"es-MX" and "es-ES"); nothing about the user goes with the request. When the provider's catalog is in
another language than the app (an app in English, a catalog in Spanish), the trends' titles in
the catalog's language are asked too, once a day, so they are found in it; the language is told
by the catalog's small words ("el", "the", "der"...). Never adult content, nor
horror, since the whole family sees these screens. Without a key, or until TMDB answers,
the posters are the provider's best rated recent movies and series, noted when a playlist opens.
Settings → About carries the notice TMDB asks for. Code: `app/lib/data/trending.dart`,
`app/lib/data/poster_wall.dart`, `app/lib/ui/backdrop.dart`.

## Movie night

From *Surprise me*, **Movie night** puts six titles for the mood to the vote: the TV shows a QR
code and the titles; everyone in the room scans it and says yes or no to each from their phone
(the companion page's *Vote* tab, only there while a vote is open). The TV counts as the votes
come; *See the winner* shows the one most wanted (at a tie, the best rated), ready to play. A
phone that votes again changes its vote, it does not count twice. Votes go to this device over
the local network with the session code, like everything on the companion page; nothing private
is in them. Code: `app/lib/remote/movie_night.dart`, `app/lib/ui/movie_night_screen.dart`.

## A poster's preview

A poster kept under the mouse (or under a remote's focus a moment) in a row, a grid or search
results opens a larger card over it: its backdrop slowly coming closer, title, year, rating,
genres and synopsis, and with the mouse *Play* and *Details*. With a remote it only shows: the
arrows keep moving along the row and OK opens the title as ever. Any scroll, another screen or the
mouse leaving closes it. No trailer there: going along a row costs no data, and trailers play on
Home's carousel and each title's page. Code: `app/lib/ui/preview.dart`.

## Screensaver

A screen left alone (five minutes on TVs and computers by default; Settings → Playback →
Screensaver, from two minutes to never; off on phones, which sleep by themselves) shows this
week's trending backdrops one after another, slowly coming closer, with the time. Never while
something plays, never a title rated for adults only; any key, tap or deliberate move of the
mouse goes back to where it was. Code: `app/lib/ui/screensaver.dart`.

## New episodes of your series

Home shows **New episodes of your series**: the series the profile has been watching that got
episodes after the last one it watched, with the next one under the poster ("S2 · E5 and 2
more"). Only series the provider's listing says changed since are asked about, a few at a time,
each once a session; one still in progress is in *Continue watching* instead. Code:
`app/lib/data/new_episodes.dart`.

## Surprise me

**Surprise me** (Home) is for an evening without a plan: a mood (a laugh, action, suspense, with
the family, romance, scary, something different) and movie or series, then one title of the
provider's catalog, well rated and not watched by the profile, and another if not that one; never
the same title twice, whatever its copies. Moods read the genres providers write, in Spanish or
English. Kids profiles are not offered the scary one. Code: `app/lib/data/surprise.dart`.

## Recommendations for each profile (optional, with AI)

The service comes from the first of these that exists:

1. **This device's own**, set up in Settings (below);
2. **the sync server's**, for every device signed in to it: its owner sets `AI_MODEL` and the
   key on the server, which forwards the requests, so devices never have the key (see
   [server/README.md](../server/README.md#recommendations-through-the-server)). Titles sent for
   recommendations are the one thing the server can read; it keeps nothing;
3. **one built into the app** at build time (below), for a family's own copies.

Without any of them, or while the service does not answer, Home simply shows no recommendations.
Settings can also turn them off on a device, whatever the service.

**Settings → Recommendations with AI** sets up a language model once per device: any service with
the OpenAI chat completions API (Ollama, locally or in the cloud at `https://ollama.com/v1`,
OpenAI, OpenRouter, vLLM, LM Studio...): an address, a model and a key, checked with a short
question before it is saved. The key goes to the system's secure storage; the setup sits behind
the parental PIN when there is one.

A family's own build can come with it on, so nobody sets anything up: with `AI_MODEL`,
`AI_BASE_URL` and `AI_API_KEY` as defines (`--dart-define=...`, or in the `.env` given with
`--dart-define-from-file`) the app uses that service unless Settings turns it off or sets up
another. That key ends up inside the app, like the TMDB one: fine for a family's own copies,
not for an app handed out to strangers, who could take it out.

Home then shows **Picked for <profile>**, right after *Continue watching*: up to twelve titles,
each with why in a line ("Because you watched Ozark"). The model reads the titles the profile
watched and keeps in its list, and picks only from candidates the app gives it: titles of the
provider's catalog (trending this week, best rated, new) that the profile has not seen. So it
never suggests what the provider lacks, and answers that name anything else are ignored. Only
those titles are sent: no credentials, no addresses, nothing about the device. Kids profiles
never use it, and a profile that has watched nothing yet is not asked about.

Answers are kept per playlist and profile, shown at once on the next start, and asked again
after twelve hours, or half an hour after the profile watched something new. Code:
`app/lib/data/recommender.dart`, `app/lib/ui/ai_settings.dart`.

## Versions, and a copy that does not start

Providers list many titles more than once, a copy per language or quality ("Spider-Man",
"Spider-Man 4K"). The app tells them apart from other titles by their words and year:

- rows show each title once, the provider's own categories too (a provider may repeat thousands of
  cards across its categories; a category shows the copy listed there), and its
  page lists **Versions** by category and container, the one shown marked, the others a tap away
  (two that would read the same are numbered);
- **My list and where it was left go by title**: a movie in My list shows as in it from any of its
  copies, and comes out from any; one started in one copy goes on from there in another; Continue
  watching shows it once. An episode counts by its series' title and number, so another copy of
  the series knows where it was too;
- playing a title brings its other copies along: one that **does not start** (gone from the
  provider, a server down) makes way for the next by itself, "Trying another copy…", within ten
  seconds instead of twenty, before "unavailable" ever shows;
- the copies are tried **fastest first, by the hour of the day**: the app notes how long each
  server took to start a stream, and when (a provider quick in the morning may crawl at night),
  and a server that failed goes last. Kept on the device, by server address only. Code:
  `app/lib/data/stream_stats.dart`.

## Adding a provider

**Add playlist** takes an Xtream account (server, user, password) or an M3U list. Pasting the
link a provider sends ("http://host:8080/get.php?username=…&password=…&type=m3u_plus", or a
stream's address) fills in all three; pasted as an M3U list, such a link becomes the Xtream
account it is, which brings full records, the guide and trailers. The same goes for a playlist
sent from a phone. With a second provider, the app offers to combine them.

A provider at https whose certificate cannot be checked (its own, expired, or for another name, as
many panels have) works as one at http: its panel, lists, guide, images, recordings and casts take
it, as the player takes it for the channels. Sync, TMDB, the language model and updates keep
checking theirs. In a browser (the web version) the browser decides, and refuses it. Code:
`app/lib/data/provider_client.dart`.

## Several providers as one list

**Combine playlists** (playlists screen, with two or more) joins providers into one list: one
may have more movies, another be faster at night, a third be the backup. Their catalogs come
together; a title several have shows once, with every provider's copy among its **Versions**
("Provider B · Marvel - DC · MP4"), and plays from the one usually fastest at that hour, or from
another when one does not start. Categories are named after their provider, their guides are
merged, and one provider that cannot be reached leaves the others working.

The combined list has its own favorites and history (*Settings → Bring favorites and history from
another list* brings each provider's), and goes with backups and account sync like any playlist:
the playlists it joins are named by their sync ids between devices. Each playlist stays as it is.
Code: `app/lib/data/combined.dart`.

## Search that holds up in a big catalog

Search covers the whole catalog on the device (25,000 movies, 4,500 series and 2,000 channels
take about 0.1 s to index once, off the UI thread, and a few milliseconds per search):

- **as people type:** words in any order, without accents or punctuation, a word cut short
  ("brea bad"), a slip of one letter in a word of five or more ("braking bad"); the provider's
  tags (`4K`, `1080p`, `AC3`, `ESP`, `LAT`...) do not count, and any script works (Arabic,
  Korean, Japanese titles);
- **best matches first:** the very title, then its start, then every word whole, then the rest;
  at equal match, the newest and best rated. Each section shows the first ones and *See all*
  the rest in the same order;
- **one card per title:** the copies a provider lists per language or quality (the same words
  and year) come as one, "3 versions"; its page lists them by category and container, the one
  shown marked, the others a tap away;
- **movies and series first**, then **what is on TV**: programmes of the guide whose name
  matches, on now (with the live dot) or within twelve hours, each with its channel, ready to
  play; then channels by name, with what they show now;
- **before typing**, what saves typing with a remote: the profile's recent searches, the week's
  top ten movies and series, and genres.

Code: `app/lib/data/search.dart`, `app/lib/ui/search_tab.dart`.

## Changing provider

Ids (`stream_id`, `series_id`, channel ids) belong to each provider's panel: another provider, or
the same one after rebuilding its panel, numbers everything differently. So favorites and history
also keep what identifies an item anywhere (`app/lib/data/matching.dart`): the TMDB id of movies
and episodes (from the full records; the app fills it in quietly for watched movies), title and
year for movies and series, season and number for episodes, guide id or name for channels.

- **Edit playlist** (pencil on the playlists screen) changes server, user or password and keeps
  favorites and history.
- **Settings → Bring favorites and history from another list** looks for everything of an old
  playlist in the open one, keeping positions and dates, and says what the new provider lacks.

## The Windows title bar

On Windows the app draws its own title bar, black like the rest, instead of the system's: the logo;
inside a playlist its name and kind (*My provider · Xtream Codes*), a button that updates its lists (as
Settings → *Update list* does, with the same progress) and an arrow back to the playlists; then a
search in that playlist, which **Ctrl+K** reaches from anywhere and which fills Home's Search tab,
closing whatever was open over Home (emptying it, with its X or by deleting, closes nothing). Esc, Enter or a click
elsewhere gives the keys back to the screen. Last come minimize, maximize and close (close lights up
grey, not red). Dragging any empty part of the bar moves the window, a double click maximizes or
restores it, and the edges resize as usual. While a dialog that only its work closes is open (the
list being updated), the playlist's part of the bar waits; over the profile picker and the
screensaver the bar shows just the logo, the app's name and the window buttons, and using it counts
as activity (a click on it, or the mouse moved over it, ends the screensaver). The bar hides while
the player is in full screen (F, a double click or its button; Esc leaves it). It is built on
window_manager, which also does that full screen: media_kit's own would leave a frame around the
picture once the system's bar is hidden. Windows 11's Snap Layouts no longer open from resting the
mouse on maximize (only the system's own button gets that); **Win+Z** opens them. Linux and macOS
keep their own title bar. Code: `app/lib/ui/title_bar.dart`, `app/lib/desktop_window.dart`.
