// AutoMix's side of Spotify: its settings, through the preferences object Shared/SpotifyPrefs captures, its product
// state, captured as Spotify makes it, and the probe.
#import "Core/SGCore.h"
#import "Shared/AdBlock/AdBlock.h"
#import "Shared/Player/PlayerState.h"
#import "Shared/SpotifyPrefs/SpotifyPrefs.h"
#import "AutoMix.h"

@interface SPTCoreProductState : NSObject
- (NSString *)stringForKey:(NSString *)key;
@end

static __weak SPTCoreProductState *sg_productState;

// Made once per session, as the account is known. Its argument is the core's C++ object, not an Objective-C one.
%hook SPTCoreProductState
- (id)initWithCoreProductState:(void *)state {
    id made = %orig;
    sg_productState = made;
    return made;
}
%end

BOOL SGTransitionSettingsRead(SGTransitionSettings *settings) {
    SPTPreferences *preferences = SGSpotifyPreferences();
    if (!preferences) return NO;
    *settings = (SGTransitionSettings){preferences.audioAutomix, preferences.audioCrossfade, preferences.audioCrossfadeTime};
    return YES;
}

BOOL SGTransitionSettingsWrite(SGTransitionSettings settings) {
    SPTPreferences *preferences = SGSpotifyPreferences();
    if (!preferences) return NO;
    // The time first: under Spoof Premium Crossfade.x turns crossfade on or off with it.
    preferences.audioCrossfadeTime = settings.milliseconds;
    preferences.audioCrossfade = settings.crossfade;
    preferences.audioAutomix = settings.automix;
    return YES;
}

static NSString *describe(SGTransitionSettings s) {
    return [NSString stringWithFormat:@"automix %d, crossfade %d, %ld ms", s.automix, s.crossfade, (long)s.milliseconds];
}

#pragma mark - the switch

// Spotify's own default. A stored time of 0 would blend nothing; Spotify's slider never stores one (at 0 it turns
// crossfade off and keeps the time), but another client or an older version might.
static const NSInteger kDefaultMilliseconds = 5000;

// Both styles keep crossfade on: Beat-matched falls back to the blend length on a song with no computed transition.
// Called only once the settings have been read, so the write cannot fail.
static void applyStyle(SGAutoMixStyle style, NSInteger milliseconds) {
    SGTransitionSettings s = {style == SGAutoMixBeatMatched, YES, milliseconds > 0 ? milliseconds : kDefaultMilliseconds};
    SGTransitionSettingsWrite(s);
    SGLog(@"automix: Spotify set to %@", describe(s));
}

static BOOL shouldStartSmartMix(void) {
    return SGFlag(SGKeyAutoMixSmart, NO) || SGFlag(SGKeyAutoMixPill, NO)
        || SGFlag(SGKeyAutoMixProgress, NO) || SGFlag(SGKeyAutoMixStatus, NO);
}

void SGAutoMixApply(BOOL on) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    SGTransitionSettings now;
    if (!SGTransitionSettingsRead(&now)) {
        SGLog(@"automix: Spotify's settings not read yet, applied once they are");
        return;
    }
    NSArray<NSNumber *> *saved = [defaults arrayForKey:SGKeyAutoMixSaved];
    if (on) {
        if (saved.count != 3) {
            [defaults setObject:@[@(now.automix), @(now.crossfade), @(now.milliseconds)] forKey:SGKeyAutoMixSaved];
            SGLog(@"automix: on, Spotify was %@", describe(now));
        }
        applyStyle(SGInt(SGKeyAutoMixStyle, SGAutoMixBeatMatched), now.milliseconds);
        if (shouldStartSmartMix()) SGSmartMixStart();
    } else if (saved.count == 3) {
        SGTransitionSettings before = {saved[0].boolValue, saved[1].boolValue, saved[2].integerValue};
        SGTransitionSettingsWrite(before);
        [defaults removeObjectForKey:SGKeyAutoMixSaved];
        SGLog(@"automix: off, Spotify back to %@", describe(before));
    }
}

// The saved array is there exactly while the switch has taken effect, so a mismatch is a switch flipped before
// Spotify's settings were read. Reapplying an applied switch would undo a change made since in Settings > Playback.
void SGAutoMixReconcile(void) {
    BOOL on = SGFlag(SGKeyAutoMix, NO);
    BOOL applied = [NSUserDefaults.standardUserDefaults arrayForKey:SGKeyAutoMixSaved].count == 3;
    if (on != applied) {
        SGAutoMixApply(on);
    } else if (on) {
        // Spotify's player and preferences are ready now; avoid registering the player observers from a dylib ctor.
        if (shouldStartSmartMix()) SGSmartMixStart();
    }
}

SGAutoMixStyle SGAutoMixCurrentStyle(void) {
    SGTransitionSettings s;
    if (SGFlag(SGKeyAutoMix, NO) && SGTransitionSettingsRead(&s)) return s.automix ? SGAutoMixBeatMatched : SGAutoMixCrossfade;
    return SGInt(SGKeyAutoMixStyle, SGAutoMixBeatMatched);
}

void SGAutoMixSetStyle(SGAutoMixStyle style) {
    SGSetInt(SGKeyAutoMixStyle, style);
    SGTransitionSettings s;
    if (SGFlag(SGKeyAutoMix, NO) && SGTransitionSettingsRead(&s)) applyStyle(style, s.milliseconds);
}

void SGAutoMixSetSeconds(NSInteger seconds) {
    SGTransitionSettings s;
    if (!SGTransitionSettingsRead(&s)) {
        SGLog(@"automix: Spotify's settings not read yet, %ld s not written", (long)seconds);
        return;
    }
    s.milliseconds = seconds * 1000;
    if (SGFlag(SGKeyAutoMix, NO)) s.crossfade = YES;
    SGTransitionSettingsWrite(s);
}

BOOL SGAutoMixAccountAllows(void) {
    if (SGHidden(SGKeyFakePremium)) return YES;
    NSString *type = [sg_productState stringForKey:@"type"];
    return !type || [type isEqualToString:@"premium"];
}

NSString *SGAutoMixSummary(void) {
    return SGFlag(SGKeyAutoMix, NO) ? @"On" : @"Off";
}

#pragma mark - driver

#if SG_DRIVER
#import "Diagnostics/Diagnostics.h"
// automix: Spotify's three settings and the product state; --automix, --crossfade and --ms write Spotify's.
NSDictionary *SGAutoMixProbeCommand(NSDictionary *p, NSString **error) {
    __block NSDictionary *result;
    dispatch_sync(dispatch_get_main_queue(), ^{
        SGTransitionSettings s;
        if (!SGTransitionSettingsRead(&s)) return;
        if (p[@"automix"]) s.automix = [p[@"automix"] boolValue];
        if (p[@"crossfade"]) s.crossfade = [p[@"crossfade"] boolValue];
        if (p[@"ms"]) s.milliseconds = [p[@"ms"] integerValue];
        if (p[@"automix"] || p[@"crossfade"] || p[@"ms"]) SGTransitionSettingsWrite(s);
        SGTransitionSettingsRead(&s);
        id next = SGPlayerState().future.firstObject;
        result = @{
            @"automix" : @(s.automix), @"crossfade" : @(s.crossfade), @"ms" : @(s.milliseconds),
            @"type" : [sg_productState stringForKey:@"type"] ?: @"unknown",
            @"catalogue" : [sg_productState stringForKey:@"catalogue"] ?: @"unknown",
            @"switch" : @(SGFlag(SGKeyAutoMix, NO)), @"style" : @(SGAutoMixCurrentStyle()),
            @"saved" : [NSUserDefaults.standardUserDefaults arrayForKey:SGKeyAutoMixSaved] ?: @[],
            @"allows" : @(SGAutoMixAccountAllows()),
            // Every metadata key of the playing track and the next, to look for what a transition carries.
            @"now" : SGPlayerState().track.metadata ?: @{},
            @"next" : ([next isKindOfClass:NSClassFromString(@"SPTPlayerTrack")] ? ((SPTPlayerTrack *)next).metadata : nil) ?: @{},
        };
    });
    if (!result) *error = @"Spotify's settings are not read yet";
    return result;
}
#endif

%ctor {
    %init;
    SGRequireClasses(@[@"SPTCoreProductState"]);
}
