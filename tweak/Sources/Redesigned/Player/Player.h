// The player redesign (screen key "player"): Spotify's full screen player kept, with its controller,
// units, controls and card list, and restyled from the Kit. Every control stays Spotify's own, so its
// action, state and accessibility do too; the redesign adds the artwork field behind it, glass behind
// the header buttons, bare glyphs for previous, play and next, a lyrics glyph in the footer, and one
// screen with nothing under it: every card is collapsed and the player does not scroll. The lyrics
// come to the player itself, the way the Music app shows them, when the lyrics glyph is tapped.
//
//     PlayerField.x      the switch's flags and rows, the field in the background plane, the cover it reads
//     PlayerArtwork.x    the cover's corners, shadow and paused shrink; the lyric preview as Spotify's setting has it
//     PlayerHeader.x     glass behind the close and more buttons
//     PlayerControls.x   previous, play and next as bare glyphs, monospaced times
//     PlayerFooter.x     share gone, lyrics, Connect and queue as one row of three glyphs
//     DJPlayer.x         the AI DJ's player (its own units): skip glyphs, a four glyph footer row, over the shared
//                        play glyph, lowered row and Connect of PlayerControls.x and PlayerFooter.x
//     PlayerCards.x      every card under the player collapsed, so the list closes up
//     PlayerScroll.x     the list held at its top, so the player is one screen and cannot be scrolled up,
//                        and its pull held off while the progress bar is scrubbed
//     PlayerLyrics.x     the lyrics in the player: the cover as a thumbnail, the title up beside it
//     PlayerGestures.x   the gestures' hookup
//     PlayerMorph.x      the open and close grown out of the now playing bar's card, the cover flown
//     PlayerMotion.x     Animated artwork: the Canvas or Apple Music's animated cover behind the player
//     PlayerVisualiser.m the Visualizer background: a calm spectrum of the song in the cover's colors, read
//                        through SGRSpectrum.m from the audio effects' tap on Spotify's output
//     PlayerMenu.m       the more button's system menu: Share, Add to playlist and Add to queue on top, then
//                        speed, pitch and reverb, the backgrounds it can switch to, and Spotify's other rows
//                        under More (Redesigned/ContextMenu)
//     PlayerSettings.m   the Player page in Mod Settings, led by a showcase of the player
//     PlayerFree.x       a Spotify Free account given the player mode these units belong to
//
// Speed and pitch, once the redesign's own, are Shared/Player/SpeedPitch.h's; PlayerHeader.x still hands
// the more button over, so a menu opened from it is taken for the player's, and hands it to PlayerMenu.m,
// which opens it as the system menu.
//
// Every hook installs only while Redesigned UI is on (SGRedesignedUI); the native look's do not then.
// Threading: main thread only.
#import <UIKit/UIKit.h>

@class SGRArtworkField;

// What is behind the player, chosen on the Player page (PlayerSettings.m).
// SGRKeyPlayerMotion is the switch the choice replaced: until a choice is stored, it picks Still or Colors.
#define SGRKeyPlayerBackground @"spotifyglass.redesign.player.background"
#define SGRKeyPlayerMotion @"spotifyglass.redesign.player.movingBackground"
typedef NS_ENUM(NSInteger, SGRPlayerBackgroundKind) {
    SGRPlayerBackgroundStill,      // the artwork blurred and held still
    SGRPlayerBackgroundColours,    // the artwork's colors drifting (SGRFlow.h)
    SGRPlayerBackgroundFluid,      // the artwork itself blurred and turning (SGRFluid.h)
    SGRPlayerBackgroundAnimated,   // the track's Canvas or Apple Music's animated cover, over Fluid (PlayerMotion.x)
    SGRPlayerBackgroundVisualiser, // a spectrum of the song over Fluid held still (PlayerVisualiser.m)
};
// The player's ⋯ menu switches between the last three, which share the Fluid field, without a restart.
SGRPlayerBackgroundKind SGRPlayerBackground(void);
// The names of the choices, in order.
NSArray<NSString *> *SGRPlayerBackgroundNames(void);

// The field behind the player, nil until the player has laid out once (PlayerField.x).
SGRArtworkField *SGRPlayerField(void);
// Holds the field still, or lets it move, for what is over it now: a paused song, an Animated artwork clip, the
// Visualizer (PlayerField.x).
void SGRPlayerHoldField(void);

#pragma mark - the cover (PlayerArtwork.x)

// The sideways list of covers behind the player, nil until one has laid out.
UIView *SGRPlayerCoverList(void);
// The cover on screen as it is drawn, its paused shrink included, in `host`'s coordinates; CGRectNull
// when no cover has laid out.
CGRect SGRPlayerCoverFrameIn(UIView *host);
// The scale the cover is drawn at: 1 while playing, its shrink while paused, so a stand-in can draw its
// corners the size the cover's are.
CGFloat SGRPlayerCoverScale(void);
// The band that cover sits in -- the room the player gives its artwork, between the header row and the
// title -- in `host`'s coordinates; CGRectNull when no cover has laid out.
CGRect SGRPlayerArtworkAreaIn(UIView *host);
// Hides the cover on screen and its shadow, or shows them again, for a stand-in to fly in its place
// (PlayerMorph.x).
void SGRPlayerSetCoverHidden(BOOL hidden);

#pragma mark - the lyrics in the player (PlayerLyrics.x)

// Whether the playing track has lyrics the player can show.
BOOL SGRPlayerLyricsAvailable(void);
// Whether the playing track has none: its grace is over and nothing is looking for them any more.
BOOL SGRPlayerLyricsNone(void);
// Whether the player is showing them.
BOOL SGRPlayerLyricsOpen(void);
// Shows them, or puts the cover back; does nothing when there are none to show.
void SGRPlayerToggleLyrics(void);
// Called by PlayerLyrics.x whenever either of those two changed, so the footer's lyrics glyph follows
// (PlayerFooter.x). It returns at once when nothing changed.
void SGRPlayerLyricsChanged(void);
// The lyrics glyph of the footer, made on first ask in `host` and kept there; the ordinary player's footer
// (PlayerFooter.x) and the AI DJ's (DJPlayer.x) share it. Only the one asked for last is followed by
// SGRPlayerLyricsChanged, which is the footer on screen: each layout of a footer asks again.
@class SGRGlyphButton;
SGRGlyphButton *SGRPlayerLyricsGlyphIn(UIView *host);
// An Endless_DJMusicImpl class of the AI DJ's player by its Swift name, under the mangled spelling or the
// dotted one the trees print; nil when the app has neither.
static inline Class SGRDJClass(NSString *name) {
    NSString *module = @"Endless_DJMusicImpl";
    NSString *mangled = [NSString stringWithFormat:@"_TtC%lu%@%lu%@", (unsigned long)module.length, module, (unsigned long)name.length, name];
    return NSClassFromString(mangled) ?: NSClassFromString([NSString stringWithFormat:@"%@.%@", module, name]);
}
// The controls under the lines fade a few seconds after the last touch while the lyrics play, and the
// lines grow down into their room (PlayerLyrics.x). On until switched off; a scroll through the lines
// hides them either way.
#define SGRKeyLyricsAutoHide @"spotifyglass.redesign.lyrics.autoHide"

// A volume slider under the controls (PlayerVolume.m), the system's: this iPhone's, or the Connect device's.
// On until switched off. Placed by the footer's layout, between the controls (`controls`) and the footer row
// (`row`), both arranged in Spotify's bottom stack, `margin` in from each side.
#define SGRKeyPlayerVolume @"spotifyglass.redesign.player.volume"
// Off until switched on: the clip and the full-screen cover are drawn without the dark layer that keeps white text
// readable over a bright one (PlayerMotion.x). The lyrics' own darkening stays.
#define SGRKeyPlayerFullBrightness @"spotifyglass.redesign.player.fullbrightness"
BOOL SGRPlayerVolumeOn(void);
// YES when the row shows; NO when it is off, has no controls to sit under or no room between them and the footer.
BOOL SGRPlayerPlaceVolume(UIView *stack, UIView *controls, UIView *row, CGFloat margin);

// Follow the cover (PlayerCoverAccent.x): the player's lit controls painted in the cover's color instead of the accent.
// Off until switched on, read at launch. The cover's color (a gray one gives the accent back), and a paint of Spotify's
// bottom stack, which the footer's layout asks for.
#define SGRKeyPlayerFollowsCover @"spotifyglass.redesign.player.followsCover"
BOOL SGRPlayerFollowsCover(void);
void SGRPlayerSetCoverAccent(UIColor *cover);
void SGRPlayerPaintCover(UIView *stack);

// The lyrics turn sideways with the phone onto a landscape screen of their own (PlayerLandscape.x). On
// until switched off. Shown or put away by hand for the harness.
#define SGRKeyLyricsLandscape @"spotifyglass.redesign.lyrics.landscape"
void SGRPlayerShowLandscape(BOOL show);
// The clip the portrait player is playing for the track (PlayerMotion.x), nil while it has none or shows a still
// cover; posted, object nil, when that changes, always on the main queue after the change has settled. The
// landscape screen plays the same file in its own view and keeps its own adjustment per file.
extern NSNotificationName const SGRPlayerMotionDidChangeNotification;
NSURL *SGRPlayerMotionClip(void);
// The playing track's lines came in, or turned out to be none: the landscape screen lays out for it.
void SGRPlayerLandscapeLinesChanged(void);

// The animated artwork follows the lyrics: blurred behind them (PlayerMotion.x).
void SGRPlayerMotionLyricsChanged(void);
// The field was laid out (PlayerField.x): the clip goes onto it, and the cover is hidden or shown again.
void SGRPlayerMotionFieldLaidOut(void);
// A cover in the player laid out: hides it while a clip plays.
void SGRPlayerMotionCoverLaidOut(void);
// A clip is playing in place of the cover, which is then hidden: the lyrics' thumbnail and the open's
// flown cover fade where they are rather than flying to or from it.
BOOL SGRPlayerMotionShowing(void);
// A view of its own playing that clip, drawn as the player draws it (its foot, the blur under the controls),
// for the Player page's showcase. It plays only in a window, like the player's. While the player has no clip
// it is the playing track's, which the page looks up itself, by the player's sources and Low Data Mode, into
// the store the player reads too: nil until it is in, and with `arrived` given the lookup starts, and
// `arrived` runs once on the main queue when a call would return it (never when nothing is found, or the
// track changed). Without `arrived` it only answers with a clip already in.
UIView *SGRPlayerMotionPreview(void (^arrived)(void));
// How dark the clip is drawn (a black layer's opacity) for white text over it to keep 4.5:1, or 7:1 with
// `contrast` (Increase Contrast), when `luminance` is the clip's bright end, its 75th percentile of linear
// luminance; between 0.10 and 0.80, 0.15 more while the lyrics are up.
CGFloat SGRPlayerClipDim(CGFloat luminance, BOOL contrast, BOOL lyrics);

#pragma mark - the Visualizer (PlayerVisualiser.m)

// The background is the Visualizer.
BOOL SGRPlayerVisualiserShowing(void);
// Puts the hills on the field or takes them off as the background says, lays them out, and blurs them while the
// lyrics are open. Called on every layout pass of the field (PlayerField.x), when the lyrics come or go
// (PlayerFooter.x), and when the ⋯ menu switches the background (PlayerMotion.x and here); cheap when nothing
// changed.
void SGRPlayerVisualiserUpdate(void);
// A view of its own drawing the same hills, for the Player page's showcase. It moves only in a window.
UIView *SGRPlayerVisualiserPreview(void);
// Switches the background to `kind` from the ⋯ menu, at once: Fluid, Animated or Visualizer, while it is one of
// them (SGPlayerMenuOffersAnimatedArtwork); nothing otherwise.
void SGRPlayerMenuSetBackground(SGRPlayerBackgroundKind kind);

#pragma mark - Mod Settings (PlayerSettings.m)

// The redesign's Player page: a card of the player over the background chosen and the control that picks
// it, the background's rows and the Mini player section under it, then `more`, the sections either look
// shares (App/Pages.m).
UIViewController *SGRPlayerSettingsPage(NSArray *more);

// Alpha 0, no touches, hidden from accessibility, set again on every call: for Spotify's Swift views,
// which SGRSuppress cannot keep (PlayerControls.x).
void SGRPlayerVanish(UIView *view);

// The play glyph over the play button in `host`, a controls unit's view: the ordinary player's
// (PlayerControls.x) and the AI DJ's (DJPlayer.x) share it, with its state, spinner and tap handling.
void SGRPlayerPlayGlyphIn(UIView *host);

// The footer's shared parts (PlayerFooter.x), for the AI DJ's footer (DJPlayer.x). `row` is the footer unit's view:
// moved down over the home indicator with the controls following, the volume row and Follow the cover placed.
void SGRPlayerLowerRow(UIView *row);
// Connect's glyph in `connect`, laid out and with the device name hidden; nil while it has no size yet, and `host`
// then lays out again on the next turn of the run loop. Leave Connect where it is while it is nil.
UIView *SGRPlayerConnectGlyphIn(UIView *host, UIView *connect);
// Connect's touches only in a 44pt square over its glyph: `holder` is the view of the footer that holds Connect, whose
// own view reaches far past the glyph (over Queue and the DJ button once the glyph is moved).
void SGRPlayerCoverConnect(UIView *holder, UIView *glyph);

// The tap to seek around the progress bar (PlayerControls.x), apart for the harness: whether a tap at `point`
// in the duration unit's view seeks, and the share of the song a point on the slider stands for, measured
// over the thumb's travel (NAN while the slider has no width).
BOOL SGRSeekTapLands(UIView *unit, UISlider *slider, CGPoint point);
CGFloat SGRSeekShareAt(UISlider *slider, CGPoint point);

// The more button's menu opens as the system menu with the player's own items (PlayerMenu.m). Called from
// PlayerHeader.x with Spotify's more button on every pass; watching it again changes nothing.
void SGRPlayerMenuWatch(UIView *button);
