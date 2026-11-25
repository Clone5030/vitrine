// AutoMix (Mod Settings > AutoMix), under either look: Spotify's own Automix and Crossfade, which its player core
// does by itself, set from one page. Every write goes through Spotify's preferences object, so Settings >
// Playback reads the same values. The mod keeps only what Spotify has no setting for: the switch, the style to
// apply while it is off, and the settings it found when it was turned on.
//
// Turning the switch off puts Spotify's three settings back as they were when it was turned on. While it is on,
// both pages write the same object, so a change made in Spotify's Playback page counts as AutoMix's and goes too.
//
//     AutoMix.x           Spotify's product state, captured; the switch's writes, through Shared/SpotifyPrefs;
//                         the probe, one log line per track change while the switch is on
//     AutoMixSettings.m   its page
#import <UIKit/UIKit.h>

#define SGKeyAutoMix @"spotifyglass.automix"
// SGAutoMixStyle, applied as the switch goes on and kept while it is off.
#define SGKeyAutoMixStyle @"spotifyglass.automix.style"
// Spotify's [automix, crossfade, crossfade time] from before the switch went on; set only while it is on.
#define SGKeyAutoMixSaved @"spotifyglass.automix.saved"

// Smart blend: with AutoMix on, each pair of songs gets its own blend length (see SmartMix.m). Default on.
#define SGKeyAutoMixSmart @"spotifyglass.automix.smart"
// The "Mixing" pill over the player's timeline while a blend is playing (the redesigned player). Default on.
#define SGKeyAutoMixPill @"spotifyglass.automix.pill"

typedef NS_ENUM(NSInteger, SGAutoMixStyle) { SGAutoMixBeatMatched, SGAutoMixCrossfade };

// Spotify's own playback settings, read and written through its preferences object.
typedef struct {
    BOOL automix;
    BOOL crossfade;
    NSInteger milliseconds;   // the crossfade's length; Spotify's slider moves in whole seconds
} SGTransitionSettings;

// NO until Spotify has read its user's settings, a few seconds into the launch (SGSpotifyPreferences).
BOOL SGTransitionSettingsRead(SGTransitionSettings *settings);
BOOL SGTransitionSettingsWrite(SGTransitionSettings settings);

// The switch's work: saves Spotify's settings and applies the style, or puts them back.
void SGAutoMixApply(BOOL on);
// Main thread, once Spotify's settings are read: SGAutoMixApply for a switch flipped before they were.
void SGAutoMixReconcile(void);
// The style in effect: Spotify's Automix while the switch is on, the stored one while it is off.
SGAutoMixStyle SGAutoMixCurrentStyle(void);
void SGAutoMixSetStyle(SGAutoMixStyle style);
void SGAutoMixSetSeconds(NSInteger seconds);
// YES on a Premium account, or a Free one under Spoof Premium; YES too before the product state is known.
BOOL SGAutoMixAccountAllows(void);

// Posted on the main thread when SGAutoMixMixing() changes.
extern NSNotificationName const SGAutoMixMixingDidChangeNotification;
// YES while the song playing is being blended into the next one by the blend length chosen for the pair.
BOOL SGAutoMixMixing(void);
// Starts the pair planner; called once the switch is on (SGAutoMixApply).
void SGSmartMixStart(void);

UIViewController *SGAutoMixSettingsPage(void);
NSString *SGAutoMixSummary(void);   // On or Off, beside the root page's row
