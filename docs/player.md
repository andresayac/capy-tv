# The player

## On screen

On top, what plays and what the stream is: back, the poster, the title and its year, the episode;
on the right **badges** for the picture and sound ("FHD", "24 FPS", "5.1", from what mpv reports),
the sleep timer when set, and LIVE. Below, the progress (tap the length for the time left) and two
groups of controls: the title's own on the left (my list, the **episodes or channels** being played
through in a side list, next episode, sound) and the picture's and sound's on the right (speed, the
**picture fit**, audio and subtitles, a **lock** on touch screens, settings).

## Pausing and rewinding live TV

Live channels can be **paused and rewound**: what a channel sends is kept while it plays
(in memory, from 32 MB on a TV stick to 512 MB on a computer: a few minutes at HD), so a pause
holds the place while the channel goes on coming in, and ±10 seconds move within what was kept.
Behind the live picture, LIVE becomes how far behind and **Go live**, which jumps back to it. A new
channel starts a new store.

## Multiview

**Multiview** (the grid button on a live channel) shows up to four channels at once: two side by
side, three or four in two rows. The channel playing comes first and the player makes way for it;
*Add a channel* picks another from the playlist's channels, with a search. One is heard, outlined
with a speaker: OK or a tap gives a channel the sound, and the bar below changes, removes, or opens
in full screen the one heard. Each channel is a player of its own, so one of the provider's
connections: past what the account allows, a channel shows as unavailable (the app does not count
them for the provider). Code: `app/lib/player/multiview_screen.dart`.

## Recording

**Recording** (the record button on a live channel) saves the channel as it comes in, the MPEG-TS
untouched, so it costs no decoding; *REC* and its time show meanwhile, and changing channel or
closing the player ends it. libmpv as media_kit builds it reads video files but cannot write them,
so the first recording opens the channel again (a moment's gap) through a relay inside the app,
for this device only: it fetches the stream once from the provider and hands the same bytes to the
player and to the file, no second connection; recording starts from the live picture. While it
records, the relay keeps up with the channel whatever the player does: paused, the player is kept
up to 32 MB and then joins the live picture again when it plays on. A stream that drops and comes
back goes on in the same file; a file that cannot be written further (no room left) stops the
recording and says so. HLS channels (those mpv finds are HLS, or one the relay finds is; by a
`.m3u8` address only when mpv does not say) come as a playlist of short MPEG-TS pieces that the
player fetches one by one, so they are recorded without the relay: the player goes on as it is, and
the app follows the same playlist (the variant the player plays, when mpv says which; else the best
one up to 25 Mb/s) and writes its pieces in order into the file, from about where the player is
(three pieces from a live playlist's end). This is a second session with the provider, and each
piece is fetched twice; the playlist is read again where it was found, and only after a few
failures from the channel's address. *REC* shows once the first piece is in the file: a channel
whose pieces cannot be had this way (a cookie, a key, a session the provider refuses) is said at
once. Cookies the provider sets go back to it, as players send them. Each piece is written once, by
its number; one not had yet is tried again while the playlist still lists it, then left out, and
pieces that went by during a long stall are a gap. A minute with no piece ends the recording and
says so (what came is kept); a playlist that ends (an event that is over) ends it once all of it
is in the file. Pieces encrypted with AES-128 are decrypted; other encryption (SAMPLE-AES, DRM),
fragmented MP4 pieces and sound that comes apart from the picture are not recorded, and the app
says why; nor is a plain M3U list named `.m3u8` (one endless stream in it is no HLS piece).
While a recording is under way the app is kept running, as for a scheduled one (a notification
says so), so the player's recordings go on with the app in the background too. Settings → Recordings plays or deletes them; they are
kept on Android in the app's own folder on the device's storage (they go with the app), on Windows
in Videos\Capy TV\Recordings (OneDrive often uploads Documents; ones from before are still listed
from there), elsewhere in Documents. Code: `app/lib/player/player_recording.dart`, `app/lib/player/record_relay.dart`,
`app/lib/player/hls_recorder.dart`, `app/lib/data/recordings.dart`.

## Scheduled recordings

**Scheduled recordings** come from the TV guide: a programme still to come (or, with a long press,
one on now; on a remote, OK held a moment or the ☰ / info button) has *Record* in its details, and
*Cancel recording* once scheduled; a dot marks it in the guide. It records with nobody watching,
from a minute before the guide's start to two minutes after its end, straight into a file among
the recordings, with no player; one on now starts at once. Each recording is a connection of its
own, overlaps included (the provider decides how many it allows), except one of the channel the
player is showing: that one records from what the player gets, through its relay, and goes back
to a connection of its own if the player leaves the channel. What is kept is the playlist, the
channel and the times, never the stream's address, which carries the account: that is made again
from the playlist when the recording starts. A stream that drops is asked for again at once after
a good while streaming, else a little later each time (a provider answering with a short "not on
air" clip is not asked every second), and goes on in the same file; one that is found to be HLS
only once asked for goes to the HLS recorder, when there is one. Recordings happen while the app
runs, in the background too. On Android a notification says what records, and keeps Android from
stopping the app meanwhile; waiting for one, an exact alarm wakes the app at its time, so Android
15's six hours a day for such services are spent recording, not waiting (before 15 the
notification also shows what comes next). Past those six hours Android stops it: a notification
says so, and recording goes on once the app is opened. Back on the app's first screen leaves it
running, as Home does, while recordings are scheduled. If Android closed the app to free memory
meanwhile, or the device started again, the wake-up records all the same: the service starts a
Flutter engine with no screen that runs the app's scheduler (`recordWhileClosed` in
`app/lib/main.dart`), and as the app opens it takes over, going on in the same file. Swiped away
while one records, the app stops it; one cut short so goes on in the same file when the app opens
again within its time. Elsewhere a recording whose time comes with the app closed is missed (and
marked so). Settings →
Recordings lists the scheduled ones above the files, with their state, to cancel or stop. HLS
channels are recorded as the player's are (above), and one whose recording stops by itself is
asked for again within its time, as any other. On an iPhone the app stops once it leaves the
screen, and a recording with it: the guide says to keep the app open, and so does sending a live
channel to a Chromecast, whose relay runs in the app. Code: `app/lib/player/recording_scheduler.dart`,
`app/lib/player/background_recorder.dart`, `app/lib/data/scheduled_recordings.dart`,
`app/android/app/src/main/kotlin/com/capytv/app/RecordingService.kt`.

## Touch gestures

On touch screens a finger **up or down** on the left half sets the screen's brightness (the
system's comes back on leaving the player), on the right half the volume; **sideways** it seeks, a
swipe across the screen being a minute and a half. Double tap on either side skips ten seconds.

## Picture in picture

On Android phones and tablets the player goes on in **picture in picture**, a small window over
other apps: by its button, or by leaving the app while something plays (Android 12 and later open
it by themselves; before, the app does on the way out). The window shows the picture alone, with a
play/pause button. Not on TVs, where a remote has no way to it. On Windows the same button (or
**P**) makes the app's own window small, in a corner of its screen, shaped like the picture and
over the other programs: dragged from anywhere it moves, and the pointer over it shows play/pause,
*Back to the window* and close. A double click, Esc or *Back to the window* bring the window back as
it was (maximized or in full screen, if it was); close does too, paused. Code:
`app/lib/player/pip.dart`, `app/lib/player/player_system.dart`, `MainActivity.kt`, and on Windows
`DesktopWindow.enterMini` in `app/lib/desktop_window.dart`.

## Keeping the sound in the background

With **Keep playing outside the app** on (Settings → Playback, phones and tablets), what plays
goes on with the app in the background or the screen off: sound only, as no picture is decoded
while nobody sees it (it comes back with the app). Its controls are in a notification and on the
lock screen, with the poster, play/pause, stop and, for movies and episodes, the progress bar;
headsets' buttons work too. A call or another app's sound pauses it, and so do headphones coming
out. A foreground service keeps Android from closing the app meanwhile; swiping the app away from
the recent ones ends it. Off by default: a paused stream still holds one of the provider's
connections. Code: `app/lib/player/background_play.dart`, `app/lib/player/player_system.dart`, `PlaybackService.kt`.

## Player settings

**Player settings**, for the session:

- a **sleep timer**: 15 to 90 minutes, or when what plays ends instead of going on to the next
  episode. When it is up the progress is saved and the stream closed (a paused one would still
  hold one of the provider's connections), so the device may sleep; *Keep watching* opens it again
  where it was. Code: `app/lib/player/sleep_timer.dart`;
- the **picture**: fit, fill (edges cut), stretch, or a shape of its own for a stream sent wrong
  (16:9, 4:3, 21:9); also the button on the controls, and kept for next time;
- a **volume boost** of up to +12 dB for streams with low audio (an audio filter in mpv);
- the **decoder**, hardware or software, without leaving: a running player cannot change its
  decoder, so a new one opens what plays where it was (with the session's speed, volume and boost)
  and the old one lets go. *Software* is software decoding everywhere (on Android it used to be the
  hardware decoder copying its pictures back);
- **stream info** over the video: resolution, codecs, frame rate, audio channels, decoder,
  bitrates, buffer, dropped frames and which copy plays;
- an episode's **series intro**: marked once (start and end, where it plays), the series' other
  episodes offer **Skip intro** while it plays; kept on the device by the series' title, so another
  provider's copy has it too. Code: `app/lib/data/intro_marks.dart`.

## Audio and subtitles

**Audio and subtitles** also has the sound and the subtitles **in sync** a tenth of a second at a
time (for this session), and how the subtitles look: their **size**, a **band** behind them and how
dark it is, a sharp **outline**, and how **high** they sit (kept; also in Settings, as the app's own
**text size** is). In an
episode's last half minute a card offers the **next episode** now, or not at all; OK on a remote
takes what is offered on screen (skip intro, next episode).

## Code

The player's code is `app/lib/player/player_screen.dart`: opening a title and its copies, keys,
gestures and the screen's own state. Its parts, each in a file of its own, are what it draws over
the video (`player_overlay.dart`, `player_controls.dart`, `player_panels.dart`), recording
(`player_recording.dart`), a live channel that froze (`player_reconnect.dart`), why a stream did
not open (`player_failure.dart`), a profile's time per day (`player_time_limit.dart`) and what it
tells the system and hears from it (`player_system.dart`); each names what it needs of the screen.
`app/test/player_logic_test.dart` plays them with a player that does as each test says.
