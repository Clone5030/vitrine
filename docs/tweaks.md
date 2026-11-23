# Working on the mod

## Layout

    tweak/                      the Theos project: Makefile, control, the bundle filter plist
    tweak/Sources/Core/         what every file builds on: logging, preferences, view-tree walking, glass panes, the
                                look this launch runs (SGUIMode.h), the forced-flag registry (SGFlagForce.h) and C
                                functions Spotify imports hooked by rebinding its import slots (SGRebind.h)
    tweak/Sources/Headers/      reverse-engineered Spotify classes, one header each, only the selectors used
    tweak/Sources/Settings/     the Mod Settings framework: SGPage (a page on Spotify's stack), SGModPage (sections
                                of rows: switches, choices, sliders, links, rows shown only while a choice
                                asks for them, and rows grayed out while the switch they wait on is off, a tap
                                on one nudging that switch), SGPageStyle (the system Settings look), SGGlowSwitch,
                                SGMarquee (a title that glides side to side when it is too long, for every layer)
    tweak/Sources/Shared/       what works the same with either look, see Layers below
    tweak/Sources/Native/       tweaks on Spotify's own screens, running only while Redesigned UI is off
    tweak/Sources/Redesigned/   the redesign, running only while Redesigned UI is on
    tweak/Sources/App/          what brings the layers together: Mod Settings' root and composed pages, the Mod page,
                                backup and signing, the welcome tour
    tweak/Sources/Diagnostics/  screen dumps, the tree server, the phone driver and the main thread hang sampler of FLEX builds
    extension/LiveActivity/     the Live Activity widget, a WidgetKit extension of its own
    extension/AppGroups/        a dylib loaded by Spotify and its home screen widget that moves Spotify's App Groups
                                into a group the re-signed IPA has; without it the widget stays a placeholder
    scripts/                    pipeline.sh (build + inject), build-extension.sh (the widget extension, without an
                                Xcode project), merge-appintents.py (the widget's intents into Spotify's), insert-dylib.py (a load command into
                                Spotify's widget), install.sh (sign + install), record-trees.py, record-session.py,
                                dump-log.sh, extract-flags.py, check-layers.sh (the one-way imports between layers)
    trees/                      recorded view trees, one per screen; the input for every new hook. trees/clean/ holds
                                the numbered snapshots per screen of record-session.py, taken of Spotify as it came
    plist/                      Info.plist overrides merged into the app (turns UIDesignRequiresCompatibility off; the
                                Bonjour services are added to Spotify's own list by pipeline.sh)
    vendor/                     AutoFLEX deb; audio/, the third-party C of the audio effects (libbs2b, WDL's EEL2) and
                                the EEL2 parser of the mod's own, built by its own Makefile into a static library the
                                tweak links (its README names the upstream commits and the licenses)
    ipa/, out/                  decrypted Spotify IPA in, built IPAs out (both gitignored)

`tweak/Sources/Shared/Flags/SGFlagList.m` is generated from the IPA and gitignored, as are the
recorded trees: both are read out of Spotify's own binary and belong to whoever built them.

## Layers

The mod has two looks, picked by Redesigned UI at the top of Mod Settings: Spotify's own screens with the mod's
tweaks on them, or the redesign, which starts from a clean sheet. What does not draw on Spotify's
screens works under both. So the sources are four layers, each a directory of features:

    Shared/       works the same with either look
    Native/       Spotify's own screens tweaked; every %ctor starts with `if (!SGNativeUI()) return;`
    Redesigned/   the redesign; every %ctor starts with `if (!SGRedesignedUI()) return;`
    App/          Mod Settings' root and the pages that combine the layers, the Mod page, the tour

`SGRedesignAvailable()` (Core/SGUIMode.h) says whether the OS has the redesign's material, iOS 26 and up:
it is Liquid Glass, and `UIGlassEffect` is the system's, so on an older OS the glass calls fall back to a
blur and the redesign runs untested against an older UIKit (issue #37, an iOS 17 scene-update watchdog).
Below 26 the Redesigned UI switch stores `SGKeyRedesignUntested` instead, and turning it on shows what
the redesign risks there and restarts Spotify from the alert; the tour offers the redesign card too, Legacy
picked, with the same warning under the cards. `SGRedesignedUIStored()` answers YES below 26 only with
that key set. A launch with the redesign below 26 leaves a mark that the main queue takes off after 15 s
or as Spotify first leaves the front, so a launch that hung is followed by one in the native look, with both switches off. The stored key
is left alone on iOS 26, so a phone that updates gets its redesign back.

The two looks never run together, so each hooks the same Spotify class in its own way, and a part of
the look is edited on its own side without touching the other: where both need the same thing, each
has its own copy (the tab bar's composition and its editor, the lyrics page's glass, the soft top edge,
AMOLED, the accent color), under its own names (SG… native, SGR… redesign) and its own keys. The imports run
one way, Core <- Settings <- Shared <- Native | Redesigned <- App, and `scripts/check-layers.sh`, run
by tweak/Makefile before every build, fails on any other. A layer below that needs something from one
above takes it through a registry in Core (forced flags, SGFlagForce.h) or a function declared low and
defined high (SGOpenModSettings).

A feature is a directory in its layer holding everything about one area of the app:

    <Feature>.h            the keys of its switches, and the functions other files may call
    <Something>.x          the hooks, one file per screen or mechanism, each ending in its own %ctor
    <Feature>Settings.m    its Mod Settings page, or its sections for the page of the part it changes, built from
                           the rows in Settings/SGModPage.h; App/Pages.m puts them on the page
    <Model>.m              plain Objective-C the hooks and the page share, where there is any

Shared:

    AdBlock/      EeveeSpotify's ad blocking: the ad and upsell services silenced (AdServices.x), ad components out of the
                  Hub JSON (AdHubs.x) and the feeds (Feeds.m), Premium pop-ups dropped (AdPopups.x), and the responses
                  rewritten on the way in (AdNetwork.x, Premium.m over the protobuf walker in Protobuf.m), with crossfade
                  and automix switched on in the player core and crossfade's switch kept in step with its slider (Crossfade.x).
                  With Spoof Premium on, RadioModes.m enables shuffle and repeat for radio/autoplay in either look:
                  only restrictions made entirely of radio, endless_context and autoplay are allowed.
                  Raw reason sets remain intact when Spotify copies its state. Positive radio evidence survives
                  empty optimistic updates only for the same playbackId/contextURI; explicit non-radio reasons revoke it. The matching
                  command's ESP request gets overrideRestrictions before the core receives it; other restrictions
                  and commands stay as Spotify supplied them. The hooks install together only when the expected
                  runtime signatures match. Checked by harness/radio-modes/; its README records device evidence.
    AlbumQueue/   With Spoof Premium on, adds Add to Queue to an album page's header menu when Spotify leaves
                  that row out, under either look. The Creative Work page's template.creativeWork.uri is read
                  by named Swift reflection and checked against the header's menu button; a track menu is
                  never inferred from the page it happens to be on. Native marks the header button just before
                  UIKit dispatches its registered touch-up or primary action (target/selector or UIAction);
                  the redesign marks the original button before its pinned mirror fires it. One marker is
                  consumed by one menu. Spotify's context resolver supplies the ordered track URIs, including
                  repeats, then SPTPlayerQueueWrapperImpl's queueMultipleTracks:loggingParams: submits them
                  with Spotify's own queue handling. Account attributes and restrictions are unchanged.
                  A missing page or malformed response fails before submission; paginated answers are
                  currently rejected rather than queueing part of an album. Checked by harness/album-queue/;
                  Spotify 9.1.90 simulator evidence and the remaining device checks are in its README.
    Privacy/      telemetry blocking and its counters, and the tracking taken off shared open.spotify.com links
                  (CleanLinks.x over the cleaner in CleanLinks.m)
    ArtistBlock/  tracks by blocked artists skipped as they start (ArtistSkip.x), the list and the Blocked artists page under Player
    Flags/        Spotify's remote-config flags: the provider hook, the generated table, the All flags page and the Labs page;
                  the provider pins 9.1.88's ios-reprise-liquid-glass-override.mode to default in both looks (after an All flags
                  override) and logs the server's own value once, as a force_disabled would take the glass off the redesign.
                  It also pins 9.1.90's ios-navigationui-tabbar-impl.is_liquid_glass_tab_bar_enabled off in both looks.
    Gestures/     the double tap zones on the player: the grid, what each cell does, the recognizer (each look hooks it on)
    Lyrics/       the lyrics engine for the redesign's Apple Music style lyrics and the lock screen: lines read from
                  color-lyrics and the player's clock (KaraokeSource.x), words timed by estimate inside Spotify's line
                  times (KaraokeTiming.m, which splits Thai, Lao, Khmer and Burmese at the system's dictionary words), which line to name where two voices sing at once (the one that came in first,
                  for the lock screen and the Live Activity), a line in another alphabet in Latin letters, offline by Apple's
                  transforms, kanji read the Japanese way in a song with kana (Romanise.m; checked on the simulator by
                  harness/lyrics' -romanise), and the Lyrics page's parts. Lines are kept in time order
                  whatever order a source lists them in. The Lyrics page's Delay (Timing, 0 to 1000 ms, either look)
                  shows every line that much later than the song, for Bluetooth headphones: whatever times lines
                  against the position takes it off first (the redesign's lyrics view and its word sweep, the lock
                  screen's line and artwork, the Live Activity, the native look's lyrics page for local files), and a
                  tap on a line seeks to its start plus the delay. Karaoke's audio, the scrubber and the lyrics preview
                  are left alone. It is read at every use, so a change applies at once (checked by harness/lyrics' -check). With EeveeSpotify injected (SGEeveeSpotifyInjected), its lyrics
                  answer Spotify's requests and the mod's sources and its own requests stand aside
    LyricsSources/ the sources lyrics come from, asked in the order the Lyrics page puts them in and merged into the
                  best answer (LyricsSources.m, the list to drag in LyricsSourcesPage.m): Apple Music's TTML from
                  BiniLyrics.m (now lrc.red: first the TTML filed under Spotify's ISRC for the track, from
                  SGSpotifyISRC in Haptics/SystemMusicHaptics.x, else its search by name) and Unison.m, read by SGTTML.m,
                  which carries a second voice and the backing vocals, and in its head Apple's translation and its
                  pronunciation of a line, each keyed to the line by its itunes:key or lrc:key, the pronunciation
                  timed word by word (the translation taken in the Lyrics page's language); Musixmatch.m, matched by
                  Spotify's track id with an anonymous token, word timed where it has richsync; NetEase.m, word timing from yrc for what the others only line time; LrcLib.m, open and
                  keyless and timed by the line, by the word where a record carries a Lyricsfile (Lyricsfile.m reads its YAML), the floor under the rest; its search answers with whole songs, so only a record that is the track (SongMatch.m) can win. SpicyLyrics.m, Spicy Lyrics' Developer Platform
                  by track id on the user's own publishable key (Keychain), syllable timed where it has a sync, with
                  its pronunciations and translations; its credit, which its terms require, shows whatever Show source
                  says and opens the uploader's and maker's pages from a tap (both looks), its answers and misses are
                  kept per track, a rate limit is waited out and a refused key is left for 10 min, its reason on the
                  source's row; checked on the Mac against harness/spicy-lyrics/. QQMusic.m (line timed LRC) and KuGou.m (word timed KRC, unpacked with
                  zlib and read by NetEase.m's parser) for Chinese and other Asian songs, matched by title, singer
                  and length; checked on the Mac against harness/lyrics-sources/. Genius.m, last: untimed words for a track no
                  other source has, the song found by the search the line meanings share (SGGeniusSongIn in SongMatch.m, whose match LRCLIB's search shares too)
                  and the words read from its embed script, which is scraping (no API gives the text); checked on
                  the Mac against harness/genius-lyrics/. color-lyrics is answered with whichever won
                  (LyricsHook.x): Spotify's own 200 gets our lines swapped in; a track Spotify's metadata says has none has
                  its request sent to a donor track that does, so the reply is a real 200 (a 404 answered as a 200 in the
                  delegate alone never showed the card on 9.1.78); a 404 for a track not seen yet is held until the chain
                  answers. The card list the server sends per track (scrollsita) carries a lyrics section only for tracks
                  Spotify has lyrics for, so one is added to any list without it: that is what makes the player ask for the
                  lyrics and show the card. has_lyrics is forced on for every track, the walk starts at the track change
                  for it and the next, and the player's card-loading timeout flag is forced to its 5 s maximum while a
                  source is on. In the redesign, with a translation language chosen, lines kept for the lyrics view with
                  no translation of their own take Musixmatch's community translations (Musixmatch.m), whichever
                  source won, Spotify's own included: matched by the line's folded text, as copies kept in place of the
                  lines (KaraokeSource.x), which the view picks up. The walk stops at the first timed answer; with
                  Prefer word-by-word timing (off by default, read by every walk) it asks on to the first source with
                  words timed and else keeps the finest it saw, the highest among equals (settled()). The redesigned
                  player's ⋯ has Lyrics Source (LyricsPick.m): every source asked at once for the song playing, a pick
                  shown at once and kept in memory until Spotify quits, and Automatic putting back what the order chose
    LyricsTranslation/ a song's lines translated from the lyrics' corner menu, for the lines no source translated, three
                  ways, each its own item: on the iPhone by Apple's Translate (iOS 26, the song's language told by
                  NaturalLanguage, both languages downloaded in the Translate app or the item says where to) and by Apple
                  Intelligence's model (iOS 26 where it is on and speaks the language; permissive guardrails for changing
                  the user's own text, 12 lines a session, greedy and capped at 60 tokens a line, exactly one string a line by a generation schema; Translate retried once, as its first ask can fail while it loads), both in
                  OnDeviceTranslation.swift, the frameworks weak linked; and by an AI translator on the user's own key, picked on the Lyrics page (SGKeyAITranslator): Gemini, an OpenAI-compatible server (chat completions; OpenAI's unless a server URL is given, such as OpenRouter's or an Ollama on the network, which Spotify's ATS allows for local addresses) or Anthropic (the Messages API). Each provider is one entry of LyricsTranslation.m's table: its Keychain slot (one key each, never in the settings, so an export never has one), its model presets (the cheapest first; OpenAI-compatible has none and needs a model), its request and its reply's reader. The answer's shape is forced where the API can (Gemini a bare array, the others {"lines": [...]} by a strict schema), the reader takes either, and a 400 that names an optional field (Gemini's thinking level, OpenAI's schema or reasoning effort, Anthropic's output_config) is asked once more without them. The prompt is shared (Vitrine's with {language} and {count}, editable in a sheet, SGKeyAIPrompt) and the provider adds its sentence on the answer's shape; the model (spotifyglass.lyrics.<id>.model) and the server are read at each ask and checked as they are read, and the log names the provider, the model, the host and the prompt's SHA-256 prefix, never the key. Temperature is not offered: Anthropic's API turns it down and OpenAI's reasoning models take only the default. The menu item says where the lyrics go. Translate on iPhone and Apple Intelligence each have a switch that leaves them out of the menu (SGKeyLyricsTranslateOnDevice, SGKeyLyricsAppleIntelligence, both on). A translation that reads the same as its line (SGLyricsBareText) is not drawn under it, and the line still counts as translated. The translate items show for every song with Translate any song on (SGKeyLyricsTranslateEverySong, off), else only for a song NaturalLanguage finds in another language than the Lyrics page's (or the iPhone's): one distinct line in five it is at least 80% sure of, or two in another script (a verse in Hangul among English), not the whole song's guess (short lines sway that: Havana reads as Dutch), so songs half in English count and a repeated chorus weighs as one line; Translate on iPhone translates from the language most of those lines are in and leaves lines already in the target as they are. Apple Intelligence's lines show and are saved a batch at a time, only lines without a translation are sent, and a batch it turns down is skipped (asking again sends only those lines). Every finished translation is kept by SavedTranslations.m in Caches/Vitrine/Translations, one JSON file a song and language with each line's text to its translation under "lines" and who made it and when ("by", "model", "made"; a file from before has the lines alone and reads as Unknown), the newest 200, synced when the song's lines are shown: each line knows whether its translation was made here (SGKaraokeLine.translationMade), and a made one with nothing saved is taken off, so the Lyrics page's Saved translations row deletes them at once, posting SGLyricsTranslationsDidChangeNotification as Translate any song does for the open lyrics to sync and redraw. The translate menu names who made a saved translation and when, and for one an AI made (or no one known) offers Delete This Translation, which removes the song's file and the launch's answer for it, so asking again sends the song. Gemini's reply read and checked on the Mac
                  against harness/lyrics-translation/
    LockScreenLyrics/ the line being sung in the system's now playing, and on iOS 26 the lyrics as the lock screen's
                  full-screen artwork (LyricsArtwork.x): a new artwork ID per line, its 3:4 H.264 clip (the line and the
                  next one dimmed over the blurred cover, SGLyricsClip.m) written only when the lock screen asks for it,
                  Still (one frame) or Animated (15 fps). The backdrop is blurred small and drawn large, on the CPU as the
                  lock screen asks in the background; previews are drawn on a queue apart from the clips, and while the
                  lock screen is asking, the next line's preview and clip are drawn ahead and a ready preview is handed
                  over at once. iOS still shows the plain cover for about half a second at each change of artwork. Picking it or another artwork applies at once.
                  Moving artwork with lyrics (the choice's fifth value, 4) draws each line over the track's moving
                  artwork, which LockScreenMotion.x finds and hands over (SGLyricsArtworkSetMotion): the clip is the
                  stretch of the video the song is at while the line shows (its start taken round the video's length,
                  from the line's start to the next's plus a second, 2 to 8 s; a video no longer than that is written
                  whole, turned to start there, so its loop has no seam), at the video's own 3:4 cut and frame rate up
                  to 30 fps, with the line sung last dimmed above (dim, bright, dim). The video is decoded as BGRA, the
                  rows behind the words are blurred (Accelerate's tent blur) and faded in, every row of the cut is
                  darkened in one pass (0.25, and 0.6 across the words), and the words with a tight dark shadow are
                  drawn on; the encoder cuts the 3:4 middle as SGMotionClip.m does, so nothing is scaled on the CPU.
                  The IDs end in the style and, over moving artwork, m and the first 16 characters of the file's name
                  (SGLyricsClipLook), so the clip arriving, a Canvas after an animated cover, or a change of style
                  re-offers the line showing. Until it comes, and for a track with no moving artwork, the lines are drawn
                  as Lyrics draws them, in the chosen style; so are they over a video that will not draw (turned, its
                  frames another size than it states, as a video with non-square pixels has, cut short or gone from the
                  store), which is remembered for the launch and tried again only when handed over again. A track with
                  no synced lines, or whose lines are not in yet, shows its moving artwork plain, as Moving artwork does:
                  LyricsArtwork.x says so (SGLockMotionShowPlain) and LockScreenMotion.x shows it and takes it off for
                  the lyrics' clips. Rendered on the Mac against harness/lyrics-clip/ (`motion`, over a
                  bright busy, a dark and any given videos). What reaches the
                  system's now playing through this hook and Player/NowPlayingExtras.x is checked by harness/now-playing/
    AnimatedArtwork/ moving artwork (AnimatedArtwork.h): the track's Canvas, else Apple Music's animated album cover
                  (SGMotionCatalog.m: searched without the album's edition, the edition of the same name first, and
                  left alone for 10 minutes after a 403 or 429; an album's answer kept on disk for a week, so a relaunch skips the search), kept as local files (SGMotionStore.m, a download that
                  fails on the way tried once more), on iOS 26 the lock screen's full-screen
                  artwork (LockScreenMotion.x). With Every song, a song with neither gets its cover over copies of it
                  blurred and swaying, a seamless 8 s 3:4 loop drawn on the CPU only when the lock screen asks for it
                  and kept per picture (SGFluidClip.m). Rendered on the Mac against harness/fluid-clip/. A track whose
                  metadata names no Canvas has it asked of Spotify's Canvas service (MotionSources.m); each track is
                  looked up again when its Canvas comes in a later state, and the next track's clip is fetched ahead
                  (SGMotionFollower.m). The lock screen takes a clip under a key the system lists, cut to that key's
                  shape when it is not, with its still filled to the size asked (SGMotionClip.m), and a change of the
                  choice applies at once, Lyrics too. Switch with the star (spotifyglass.lockscreen.star, off;
                  LockScreenStar.x) puts a star on the lock screen widget, MediaPlayer's like command, whose tap swaps
                  the choice for the one the star last left (kept under spotifyglass.lockscreen.star.back) when that one
                  is on the other side, with lyrics or without, else for Lyrics or Moving artwork: Lyrics swaps with the
                  moving artwork it left (Moving artwork or Every song), and Moving artwork with lyrics counts as lyrics,
                  so it swaps with Moving artwork. The star is filled while the lyrics show; the choice is the setting, so the
                  mode outlives a relaunch and the page's row follows it. The star takes the slot of Spotify's like
                  and dislike buttons, so their flag is forced off at launch while the switch is on, over the row's
                  own override, and the row shows it locked. The cut and the service's wire format are checked on
                  the Mac against harness/motion/
    LocalFiles/   local files (LocalFiles.h lists its files): Edit info in the player's ⋯ menu, the table's footer
                  under Speed and pitch, which closes the menu and opens a form sheet (the three names, the cover
                  with a menu to change it, Restore file's info; nothing is stored before Save, and a swipe away
                  with changes asks first), storing a title, artist, album and cover by the file's URI and laying them
                  over -[SPTPlayerTrack metadata] and the cover's image request (the redesign's artwork reads the
                  stored cover itself, Redesigned/Kit/SGRBridges.x); the file is never written. Their
                  lyrics are kept under the URI and asked of the sources by name, since Spotify never asks for them;
                  with no source switched on, of LRCLIB alone, which then gets the file's title, artist, album and
                  length. A rename gives a new key (a cover alone does not), asked for at once while the file plays.
                  A miss is asked again a few times, in case it was a lost request. The user's own .lrc files
                  (LocalLyrics.m), imported from Files on the Imported LRC files page under Lyrics' sources and kept
                  as UTF-8 in Documents/Vitrine/Lyrics, come before any source: a file linked to the local file
                  playing (Import for current track) is its lyrics whatever its tags say, and any other is matched by
                  [ti:] and [ar:], or a name of "Artist - Title", folded; an import or a delete has the engine forget
                  what it kept for local files and ask again. SGImportedLRCAsk is the same as a source for the
                  order, which moves it on top at the first import and at every link once LyricsSources lists it.
                  Where Spotify's player shows its placeholder for a local file, the file's own cover is found
                  (LocalCover.m) in the image fields of its metadata or, while the titles and artists agree, in the
                  system's now playing artwork, which the lock screen shows; the native look puts it into the front
                  cover's empty image view (Native/LocalFiles/LocalCover.x), the redesign's artwork bridge takes it
                  as the picture of a local file whose metadata names none. A cover picked in Edit info wins.
                  The model and the LRC reading are checked on the Mac against harness/local-files/, the row and
                  the editor in the simulator against its sim/
    Navigation/   the page transition fix (PageTransition.x), opening a spotify: link (Links.x), and either look's
                  Add a Tab sheet (AddTabSheet.m) with the icons a tab can wear, Encore's glyphs or SF Symbols
                  (TabIcons.m). The sheet runs in the simulator in harness/addtab/
    Player/       the player's open and close announced (PlayerEvents.x), what the player is doing read through
                  one hook for every feature that wants it (PlayerState.x), the last track played for the settings
                  pages' previews to show when nothing plays (SGLastTrack.m), the lock screen widget's flags, and in the
                  more button's menu Speed and pitch: both done to Spotify's audio by Apple's time and pitch unit, put
                  between its mixer and its RemoteIO unit by taking over the connection Spotify makes between them
                  (SpeedPitchMenu.x, SpeedPitch.x, SGTimePitch.m). Spotify runs a chain per sample rate, so a local
                  file at another rate can have two RemoteIO units running at once: SpeedPitch.x keeps a record
                  per unit (its own mixer, sample time, largest slice and formats; AudioOutputUnitStop and
                  AudioComponentInstanceDispose rebound too, a disposed unit forgotten after its render in progress)
                  and names one the music's (SGPlayerMusicOutput), the one Spotify started or connected last, or
                  one with sound when that one has had none for a second; speed and pitch, Karaoke's stage, the audio
                  effects and Music Haptics follow it (SGPlayerWatchMusicOutput), and the other plays as Spotify
                  made it. A connection whose formats the callback cannot take (not float with a buffer per channel,
                  more than two channels, or a mixer at another rate than the unit) gets Spotify's own connection
                  back. Each start, stop and dispose is logged as `audio:` with its formats and where the processors
                  are. Pitch follows speed (on until switched off,
                  spotifyglass.speed.pitchFollows) plays the speed through Apple's Varispeed instead, faster and higher
                  together like a record; Varispeed also carries 1x while it is on, so a return to normal speed changes
                  nothing, and the stretch is left for pitch alone at 1x, the two swapped only through a reset. A new
                  format on either side of the output while it runs (a route to another rate, Spotify handing it
                  another one) makes the unit again for it, and until then the sound passes as it is. harness/speed's
                  `two` runs a 44.1 and a 48 kHz chain at once. Under the
                  sliders a Reverb slider sets the audio effects' reverb amount (spotifyglass.dsp.reverb.amount), turning
                  the effects and the reverb on with it. The block goes into Spotify's own context menu sheet
                  and is drawn from its own measures, not the Kit's, so it sits there under either look. Tested on the
                  Mac against harness/pitch/ and in the simulator against harness/speed/ and harness/menu/. Under the
                  redesign, with the player's background Fluid or Animated, a row under the block switches Animated
                  artwork at once, through functions the redesign's PlayerMotion.x defines. The redesign shows that
                  sheet as the system menu (Redesigned/ContextMenu), whose own items stand in for the block, so the
                  block stays out of it unless the sheet itself is shown (SGPlayerMenuReplaced). Switch to video,
                  the chip over the title of a song with a music video, is hidden under either look on request
                  (VideoSwitch.x, spotifyglass.hide.videoSwitch), by its identifier in FloatingElementsUnit.
                  The sleep timer (SleepTimer.m, set from the Live Activity) pauses Spotify at a time, at the end of
                  the track or at the end of the album or playlist, the last track of it found by the tracks to come
                  that are neither queued by hand nor autoplay's (SPTPlayerTrack's provider), or by the next one
                  having played already when it repeats. Over the last seconds (the Live Activity page's Fade out: Off,
                  10 s, 30 s, 1 minute or 2 minutes, 30 s unless picked; at the end of a track, over the whole track
                  when it is shorter) it fades the sound 60 dB through a gain of the mod's own, applied by SpeedPitch.x's notify on the music's RemoteIO unit (never the system
                  volume), and puts the gain back a second after the pause. Spotify's own timer, from the player's
                  ⋯ menu, fades by the same choice and gain (SpotifySleepTimer.m): the core reports it in the player's
                  state (SPTPlayerState's sleepTimer: type 1 at a timestamp, 2 at the end of the track), checked four
                  times a second while Spotify plays; Spotify pauses, the gain is held down from its end until that
                  pause and back a second later, at once on a cancel or a later time. It stands aside while the mod's
                  own timer runs and while Spotify's own Fade out flag (its DuckHandlerImpl's duck) is forced on.
                  Tested on the Mac against harness/sleep-timer/, the gain in the simulator against harness/speed/
    AudioEffects/ the audio effects on Spotify's sound (AudioEffects.h has the keys and the page's calls): a render
                  notify on the music's RemoteIO unit (SGPlayerMusicOutput, Shared/Player) runs each finished buffer through the mod's own engine, re-blocked to 1024 frames one block late,
                  in place (AudioEffects.x, SGDSPEngine.m), then hands it, mixed to mono, to one reader that only
                  reads it, switch on or off (SGAudioSetOutputReader: the player's Visualizer). The buffers are in the unit's output format, the
                  hardware's, not the client format Spotify sets. The effects are the SGDSP*.m files, on Accelerate,
                  Apple's Reverb2 unit, libbs2b and EEL2 (vendor/audio). Settings apply as they change, on a queue of
                  its own; the file effects read their files from Documents/Vitrine/Audio effects
                  (AudioEffectsFiles.m). Presets and Headphones (AudioEffectsPresets.h lists their files): seven
                  built-in presets over a reset that keep the Graphic EQ, the user's own as a copy of every dsp key, the
                  settings from before the page's first pick saved as one of them, Before presets, and AutoEq's
                  corrections, its INDEX.md fetched from GitHub and cached a month in Caches/Vitrine/AutoEq, a
                  headphone's GraphicEQ file put into the Graphic EQ (AutoEq.m), None taking it off; a pick turns the
                  master switch on. A pick can be kept per output (spotifyglass.audioOutputs, by the port's UID): on
                  every AVAudioSessionRouteChangeNotification to another output (AudioEffects.x), a remembered output
                  gets its correction or None, and any other output takes off a correction that came on for one; a
                  pick made with nothing remembered and a curve of the user's own stay, and the master switch is
                  never touched. Checked on the Mac by `harness/audio-effects/build.sh route`.
                  Tested on the Mac against harness/audio-effects/ and harness/autoeq/, the hook in the simulator
                  against its sim/, the page against harness/audio-effects-page/
    AutoMix/      Spotify's own Automix and Crossfade, which its player core does, set from one page (AutoMix.h lists
                  its files): Style picks Beat-matched (Automix and crossfade on) or Crossfade (Automix off), Blend
                  length is Spotify's crossfade time (1 to 12 s, kept in milliseconds as Spotify does). Every write goes
                  through Spotify's preferences object (SpotifyPrefs/), so Settings > Playback shows the same values,
                  and the player takes a change at the next track change, with no restart. Turning the switch on saves
                  Spotify's three settings; turning it off puts them back, and so does Reset all settings. A switch
                  flipped before Spotify has read its settings takes effect once it has. While the switch
                  is on, one log line per track change (the probe) gives the current and next track's automix.* and md_*
                  metadata and the settings
    SpotifyPrefs/ Spotify's preferences object, the one Settings > Playback writes, captured as Spotify makes it at
                  launch, for Lossless's streaming quality and AutoMix. Its user's settings read 0 until they are read
                  in, about 3 s into a launch, so SGSpotifyPreferences is nil until the playback speed (a percent, never
                  0) is set; then what Lossless and AutoMix left to do is done
    Sing/         Karaoke (Sing in the code and its keys), a song's vocals turned down while it plays (Sing.h lists
                  its files): the voice model Voice model chooses (spotifyglass.sing.model, read live: Best quality,
                  the default, is Mel-Band RoFormer, MIT, exported by Vitrine for the Neural Engine and palettized to
                  6 bits: separator-ane.mlmodelc, 210 MB; Light is the vocals of HiDolen's Mini-BS-RoFormer-18M, MIT,
                  exported in float16 by harness/sing/export_light.py with the same input and output:
                  separator-light.mlmodelc, 31 MB, more of the voice left in and the music dipping under it; both
                  from the same Hugging Face repo, each with its own pins, staging folder, resume data and paused
                  bytes; on a FLEX build a copy of the chosen one in Sing/dev/<its folder> comes first; a switch
                  stops a running download, keeping what came in, and Sing.x loads the chosen model at once, no
                  restart, or lets the old one go if the chosen one is not downloaded) downloaded and checked file by
                  file over Wi-Fi unless cellular is allowed,
                  a stop keeping what came in for the next download to carry on from; the 489 MB model downloaded
                  before is kept and loaded on the CPU alone until this one is in (the Voice model row then reads
                  Update available), and deleted as its download ends or at a launch that finds both
                  (SGSingRemoveOldModel, which logs the space freed), Sing moving to the new one at its next load;
                  loaded only while Spotify
                  is active (SGSingLoader.m), on any iPhone with iOS 18, a CPU copy first and warmed, only with 1 GB left to the
                  process (0.4 GB for Light, and 1.6 or 0.65 GB beside a load still out; no floor on the iPhone's memory: both copies warm add 0.1 GB of footprint), then on Automatic, where the iPhone has a
                  Neural Engine, a Neural Engine copy of the same model beside it, which takes every window once it is
                  in, in the background too, each load with a deadline and kept a minute after the mic goes off; the
                  Neural Engine copy loads only with 0.5 GB left to the process (0.25 GB for Light), its first load after every install
                  compiling it for up to ten minutes while Karaoke runs on the CPU (while it loads, the CPU's falling
                  behind spends none of the 8 s after which Karaoke gives a song up, nor counts toward its three in a
                  row), unless Prepare after updates (on by default) compiled it already: with the model in and the mic off, 15 s after
                  Spotify comes to the front and below the thermal state Serious, the Neural Engine copy alone loads once for this
                  iOS and install and is let go (22 s on a fair iPhone 15 Pro, 48-65 s on a serious one; a want meanwhile takes that
                  load over), so the mic's copy loads in 0.3 s; Karaoke's status reads "On, Neural Engine" or "On, CPU", and "Off ·
                  preparing for the Neural Engine" while it compiles ahead, and it is dropped for the launch, the CPU copy carrying on, once it fails to load, warm up or
                  run a window (one that falls behind keeps its place); Runs on is Automatic or CPU only, the GPU and
                  Neural Engine choices stored before read as Automatic; the STFT around it on Accelerate,
                  and an engine that stands in Speed and pitch's chain between Spotify's mixer and its output
                  (SGPlayerSetStage), pulls the mixer a few seconds ahead of what plays, never past sound Spotify has not
                  decoded yet (a part of a pull ahead its mixer marks silent is left out of the lead and read again at the
                  next render, so a slow network fills the lead more slowly and a stall plays through on it; "sing: read
                  ahead:" in the log, the first three times and then a count a minute), separates two-second windows
                  there on a worker thread and mixes the vocals down on the render thread. Spotify's clock has the lead
                  taken off (SPTPlayerState's positionAsOfTimestamp): the lead held when that line of the clock began
                  (the same position run on at the same speed, however often a state is stamped again), less what was
                  dropped since, as the player reports on a change and not as it plays (SGSingLeadOf, read by every
                  correction); run on (-position), the lead comes off after running on and never below 0, so a track
                  reached as the last one ends, reported while the lead still holds that end, stays at 0 until its first
                  frame plays rather than running on from the title change (every 5 s a "sing: clock:" log line sets Spotify's clock against what the engine pulled
                  and played, and every lyrics seek logs where it was sent and where it landed), and a seek, a skip or a stop drops it.
                  Until the seek or skip lands (Spotify reports the target or the new track, or 5 s pass) nothing is
                  read ahead, as Spotify's mixer still hands over what came before it; the queue's next track arriving
                  up to 12 s early is crossfade and keeps the lead, another track arriving early drops it; on the
                  queue's last track (no next, no repeat) the lead drains at half speed so it has played out a second
                  before Spotify's decoder reaches the end (SGSingEngineSetLeadCap). Not separating (stopped, held, resting at As sung,
                  standing aside), the engine plays the lead it holds on as it is, dry, the clock still corrected, so no
                  part of the song is skipped; it lets it go at a pause, where Sing.x seeks Spotify back to what was
                  heard (and so when the headphones it played on go), or with a seek, a skip or the output stopping, and builds one only when it separates.
                  Karaoke stands aside, the model kept, over AirPlay, for what is not a song, and while Spotify plays
                  but its output has not rendered for 3 s (Connect to another device: "Not on this iPhone"); an
                  interruption (a call, Siri, another app's audio) holds the worker and keeps the lead until iOS says it
                  ended or the sound comes back, Spotify deciding whether to resume. At As
                  sung with Spatial voice off it rests (held as for the heat, the model kept a minute as for a mic
                  switched off, "sing: rests" in the log) unless the Karaoke page's card is on screen with Spotify in
                  front: its reads of its two lines (SGSingReadLevels; the card's traces, not the lyrics, which are no
                  viewer) keep Karaoke separating the playing song, so the lines move and the slider is heard at once
                  ("sing: separates again"), and a second after the page is popped, covered or in the background it
                  rests again. From the
                  thermal state Serious up Karaoke is held and lets the model go,
                  unless Ignore heat warnings is on, and runs again at Fair. Spatial
                  voice holds the separated vocals in front as the head turns: HeadGestures' motion gives the yaw off a
                  front that follows the head (Back in front, 5 s unless set), and the render thread pans the vocals' middle at equal power,
                  narrowed, with the far ear up to 0.65 ms late and low-passed; it stands down for iOS's own spatial
                  audio. Its Sound section sets Distance (the voice down by the square root of the distance), Room
                  (a wet-only AUReverb2 fed the voice's middle, emptied by a seek) and Instruments width (the rest's side
                  scaled); off, all three leave the song exactly as it was. The Spatial voice page's preview (SGSpatialPreview.m) turns a disc of dots under the listener by
                  the same front (SGSpatialVoiceAngle, SGSingEngine.h), on Core Animation alone and only while the page
                  shows. The mic is on the redesign's lyrics (Redesigned/Lyrics/SGRSingButton.m). Tested on the Mac
                  against harness/sing/ (the lead, its cap, a slow decoder, a track boundary, spatial voice and its front without the model: `build/sing spatial`; the
                  model as both copies with `ane`, as the CPU's alone with `cpu`), the download against its download/
                  (`update` for the old model kept until it, `dev` for the dev folder), the pages in the simulator against harness/spatial-page/
    Haptics/      Vibrations (Haptics.h lists its files): a tap of UIKit's feedback generators for the player's and the now
                  playing bar's controls, the scrubber's tenths and ends, cover swipes, gestures and the lyrics page's tap to
                  seek, at the strength set for them (ControlHaptics.x, SGFeedback.m); and Music Haptics, Core Haptics
                  playing along with the song: the music's RemoteIO output unit (SGPlayerMusicOutput, Shared/Player)
                  gets a render notify, the samples, in the unit's output format (the hardware's), go through a drum
                  and bass analyzer on the render thread (SGMusicAnalyzer.m, plain C), and a thread of its own schedules
                  the taps and the rumble for when the sound is heard, at their strength and leaving out what Follows
                  leaves out (MusicHaptics.x). Everything applies at once; nothing plays while Spotify is not the active
                  app. Beside it, In the Background (iOS 18 and up) asks Spotify's extended-metadata for the track's
                  ISRC with Spotify's own spclient headers, asks Apple Music's catalog for that ISRC (the phone's own country first, then the US), and names the
                  matched song's catalog id (same ISRC, length within 2 s, a haptic track) or else the ISRC in the now
                  playing info for iOS's own Music Haptics, which plays on the lock screen and in other apps too
                  (SystemMusicHaptics.x, its pure steps in SGHapticTrack.m). Both may be on: while iOS reports the named song
                  playing, the mod's own stays quiet, since iOS plays the track in front of Spotify too, and also while
                  it asks (10 s at most) and for 3 s after a song is named; with no report by then, once iOS has none,
                  while iOS's is paused in Control Center or in an install iOS does not list, the mod's own plays while
                  Spotify is in front. The analyzer is
                  scored on the Mac against harness/haptics/, as are the pure steps (build/track), the hook, the two
                  switches, the stand-down and the move from the old choice in the simulator against its sim/, the
                  settings against harness/haptics-page/
    HeadGestures/ AirPods gestures (HeadGestures.h lists its files): CMHeadphoneMotionManager's attitudes, while the
                  switch is on and Spotify plays, read for a double nod and a shake, each doing what its pull-down
                  says: Nothing, back or forward 15 s, play or pause (which listens with the song paused too), next or
                  previous track, shuffle, repeat, or Like, which adds the track to Liked Songs through Spotify's
                  collection platform (addURL:showUIConfirmation:completion:); Like and Next track until changed. A
                  tone played through Spotify's playback session confirms each, whatever the Ring/Silent switch says,
                  unless Chime on activation is off (spotifyglass.headgestures.chime; Try it and teaching always sound).
                  Try it listens a few seconds and names in its row what it picked up, doing nothing to the song. A
                  sheet teaches one's own nod and shake, five of each after a tone, a ring showing the head live (a dot
                  that moves with it, ticks lighting toward where it went; SGHeadMotionListen) and five dots counting
                  what landed, with Redo last; the threshold kept is the one that fires on all five but one at least, the nod
                  stored before the shakes begin, so Cancel keeps it. Forget shows only while something is learned.
                  The one CMHeadphoneMotionManager is lent to other features
                  (SGHeadMotionListen: Karaoke's spatial voice), and runs for them with the switch off, the detector then
                  unfed. The detector is
                  tested on the Mac against harness/head-gestures/, the hook and the page in the simulator against its sim/
    LiveActivity/ a Live Activity on the lock screen and in the Dynamic Island in one of three views, the line being
                  sung with the next one under it, the tracks up next (a tap on one skipping ahead to it), or a control
                  menu of tabs, Controls (previous, play and pause, next, shuffle, repeat), Queue and a sleep Timer of
                  the mod's own (Player/SleepTimer.m: 15 min, 30 min, 1 hour, End of track, End of album) that fades
                  the sound out and pauses Spotify, and stays set when the card is switched off (LiveActivity.h lists its files): a timer polls the player and
                  sends a new state only when what the view shows changes, local updates only, no push, and asks ActivityKit
                  only then. It ticks four times a second in the lyrics view and once a second in the others. The card
                  is tinted with the cover's color and shows the cover itself, a JPEG of a few dozen pixels inside
                  the state, which ActivityKit caps at 4 KB (the bridge sends it without the cover when it would
                  not fit); the color is darkened to a luminance of 0.04 at most, so the white text keeps 4.5:1 on any
                  cover, and the cover is read only once the now playing title is the new track's. The page's options
                  ride in the state too, read on every tick, so they apply within a tick: the lines' alignment, what the
                  lyrics view shows on a track with no timed lyrics (a note under the track, or the track large), the
                  colors (Spotify's green; Artwork, the cover's color lightened to about the green's luminance in its
                  place; Plain, white on the system's own background), and the progress bar. Artwork off sends no
                  cover at all. The page's preview (SGLiveActivityPreview.m) is a mock of the card in UIKit, not the
                  widget, checked in the simulator against harness/live-activity-page/. Taps are
                  LiveActivityIntents run inside Spotify and take a second or two to show on the card. The widget is extension/LiveActivity; ActivityKit pairs the two
                  by the attributes' type in LiveActivityShared.swift, compiled into both. It starts only with Spotify
                  in front; its settings apply at once. It ends when Spotify is swiped away while running; killed
                  while suspended, Spotify cannot end it, so each state goes stale a minute on (an unchanged card is
                  sent again every 20 s) and a launch ends any left over before it starts a new one. The same folder
                  gives Siri, the Shortcuts app and the Action button Like This Song, Play or Pause, Next and Previous
                  Track, Karaoke and Sleep Timer (AppShortcuts.swift lists them as Spotify's App Shortcuts), and iOS 18
                  controls for Control Center and the lock screen of Like, Karaoke and the sleep timer
                  (extension/LiveActivity/Controls.swift), buttons, as the extension cannot read Karaoke's state. Each is
                  a LiveActivityIntent or AudioPlaybackIntent, so it runs inside Spotify, launched in the background
                  when needed, and LiveActivity.x answers it with the activity on or off, Like through
                  HeadGestures.x's collection platform and Karaoke through SGSetSingOn; the sleep timer (15 min, 30 min,
                  1 hour, End of track, End of album or Off) is the card's own, Player/SleepTimer.m, which keeps its
                  own clock with the activity off. The intent asks again for 8 s while the player is not up,
                  then tells Siri to open Spotify. Checked in the simulator against harness/shortcuts/

    ListeningStats/ listening stats kept on the phone (ListeningStats.h lists its files): each music track timed while
                  it plays through PlayerState's observer and written to a text log in Application Support once it ran 30 s
                  or half the track (ListeningStats.x), Spotify's data export read in, either shape, loose or zipped, plays
                  already there skipped (SGPlayLog.m), and a page of the top tracks, artists and albums of a week, a month,
                  a year and all time. Tested on the Mac against harness/listening-stats/, the page and the recorder in the
                  simulator against its sim/
    Connect/      Connect speakers on the Wi-Fi for a build signed without the multicast entitlement (Connect.h lists
                  its files): Bonjour, which needs only NSBonjourServices (plist/, merged with Spotify's own list by
                  pipeline.sh) and the Local Network permission, finds and resolves _spotify-connect._tcp; Spotify's
                  imports of sendto, sendmsg and recvfrom are rebound, a Connect query the system refused is sent by
                  unicast to each receiver's port 5353 instead, and each answer is passed to Spotify's socket over
                  loopback with recvfrom reporting the receiver as its source. Spotify asks the same question from four
                  sockets, two for each address family, every two seconds or so; it is relayed once every 3 s for each
                  family (on a busy Wi-Fi with 21 receivers, 124 rounds a minute became 31), and a new question goes at once. No setting. Tested on the Mac against
                  harness/connect/

Native:

    Appearance/   AMOLED (Amoled.x), the accent color (Accent.x), the soft top edge (EdgeEffect.x), and Repaint.x, which
                  keeps what the native tweaks stripped transparent
    Navbar/       Spotify's tab bar composed (Navbar.x, NavbarLayout.m, hooked from TabBarHooks.x), the Navbar and Add a tab pages
    NowPlayingBar/ the device button hidden, the bar's flags
    Player/       the full screen player (Player.x), its cards and buttons hidden and a hidden lyric preview's room given
                  to the cover (PlayerDeclutter.x), the glass lyrics card (LyricsCard.x), the gestures' hookup and the hold
                  on either side of the cover that plays at 2x until the finger lifts (PlayerGestures.x), the list's pull
                  held off while the progress bar is scrubbed (PlayerScrub.x), the Queue & devices flags. The scrub and
                  the cover's room are checked in the simulator against harness/native-player/
    Lyrics/       the full screen lyrics page on glass, and a tap on the lyrics' footer opening the pages a credit
                  links to (LyricsPage.x)
    LocalFiles/   a lyrics button on the player's footer for a local file with an LRC file linked to it, a fifth of the
                  way in from the leading edge, which opens a page of the lines on black that follows the song
                  (LocalLyrics.h lists its files); the file's metadata says has_lyrics. Checked in the simulator
                  against harness/local-files/lyrics/. And the file's own cover where the player shows
                  Spotify's placeholder (LocalCover.x)
    Home/         the Home gradient, Home's sections and pills hidden (HomeDeclutter.x), the Home & Library page
    Playlist/     the playlist header and pills, hidden one switch each
    Album/, Artist/ their pages' parts hidden, and the cover or photo behind their headers

Redesigned:

    Kit/          what the redesign builds on (SGRKit.h lists it), the flags it forces (SGRedesign.h, SGRGlassDesign.x for
                  Spotify's own glass design), its repaint hook (SGRRepaint.x), soft top edge, AMOLED black (always on,
                  SGRAmoled.x) and its own accent color (SGRAccent.x, stored apart from the native look's). The
                  playlist, album and artist pages take their field's color from the cover's main color (checked on
                  the Mac by harness/palette/), and come in whole: a black veil over the page until the cover has
                  been read, at most SGRFieldHoldLimit (1 s), then faded away (SGRField.h)
    Navbar/       the glass tab bar (TabBar.x) over its own composition (Navbar.x, NavbarLayout.m) and editor, the glass search field.
                  Spotify is made to leave the glass bar its height where its own bar is shorter (a phone with a home button,
                  Offline or Private Session under the bar), so the now playing bar and the pages move up with it. Under both
                  bars the pages fade to half black (SGRBarFade, the stock bar's own subview). A page scrolled down
                  minimizes the bar to two circles, the first or current tab and the last, with the now playing card
                  between them, and a scroll back up, its top, another tab or the player brings it back
                  (TabBarMinimize.x, MinimizeStep.h; the Player page's Apple Music style). Spotify's container is no
                  UITabBarController, so UIKit's tabBarMinimizeBehavior and bottomAccessory cannot do it. The bars,
                  their circles and the card move as one, on one spring of their own (SGRMotionBar, 0.26 s, no
                  overshoot; at once under Reduce Motion), from what is on screen, so a change turned back half way
                  carries on from there. Each glass tab carries its name for VoiceOver and the large content viewer, labels
                  hidden or not, and the leading circle says it shows all tabs. Laid out on
                  the Mac against harness/tabbar/ (`mini`; a tap on the leading circle `tap`, real flings that turn
                  the bar half way `turns`, a minimize from inside Spotify's own animations `nested`, every frame of
                  the move sampled `motion`), the scroll's steps checked by harness/tabbar/minimize-check.c
    NowPlayingBar/ the glass now playing bar (NowPlayingBar.x), with Spotify's device button on it hidden on request
                  (BarConnect.x, its own key and its own row on the Player page, apart from the native look's). The card's text is the Music
                  app's, the title over the artists with no device line, drawn inside Spotify's own text on each swipe page
                  so it slides and fades with it; Spotify lays a page out as "title • artists" over the device line or as
                  title over artists, and both are read. In the minimized row
                  the card drops its device and add buttons, faded out as it heads there and back in as it leaves. Only the title stays in the row. In a Jam the
                  glass stays on the track and Spotify's Jam strip gets a pane of its own above it (harness/tabbar/, jam)
    ContextMenu/  the ⋯ of the player and the ⋯ pinned over the playlist, album and artist pages open the system menu,
                  always (ContextMenu.h). The player's ⋯ is a pull-down button of the mod's over Spotify's: the menu
                  opens on touch down with the quick row (Spotify's items 9, 19 and 11), the player's items and More,
                  waiting on nothing of Spotify's (the button holds a stand-in menu from the start, since UIKit opens
                  a button's menu on touch down only while it holds one, and the session's replaces it as the touch
                  asks); Spotify's ⋯ action is then run from code and its sheet presented
                  in a window of the mod's under the app's (the menu, a presentation of UIKit's from the player,
                  leaves no room for another there), read, and used to run a pick. More shows the last complete set
                  of rows stored for that kind of track (spotifyglass.redesign.player.menuRows.<kind>), or the
                  system's loading row the first time, and is put right in place as the live rows come. A page's ⋯
                  works the other way round: its tap opens Spotify's sheet, presented unanimated in a container hidden
                  from the presented controller's viewWillAppear: on, and the menu comes from an invisible button
                  inside the ⋯ that takes touches only while it is up, opened with -performPrimaryAction (else
                  UIContextMenuInteraction's private _presentMenuAtLocation:). Spotify's rows, read off the sheet's
                  cells (words, glyph, grayed out), and the mod's own rows in its header and footer (Sort, Mix, Edit
                  info) are fired on the hidden sheet once the menu is gone, through the row's own control (scrolled
                  to when it is below the fold); a row that pushes a page shows the sheet on that page, one that
                  presents a sheet of its own (Sleep timer) leaves that sheet as Spotify's and the card goes unseen,
                  and a close with no pick dismisses the hidden sheet. Checked in the simulator against
                  harness/system-menu/
    Player/       the redesigned full screen player (Player.h lists its files); its more button opens the system
                  menu (ContextMenu/), Spotify's rows and then Speed, Pitch & Reverb, which opens the sliders and
                  Pitch follows speed in a popover from the ⋯ (SpeedPitchMenu.x), and the backgrounds it can switch
                  to (PlayerMenu.m), and a hold on either side of the
                  cover plays at 2x until the finger lifts (PlayerArtwork.x), an octave higher while Pitch follows
                  speed is on. A Free account gets it too: Spotify's Reinvented Free player mode, whose units none of
                  the hooks reach, declines while the redesign runs, so the track falls to Spotify's other Free mode,
                  built from the units the redesign styles (PlayerFree.x, read from the binary, not yet seen on a Free
                  account). Animated artwork (PlayerMotion.x)
                  runs the clip edge to edge from the top over the color of its last rows drawn on down, with a blur coming in
                  from the seam under the controls and over the whole clip behind the lyrics. The clip and the cover
                  cross over as one comes and the other goes, the clip from its poster frame before the video has
                  decoded one, and the Fluid field under a clip holds still and, once the clip has faded in, is hidden
                  (SGRArtworkField's covered); the menu switches between Animated, Fluid and the Visualizer without
                  a restart. The clip holds its frame while the song is paused, goes while
                  Spotify's music video shows, is given up when it has drawn nothing in 5 s on screen, and on a skip
                  stays a moment for the next track's to cross over it. Under Reduce Motion and in Low Power Mode no
                  clip plays: the cover stays over Fluid. A black layer dims the clip by its brightness (the 75th
                  percentile of the linear luminance of three frames), so white text keeps 4.5:1 (7:1 with Increase
                  Contrast), from 0.10 to 0.80 and 0.15 more behind the lyrics. A track that changes while the player
                  cannot be seen (no window, or the app not in front) takes the last clip away at once. Checked in the simulator against
                  harness/player/ (`motion`). The Visualizer
                  (PlayerVisualiser.m) draws two soft hills of the song's spectrum across the foot of the player, the kick
                  a mound in the middle (the two bands under 80 Hz are left out, and the kick's bands stand at least as
                  tall as the bands beside them, so the middle is never a notch), as light in the cover's flow colors
                  added to the Fluid field held still (plusL, every color at one luminance with its saturation lifted, so
                  a red cover glows warm and a black one is a gray mist, never a silhouette), clear toward the tallest crest so a peak
                  thins out instead of ending in an edge, the front hill brightening on the kick, blurred behind the
                  lyrics: the audio effects'
                  render notify on the music's output hands what it plays, mixed to mono, to one reader (SGAudioSetOutputReader), and
                  SGRSpectrum.m cuts it into 24 bands with Accelerate's FFT on the render thread, without allocating or
                  locking, and publishes them atomically; a display link of at most 60 Hz (30 behind the lyrics, 15
                  with Reduce Motion, where the bands ease over seconds) draws them while the player is on screen,
                  Spotify is in front, the player is not opening or closing and Low Power Mode is off, and stops once
                  a paused song's hills have settled. The spectrum is checked on the Mac against harness/visualiser/,
                  the view in the simulator against harness/player/ (`visualiser`)
    Lyrics/       the full screen lyrics page on glass with Apple Music style lyrics over it, always on (SGRKaraokeView,
                  which the player shows in itself too, Player/PlayerLyrics.x, where with Hide the controls on
                  everything else -- the header row, the thumbnail, the title row and the controls -- fades a few
                  seconds after the last touch and the lines take the whole safe area until a tap): lines sung over each other lit together,
                  the stack moving on once the first is sung out; an instrumental break of 7 s or more held by three dots
                  that breathe and fill over its length on a Core Animation timeline laid against the song's clock; and
                  a line's pronunciation (under the words it spells) and translation, switched on from a glass button in
                  the lyrics' corner that shows only for a song that has them, in the order of sizes the Lyrics page sets
                  (LyricsText.h). With the Lyrics page's Romanized lyrics on, a line in another alphabet has the same
                  again in Latin letters right under its words (the source's own pronunciation where it is hidden, none
                  where it shows), before the translation, at the pronunciation's size, lit with its line but never swept.
                  A word held 0.9 s or more glows and its letters rise in a wave as the sweep reaches
                  them. The size, the room between lines, the blur, the glow and the wave are the Lyrics page's look
                  (LyricsLook.h): five presets and a sheet of sliders, applied at once to every view, under a live
                  preview of the view playing a song of its own (LyricsLookSettings.m). Laid out on the Mac against
                  harness/lyrics/; the page against harness/lyrics-page/
    Home/         Home decluttered to music on black (an allow list of its sections: shortcuts, the DJ without its heading and
                  transcript, the shelves of cards, each with a switch on the Home page of Mod Settings; the previews and the
                  song suggestions only when switched on), a large title where the filter pills were, the title rising and
                  fading with the feed as it scrolls, as the Music app's does, the shelves' headings at the Music app's size,
                  continuous corners on the covers, and, under the Home look switch (the Home page's first row; off, none of
                  its hooks install and Home is as before it): at the trailing edge a glass pill of the filter (a menu that
                  drives Spotify's own chips, with the device picker and the top shelf's Show all) and the avatar, Top picks
                  (the first shelf, or the one Cards from names, found in Spotify's feed model before its cells are built, moved above the shortcuts and drawn as large cards in their
                  covers' colors with no heading, the page tinted by the first card) and each shortcut tile as a glass pill
                  in its cover's color with its name in bold on up to two lines; in FLEX builds a meter of each scroll's
                  frames and the hooks' time (Home.h lists its files)
    Search/       the Browse page decluttered to its category cards (an allow list of the list's cells: the watch feed
                  carousels and promos collapse, and the cards move up by the spacing they leave), the header the way Home
                  has it without the camera, and each card as Liquid Glass tinted by its own color, read off the Box's
                  shape layer (Search.h lists its files)
    Library/      Your Library the way Home and Search have their headers: a large title at the leading edge, the avatar
                  at the trailing edge with the search and create buttons before it, the header's scrim gone, each row's
                  artwork at the Kit's radius with a circular one left round, a hairline between the rows, and the search
                  inside the library on glass capsules (Library.h lists its files). The filter chips under the row stay
                  Spotify's: they were taken out when this was first built and put back in 0.21 (issue #20), since
                  sorting a library is not something the page can do without, and Spotify already draws them on the
                  system's own glass
    Playlist/     the playlist page (Liked Songs and one's own too, all three being the same page) the way the Music
                  app lays one out: the cover full bleed across the top dissolving into the page's field with no seam,
                  the title, the creator and the length centered under it, one row of glass controls (shuffle, a
                  prominent Play capsule taking its glyph and its word from Spotify's own button, add), the find bar
                  and the curation pills gone, and the track rows on the field with a hairline between them
                  (Playlist.h lists its files). Sort and Mix, the two of those pills the ⋯ menu does not already offer,
                  are put on that menu's own sheet instead, above Spotify's rows, and fire Spotify's own buttons.
                  The page of the songs the user liked by one artist (CollectionArtist) is Liked Songs' header kit
                  with no cover and goes through the same files: the neutral field, the wash and the bar's scrim
                  gone, the one row of shuffle, Play and download, and its rows as the playlist's are. Its pinned ⋯
                  opens the system menu, as every other redesigned page's does. Its download button is the plain one, not the Granular one, so its state is read from its
                  owner's `currentStatus`, whose cases are its own (none, waiting, downloading, downloaded); it keeps no
                  progress while it downloads, so the ring turns (Kit/SGRDownload.m).
                  Laid out on the Mac against harness/playlist/
    Album/        the album page laid out the same way, on the page the Creative Work Platform builds rather than the
                  playlist's, so it shares nothing with Playlist/ but the Kit: the cover full bleed dissolving into the
                  field (Apple Music's animated cover over it where the album has one, fading in once its first frame
                  is decoded and moving only in front of the app with Reduce Motion and Low Power Mode off and Auto-Play
                  Video Previews on), the title, the artist and the kind and date centered under it, and the same row of glass
                  controls -- play and shuffle float over the album page outside its header, so they are concealed
                  there and the row carries the Kit's stand-ins, which draw their glyph and fire them. A track's artist line
                  goes where it only repeats the album's artist (with the guests the title names after "feat." and the
                  like), its explicit badge drawn after the title instead (AlbumCredits.m decides, checked on the Mac
                  by harness/album-credits/; a switch on the Albums page). Under the tracks
                  everything the server sends is dropped -- more by the artist, videos, concerts, merch, you might also
                  like, and whatever it adds next -- but the album's own line and its copyright, each section back
                  once its switch on the Albums page is off (told apart by its English heading; in another
                  language Everything else covers them all; Album.h lists its files). A podcast's episode page is the same template, so it is given the same field, and what it
                  paints over it is taken off. Laid out on the Mac against harness/album/
    Artist/       the artist page on the same field and header (Artist.h lists its files), its Music / Video / Merch
                  strip and the videos in its Music list kept unless switched off (each off until switched on) and,
                  likewise off until switched on, the Artist pick, the Release Countdown and About
                  (spotifyglass.redesign.artist.hide.pick, .countdown, .about). Each is told apart by the identifier
                  its content carries in any language (Components.UI.PinnedItemUI, Components.UI.UpcomingReleaseRow,
                  Components.UI.CreatorBiographyCard; strings of the 9.1.78 and 9.1.90 binaries) and dropped with its
                  heading and spacer (ArtistSections.x). Laid out on the simulator against harness/artist/, whose
                  recorded artist has no countdown

App:

    ModSettings.x  the root page and the rows that open it from Spotify's settings and the side drawer
    Pages.m        Redesigned UI's switch, the Appearance, Vibrations, Player and Lyrics pages, which Tab bar page opens
    About/         the update check against the repo's GitHub Releases, the Updates page it fills (the state, and
                   the changelog of every release newer than the build, a line per commit), betas counted only
                   while Mod > Include betas is on (unset, on for a beta build), and the sheet a newer
                   release brings up on its own a few seconds after Spotify opens, once per release; backup, the
                   signing warning, the date the provisioning profile runs out (on the Mod page, and at the top of
                   Mod Settings for a free Apple ID's week) and the Mod page with the reset
    Onboarding/    the welcome page over Home on the first launch, opening on the logo in glass, with Redesigned UI and
                   a No ads switch that sets Hide ads, Hide upsells and Spoof Premium together (off leaves each as it is;
                   on, like a changed look, ends the tour in a restart, as all are read at launch), and under "Easy to miss"
                   a card of pointers, each what it is and where in Mod Settings: Split Tabs (with the redesign picked),
                   Lyrics (sources, lyrics for every track, the redesign's live preview with it picked) and AirPods
                   gestures with the Live Activity (iOS 17 on);
                   on the first launch of a new version instead, What's new (WhatsNew.m), this version's section of
                   CHANGELOG.md, which scripts/whats-new.sh writes into a gitignored header at each make (a section
                   that came over from upstream is left out, so a build without its own has no sheet). The Mod
                   page offers both again. Environment.m says once per install state, a few seconds in, when
                   EeveeSpotify is injected too (a dyld image named so, or its settings page's Swift class) or Spotify is not the version the mod is
                   supports (SGSpotifySupportedVersions in Onboarding.h: 9.1.78, which it is made for, 9.1.88 and 9.1.90) or likely works on (SGSpotifyLikelyWorksVersions, empty now), and when a redesign below iOS 26 did not start, and when the install lacks the app
                   changes the IPA build makes, as with a .deb injected by hand: Spotify's own glass opt-out set (9.1.88's
                   UIDesignRequiresCompatibility, under the redesign), or NSSupportsLiveActivities or MusicHapticsSupported
                   missing, each named in the warning and the last two under Live Activity and Vibrations too; all but
                   the third stay as red rows at the top of Mod Settings. What Chroma left in Spotify's storage when Vitrine
                   replaced it (its Karaoke model and saved lock screen videos, never its listening history or audio
                   effects) is offered for deleting once, and stays a row there until it goes. Laid out on the simulator by harness/onboarding/

Every key a feature stores starts with `spotifyglass.`, whatever it holds: Reset all settings on
the Mod page removes by that prefix and has no list to keep up to date. It leaves `SGKeyStock` behind,
which makes every unset switch read off, so a reset is stock Spotify whatever switches exist. The API keys
(each AI translator's, the OpenAI-compatible server, Spicy Lyrics') live in the Keychain, which a reset leaves
alone; Clear Keychain beside it deletes each by its own service and keeps the settings.

A hook reads its switch when it runs (`SGEnabled`, `SGHidden`, `SGFlag` from Core/SGPrefs.h), so a
change shows after Spotify restarts; the tab editor on the Navbar page is the exception and applies as soon as the bar lays
out again, as are the Home gradient's color, strength and height, but not the switch that turns it on, and Vibrations
and Live Activity. The root page in `App/ModSettings.x` links the Appearance page and the page of each part of Spotify, and only the stored look's.

## Lossless

Off unless `spotifyglass.lossless` is set; there is no settings row yet. A FLAC or ALAC file in Spotify's
Documents/Lossless folder (Files app › Spotify › Lossless) plays in place of Spotify's sound for the same recording.

- **Which file:** the folder's index (`.index.plist`, track URI to file name), else a file whose title tag (or
  name) is the track's title and whose length is within 2 s. Artists are not compared. A file goes in the index
  once its sound matched (`SGLosslessStore.m`).
- **Where in the file:** at each track start, seek and resume, 4 s of Spotify's output are matched against the
  file near Spotify's position: first on a mono copy at 1/16 of the rate, then exactly on a full-rate window. A
  normalized correlation under 0.8 is another recording or master, and Spotify's sound stays. The file plays
  from that frame at the gain that matches Spotify's loudness (`SGLosslessEngine.m`).
- **Playback:** a static 2^19-frame ring that a worker thread fills ahead of where Spotify plays. A block the
  ring does not hold yet keeps Spotify's sound. The swap is in Shared/Player's source selector, before Sing.
- **Data:** Spotify still downloads and decodes its own copy, and it downloads a song as it starts. So while
  the next song in its queue has a file, Spotify's quality is set to low, and the user's value comes back
  afterwards, also at the next launch (`LosslessQuality.x`).
- **Not yet:** Karaoke and speeds other than 1 keep Spotify's sound; the first 4 s after each start, seek or
  resume are Spotify's; a silent block drops the anchor until the next try. Sources that download files are a
  design only: [Lossless sources](lossless-sources.md), [addons](lossless-addons.md),
  [playback investigation](lossless-playback.md), [prototype history](lossless-prototype.md).

## Make targets

    make build      # out/vitrine-<version>.ipa with FLEX in it
    make release    # the same without FLEX
    make install    # build without FLEX, sign with your certificate, install over USB or Wi-Fi
    make install FLEX=1   # the same with FLEX, which is what make trees reads through
    make quick      # rebuild only the tweak into the app the last make install made, sign, install (seconds)
    make trees      # record view trees screen by screen (FLEX build open on the phone, USB)
    make session    # clean trees, as many snapshots per screen as you like: Enter saves, n goes to the next screen
                    # (SCREENS="playlist artist" for some); every snapshot says whether the mod was at stock
    make log        # stream [spotifyglass] log lines from the phone
    make flags      # regenerate the flag table from the IPA

## Diagnostics

A build with FLEX in it (`make build`, `make install FLEX=1`) runs `Diagnostics/`: the tree server, the hang
sampler, and the phone driver, which lets an agent on the Mac work the app without anyone touching the phone.
The server listens on the phone's loopback only, 127.0.0.1:8085, which the Mac reaches through iproxy over
USB and nothing on Wi-Fi reaches. `GET /tree` answers with the visible screen's view tree, as `make trees`
records it. The driver adds `GET /<command>?<params>`, each answering JSON with `ok` and either what happened
or an `error`. A command needs an `X-Phone-Driver` header, which a web page on the phone cannot send to the
loopback without a CORS preflight the server never grants (`curl -H 'X-Phone-Driver: 1'`). It is compiled only with `SG_DRIVER=1`, which `scripts/pipeline.sh` sets for the builds that
carry FLEX; `make release` and the release workflow's build leave it out, and it starts only when FLEX is
there.

`scripts/phone.py` is the client. It uses whatever already answers on 127.0.0.1:8085 or starts iproxy and
leaves it running:

    scripts/phone.py tree | state | log [--since N]
    scripts/phone.py find --class UILabel
    scripts/phone.py tap --id X | --label X | --text X | --class C [--index N] | --at X,Y
    scripts/phone.py longpress --id X [--duration 1]
    scripts/phone.py swipe --from X,Y --to X,Y [--duration 0.2] [--drag 1]
    scripts/phone.py scroll [--id X] --by 0,400
    scripts/phone.py type "text"
    scripts/phone.py player.open | player.close | player.more | play | pause | next | seek 42
    scripts/phone.py menu.pick "Sleep timer"
    scripts/phone.py tab 0 | tab Search
    scripts/phone.py settings.open | settings.page "Appearance"
    scripts/phone.py wait --id X [--gone 1] | --menu 1 | --log "system menu: the player's menu is up" [--timeout 3]
    scripts/phone.py screenshot out.png

Views are addressed as the tree prints them: `id=` is the accessibility identifier, `a11y=` the accessibility
label, the quoted text a label's, and a class with an index counts that class's views in the tree's order.
Points are screen points, the frames `find` prints. Touches are made as a finger's (`harness/tabbar/touch.m`'s
way: a UITouch and the IOHIDEvent gesture recognizers read, through `-[UIApplication sendEvent:]`), so
controls get their control events, recognizers recognize, and a button whose menu is its primary action opens
it on the touch down. `menu.pick` taps a row of the system's menu, not of Spotify's own sheet (tap that by
`--text`). `log` reads the app's last 2000 `SGLog` lines from memory, so no device log capture is needed;
a log wait looks from the start of the last command that did something. Everything runs on the main thread
through `dispatch_async` and a semaphore with a timeout, waited on from the server's thread only. Checked in
the simulator by harness/driver/.

## Mod Settings

Mod Settings, opened by holding Home on the tab bar or from the first row of the side drawer and the
last row of Spotify's Settings, looks like the system Settings app in its dark appearance under either look:
cards of #1C1C1E on black, 17pt rows that follow Dynamic Type up to xxxLarge and the app font, each part of
Spotify behind a symbol on a tile of its own color, gray chevrons and footnote headers. It has no account
page. It sorts every
setting by the part of Spotify it changes, so a part's glass, its hide switches and its flags sit on
one page, the mod's own rows first and Spotify's flags below them or on a sub page named after what
they change. Its main page groups the rows by what they are, in cards with no headings as Settings has its own,
under the signing and environment warnings: Redesigned UI, Appearance and Tab bar, with a restart note; Home (Home &
Library in the native look), Player, Lyrics, Albums and Artists; Karaoke, Spatial voice (where the iPhone reads headphone
motion), Audio effects, AutoMix, Live Activity, AirPods gestures and Listening stats; Lock screen, Vibrations and Premium, ads &
privacy; Labs and All flags; Mod. It is checked in the simulator
against harness/mod-settings/. The Appearance page has, in the native look, AMOLED (the redesign is always black), then the stored look's Accent color
preset, a pull-down of Spotify, Apple Music and Custom read off the color stored (a color set before the presets
existed reads as Custom, Apple Music's red as Apple Music), and Accent color, the hex and a swatch of the color in
effect, which opens the system picker in a sheet that stores only from its checkmark, as Custom. The custom color is
kept aside while a preset is in place, so Custom brings it back. Last come the Font, under either look and on any
iOS, below 26 too, a page of its own with each choice drawn in itself: Default (Spotify's), San Francisco, SF
Rounded, New York and SF Mono; More fonts, the families iOS carries of a fixed few (Avenir Next to American
Typewriter), each weight taken as the family's nearest face; and Your fonts, the files of one family (.ttf, .otf, .ttc or .otc, picked
together) added from Files, refused when their faces name more than one family, copied to Application Support/Vitrine/Font
and registered again at each launch, each weight taken as the family's nearest face, Spotify's font coming back when
the files are gone. Swiping the row deletes the family. An import from before families (one file under
spotifyglass.font.file) moves to spotifyglass.font.files and the family name on first use. Then the App icon. Everything on the page applies after a restart. Redesigned UI, the main page's
first row, is the one switch between the two looks (see Layers): it glows (Settings/SGGlowSwitch), its ⓘ says what
it changes, and flipping it offers to restart Spotify. The pages show only what the stored look has: a page opened
after flipping the switch already shows what the restart will bring, and the main page swaps Home & Library for
Albums and Artists as it is flipped. Tab bar: the tab editor of the stored look, each with
its own list of tabs. Lyrics, on the main page of its own: in the redesign a live preview of the lyrics first, with the presets of their look
under it and their sliders in a sheet (Text size, Line spacing, Blur, Glow, Wave), applying at once; then Karaoke, then the ordered list of lyrics sources,
lyrics for every track, naming the source in the redesign, the lock screen, and glass lyrics in the native look; in
the redesign also which of the lyrics, their pronunciation and their translation is set largest, Romanized lyrics
(applied at once), and the translation's language. Karaoke, under either look, on the main page and as Lyrics' first row, the row reading out On,
Off or how far the voice model's download has come, kept up to date while the page shows: Karaoke's switch, which turns
the mic on and off at once, a card at its top (SGSingCard.m: the song, what Karaoke is doing, a tap saying more, the vocals
and the rest traced live from the engine's loudness, Karaoke running on the playing song while they show even at As sung, still under Reduce Motion, play and pause, and a tall Vocals slider
from gone through as sung to the vocals alone, with Sing along, Original and Vocals only under it), Spatial voice
(where the iPhone reads headphone motion; a page of its own, reading out On or Off, with a live preview at its top that
follows the head through AirPods, or sways gently without them and holds still under Reduce Motion, a line under it
saying which, then the switch; its row is on the main page too, under Karaoke's), a Voice model section (Best quality
and Light, a checkmark against the chosen one, each with its size; then the chosen model's download, Paused and Checking
among its states, and its removal; and Remove the other model, with its size, while the one not chosen, or the old
model with the full one, is on the iPhone), Toggle from lyrics (the redesign's mic, on until switched off, issue #12),
Ignore heat warnings, and under Advanced Runs on (Automatic: the Neural Engine
beside the CPU; CPU only) and Prepare after updates, all applying straight away. Lock screen, on the main
page under either look, opens the lock screen widget's page, titled Lock screen: Widget (the line in place of the artist,
and Spotify's like and dislike buttons' flag, locked off while the star is on) then Artwork (Off, Moving artwork, Lyrics,
Every song or Moving artwork with lyrics, the lyrics' style, Still or Animated, Switch with the star, the sources and Low Data Mode; below iOS 26
one row saying why not). Spotify's podcast, audiobook and artwork flags stay in All flags. Player: Gestures and Blocked artists (with the count on the row), which work with either look;
in the native look also Now playing bar (its device button and its flags), Queue & devices, and
Spotify's own player screen (artwork background, glass header buttons, Disable Canvas and the sheet,
header, slider and sticky header flags, the cards under the player and the lyrics preview and player
buttons to hide); in the redesign the page instead leads with a card of the player (Redesigned/Player/
PlayerSettings.m): the background chosen edge to edge, and over its foot the cover, title, artist and progress;
for Animated while the player has no clip, the card looks the playing track's up itself while it is on screen
(SGMotionClipFor, the player's sources, size and Low Data Mode, into the store the player reads), Fluid until it
is in, then the clip over it, poster first (harness/player/ `preview`);
under it a segmented control of the five backgrounds (Still, Colors, Fluid, Animated, Visualizer, changing the card at once)
with a note on what the one picked does, Artwork sources and Download in Low Data Mode while Animated is chosen,
while Fluid is chosen its five sliders and a red Reset (Redesigned/Kit/SGRFluid.h, spotifyglass.redesign.fluid.*):
Speed (25-300 %, how fast the four blurred copies turn, picked up from the angle each is at), Warp (0-100 %, how
far from the middle they turn and how much the upper three show; at none one copy turns alone), Blur (2-24, the
radius at 1.25 px a step on the 128 px cover), Saturation (0-250 %) and Brightness (40-150 %, a gain on linear
light that the luminance ceiling for the player's text, 0.07 or 0.04 with Increase Contrast, still caps); the
card and the player follow each step at once through SGRFluidSettingsDidChangeNotification, the last three by
blurring the cover again off the main thread, and Animated and Visualizer's Fluid with them,
and Mini player: Apple Music style (the tab bar's minimize on scroll), Device button (the now playing bar keeps
Spotify's device button in that minimized row, off by default), the device button hidden on the full bar, and the
like button hidden (Spotify's own flag ios-feature-nowplayingbar.add_button forced off),
checked in the simulator against harness/player/ (`settings`). Vibrations, a page of its own under either
look opened from the main page (the row reads out which of the two are on), leads with a preview (Shared/Haptics/SGVibrationsPreview.m): rings of dots that a tap sends a crest across, out
from the middle in the accent color, higher and further the stronger the Strength, while the first of Controls and
Music Haptics that is on plays its own tap through its own path (Controls' add tap, or one kick of Music Haptics'
with its rumble unless it follows Beat), the line under it naming which, or saying why there is none. While the page
shows, each tap Music Haptics plays sends a low crest too. Nothing runs between crests, and with Reduce Motion the
rings light up together and fade instead of moving. Under it a card for
Controls (on until switched off) and one for Music Haptics, which holds two switches, both off until switched on,
each with an ⓘ: Music Haptics, the mod's own from the sound while Spotify is in front, and In the Background
(left out below iOS 18), the song named to iOS's own Music Haptics. The one choice of before moves to them once
(Generated to Music Haptics, Native iOS to In the Background, None to neither). Controls
has its Strength under it, grayed out while the switch is off (10 to 100%, a tap at the new strength with each step);
Music Haptics its Strength (20 to 200%, 100% being how it first shipped, a kick at the new strength with each step) and
Follows, grayed out the same way, Everything (a tap on each kick and snare and a rumble under the bass), Beat (the
taps without the rumble) or Bass (the kicks' taps and the rumble); In the Background a Status row (Paused, Waiting,
Checking, "Sent, iOS not playing yet", Playing or Unavailable) while it is on, or, while Music Haptics is off in Settings > Accessibility, a
row saying so whose tap opens its ⓘ, all applying straight away. Live Activity, on iOS 17 and up under either look: its switch and which view it
shows, Lyrics, Queue or Control menu, and for Lyrics its Without lyrics (Note or Track), Alignment (Center, or Left),
Translations (off until switched on) and Text size (Small, Medium or Large); then for every view a Card section of
Artwork and Progress bar (both on until switched off) and Colors (Spotify, Artwork or Plain), with a note that the
card shows on a paired Apple Watch and in CarPlay too, all applying straight away, the row reading out the view or
Off. At its top a preview, a slice of the lock screen with a mock of the card with a made-up song, follows the
options as they change and steps every 3 s through the picked view, the lines being sung or the menu's tabs, with
a crossfade; under Reduce Motion it rests and a tap moves it on, and it stops while the page is off screen. Audio effects, in either look (Shared/AudioEffects/AudioEffectsPage.m):
the effects' switch with what the engine is doing under it, Presets (built-in ones and your own, saved, loaded
and deleted there) and Headphones (AutoEq's corrections, searched and applied to the Graphic EQ, with Use for <the
output playing now> keeping the pick for that output and the remembered outputs listed, a swipe removing one), either of which
turns the effects on, then a card per effect, each opening out into its sliders, choices, curve or file library
while its switch is on (Reverb has its Room and its Amount, the amount the player's ⋯ menu also sets), everything
applying as it changes; the row reads out Off, On or how many effects are on. Home & Library, in the native look only:
the Gradient page (the wash behind the top of Home in one of eight colors, at three strengths and
four heights) and the Home flags, the parts of Home to hide including the DJ button and badge, the
playlist header, buttons and pills to hide, and the Library flags. Then Premium, ads & privacy
(EeveeSpotify's Hide ads and Hide upsells, in the native look hiding the video carousel in Search, and
an Ad and upsell flags page under them, every switch there forcing a flag Spotify ships on to off;
Spoof Premium; Block telemetry; Clean shared links; then what the ad
blocking and the telemetry blocking have stopped) and Labs (features Spotify built and did not ship,
AI Chat (Martini) first). Last, All flags, Spotify's remote-config flags with a search field and an
Auto / Off / On control per flag (a text field for the number and text ones), and Mod: Updates
(the row reads out where the build stands and opens the changelog of everything newer than it, read
from the releases Release Please cuts, with Check now, the release to get, all the releases and Tell
me when one is out, the sheet a newer release brings up a few seconds after Spotify opens), the
build and Spotify's version, the site and the repo, What's New and the welcome tour again, Clear Keychain and Reset all
settings. A flag switch on a page forces that one flag and off leaves Spotify's own value, so the All
flags page is where a flag goes back to Auto. Spotify ships its newer design behind several flags at
once, and the redesign is built on it (the glass navigation bar, the new player slider, the sheet style
player, the queue and Connect sheets, the redesigned player header, the sleep timer's options sheet):
while Redesigned UI is on each is forced, over an override too, and their rows elsewhere show what is
forced and take no touch. `Redesigned/Kit/SGRGlassDesign.x` holds the list; what else forces a flag
registers in `Core/SGFlagForce.h`. A change shows after Spotify restarts. Spotify reads most flags
only when their feature first needs them, so 15 s after launch the log says how many stored overrides
it has asked for and which not yet (`flags: N overrides stored, …`), and an override asked for later
gets its own line as it is asked (`flags: Spotify asked for <flag> only now, …`).

The tab editor on the Tab bar page is the exception and applies as soon as the bar lays out again. It lists the tabs in the order
the bar shows them: drag to reorder, tap to hide or show, and Add a tab puts a page of Spotify's or
any `spotify:` link on the bar. It is a sheet: a name, a link picked from Spotify's pages or pasted (one
Spotify's router cannot open is refused there), and an icon picked from Encore's glyphs or the SF Symbols,
searchable. Split tabs sets chosen tabs apart at the right end of the bar: after a gap in the native look,
on a glass bar of their own in the redesign, like Search in the Music app. Spotify's own tabs are kept by the
name under their icon, so they can be hidden but never removed, and switching the app's language
starts the order over. A tab of the mod's own opens its link through Spotify's link dispatcher. In the native
look it never lights up as the tab you are on; on the redesign's glass bar it does while the page it opened is
up, and a second tap goes back to that page. In the redesign (Redesigned/Navbar/NavbarSettings.m) the page leads
with a preview of the glass bar, drawn by the same system UITabBar as the bar itself from the list as it
stands, the split tabs on a bar of their own, and changing with every change on the page; then Custom tab
bar (off, the bar is Spotify's own tabs in Spotify's order, the list kept); two picture cards for the labels,
Icons and names or Icons only (the glass bar's names hidden, applying straight away); the tabs, each with a
check circle that shows or hides it, its glyph (TabBar.x draws Spotify's own off their items on the bar) and
the drag handle, a tap on a tab of the mod's own opening the Add a Tab sheet as Edit Tab, with Save and Remove
Tab; Add a tab and Use Spotify's tabs; and Split tabs. Spotify's own tabs keep their names and icons. Checked
in the simulator against harness/addtab/ (`navbar`, `icons`, `off`, `hide`, `edit`, `remove`, `links`).

## Adding a feature

1. `make trees`, record the screen, read `trees/<screen>.txt` for the classes and frames.
2. Decide the layer (see Layers), then make `tweak/Sources/<Layer>/<Feature>/` with `<Feature>.h` declaring the switch key
   (`#define SGKey<Feature> @"spotifyglass.<feature>"`) and `UIViewController *SG<Feature>SettingsPage(void)`.
3. Add the hooks in `<Screen>.x`: `#import "Core/SGCore.h"` and the feature header, guard on the
   switch, use `SGGlassFor`/`SGGlassAt` + `SGShapeGlass` for glass and `SGStripBackgrounds` to clear
   Spotify's paint, and end with `%ctor { %init; SGRequireClasses(@[...]); }`, gated first on the layer's look
   (`SGNativeUI()` or `SGRedesignedUI()`) in Native/ and Redesigned/.
4. Add `<Feature>Settings.m` returning an `SGModPage` of `SGSection`s of `SGSwitchRow`/`SGHideRow`/
   `SGFlagRow`/`SGChoiceRow`/`SGSliderRow` (Settings/SGModPage.h), and put it on the page of the part of
   Spotify it changes in `App/Pages.m` or `App/ModSettings.x`.
5. `make install`. Log lines are prefixed `[spotifyglass]`. A FLEX build serves the visible screen's
   tree on the phone's port 8085, which `make trees` reaches over USB through iproxy.

A class Spotify has renamed shows up in the log as `class X not found, its hooks are inactive`;
declare the classes a feature needs in `Headers/` only when a hook calls into them by type.
