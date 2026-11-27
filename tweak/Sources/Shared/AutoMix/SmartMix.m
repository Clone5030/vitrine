// Smart blend: the length of each blend is chosen for the pair of songs it joins, where Spotify's crossfade has one
// length for every pair. Only what the player reports is known (the two tracks' length, album and artists), so
// this is a plan from metadata, not from the sound: it does not find beats, and Spotify's own beat-matched Automix
// (the Style row) stays Spotify's. What it decides, per pair, written to Spotify's crossfade before the change:
//
//   the next song is the next on the same album   no blend, so a gapless album stays gapless
//   a short song on either side                    about a tenth of the shorter, at least 2 s
//   one artist across albums                       a medium blend
//   two artists                                    the longest blend (the Blend length row is the ceiling)
//
// It also says when a blend is playing, for the Mixing pill: the playing song has no more left than the pair's
// blend length. Spotify's player takes a new setting at the next track change, so the plan is written as soon
// as the next song is known, early in the playing one.
//
// Threading: main thread; the player state observer is called there.
#import "Core/SGCore.h"
#import "Shared/Player/PlayerState.h"
#import "AutoMix.h"

NSNotificationName const SGAutoMixMixingDidChangeNotification = @"SGAutoMixMixingDidChange";

static const NSInteger kShortestMs = 2000;

static BOOL sg_mixing;
static NSInteger sg_plannedMs;      // 0: this pair is not blended
static NSString *sg_plannedFor;     // the playing song's URI, which the plan is for
static NSInteger sg_ceilingMs;      // the longest blend: Spotify's setting as the switch left it
static double sg_secondsUntilStart = -1;

BOOL SGAutoMixMixing(void) { return sg_mixing; }
double SGAutoMixSecondsUntilStart(void) { return sg_secondsUntilStart; }
double SGAutoMixPlannedSeconds(void) {
    if (SGFlag(SGKeyAutoMixSmart, NO)) return sg_plannedMs / 1000.0;
    SGTransitionSettings settings;
    return SGTransitionSettingsRead(&settings) && settings.crossfade ? settings.milliseconds / 1000.0 : 0;
}

static NSString *meta(id track, NSString *key) {
    if (![track isKindOfClass:NSClassFromString(@"SPTPlayerTrack")]) return nil;
    id value = ((SPTPlayerTrack *)track).metadata[key];
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static BOOL sameNonNil(NSString *a, NSString *b) { return a.length && [a isEqualToString:b]; }

// The blend for the song playing into `next`, in ms; 0 for none.
static NSInteger planFor(SPTPlayerState *state, id next, NSInteger ceiling) {
    SPTPlayerTrack *now = state.track;
    NSString *nowAlbum = meta(now, @"album_uri") ?: meta(now, @"album_title");
    NSString *nextAlbum = meta(next, @"album_uri") ?: meta(next, @"album_title");
    NSString *nowNumber = meta(now, @"album_track_number"), *nextNumber = meta(next, @"album_track_number");
    // The next song on the same album: the album is meant to run on.
    if (sameNonNil(nowAlbum, nextAlbum) && (!nowNumber || !nextNumber || nextNumber.integerValue == nowNumber.integerValue + 1)) return 0;
    double shorter = state.duration;
    NSString *nextLength = meta(next, @"duration");
    if (nextLength.doubleValue > 0) shorter = MIN(shorter, nextLength.doubleValue / 1000.0);
    NSInteger length = sameNonNil(meta(now, @"artist_uri"), meta(next, @"artist_uri")) ? ceiling * 6 / 10 : ceiling;
    if (shorter > 0) length = MIN(length, (NSInteger)(shorter * 100));   // a tenth of the shorter song, in ms
    length = (length + 500) / 1000 * 1000;                                // Spotify's slider moves in whole seconds
    return MAX(kShortestMs, length);
}

@interface SGSmartMix : NSObject <SGPlayerStateObserver>
@end

@implementation SGSmartMix {
    SPTPlayerState *_last;
    NSTimer *_timer;
    NSString *_plannedNext;
}

- (void)setMixing:(BOOL)mixing {
    if (mixing == sg_mixing) return;
    sg_mixing = mixing;
    [NSNotificationCenter.defaultCenter postNotificationName:SGAutoMixMixingDidChangeNotification object:nil];
}

- (void)playerStateDidChange:(SPTPlayerState *)state {
}

- (void)playerStateDidReport:(SPTPlayerState *)state {
    _last = state;
    if (!SGFlag(SGKeyAutoMix, NO)) { [self setMixing:NO]; return; }
    NSString *uri = SGURIString(state.track.URI);
    id next = state.future.firstObject;
    BOOL known = [next isKindOfClass:NSClassFromString(@"SPTPlayerTrack")];
    if (uri && known && SGFlag(SGKeyAutoMixSmart, NO) && !(sg_plannedFor && [sg_plannedFor isEqualToString:uri] && [self planned:next])) {
        SGTransitionSettings s;
        if (!SGTransitionSettingsRead(&s)) return;
        // The ceiling is Spotify's blend length the first time, and the slider's value after.
        if (!sg_ceilingMs) sg_ceilingMs = s.milliseconds > 0 ? s.milliseconds : 5000;
        NSInteger ms = state.options.repeatingTrack ? 0 : planFor(state, next, MAX(sg_ceilingMs, kShortestMs));
        sg_plannedFor = uri;
        sg_plannedMs = ms;
        _plannedNext = SGURIString(((SPTPlayerTrack *)next).URI);
        SGTransitionSettings plan = s;
        plan.crossfade = ms > 0;
        if (ms > 0) plan.milliseconds = ms;
        if (plan.crossfade != s.crossfade || plan.milliseconds != s.milliseconds) SGTransitionSettingsWrite(plan);
        SGLog(@"smart mix: %@ into %@: %@", uri, _plannedNext, ms ? [NSString stringWithFormat:@"%ld ms", (long)ms] : @"no blend");
    }
    if (!_timer) {
        // Position moves between reports, so the pill asks the clock a few times a second.
        __weak SGSmartMix *weak = self;
        _timer = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *t) { [weak tick]; }];
    }
}

- (BOOL)planned:(id)next {
    return [_plannedNext isEqualToString:SGURIString(((SPTPlayerTrack *)next).URI)];
}

- (void)tick {
    SPTPlayerState *state = _last;
    NSInteger blend = sg_plannedMs;
    NSString *trackURI = state ? SGURIString(state.track.URI) : nil;
    if (!SGFlag(SGKeyAutoMixSmart, NO)) {
        // Without the plan, Spotify's one blend length is the length of every blend.
        SGTransitionSettings s;
        blend = SGTransitionSettingsRead(&s) && s.crossfade ? s.milliseconds : 0;
    } else if (![sg_plannedFor isEqualToString:trackURI ?: @""]) {
        blend = 0;
    }
    if (!state || !SGFlag(SGKeyAutoMix, NO) || state.isPaused || !blend || state.options.repeatingTrack || state.duration <= 0) {
        BOOL changed = sg_mixing || sg_secondsUntilStart >= 0;
        sg_mixing = NO;
        sg_secondsUntilStart = -1;
        if (changed) [NSNotificationCenter.defaultCenter postNotificationName:SGAutoMixMixingDidChangeNotification object:nil];
        return;
    }
    double elapsed = [NSDate.date timeIntervalSinceDate:state.timestamp] * state.playbackSpeed;
    double left = state.duration - (state.positionAsOfTimestamp + elapsed);
    double window = blend / 1000.0;
    BOOL mixing = left > 0 && left <= window;
    double until = MAX(0, left - window);
    BOOL changed = mixing != sg_mixing || (mixing ? sg_secondsUntilStart >= 0 : fabs(until - sg_secondsUntilStart) >= 0.45);
    sg_secondsUntilStart = mixing ? -1 : until;
    if (changed) {
        sg_mixing = mixing;
        [NSNotificationCenter.defaultCenter postNotificationName:SGAutoMixMixingDidChangeNotification object:nil];
    }
}

@end

static SGSmartMix *sg_smart;

void SGSmartMixStart(void) {
    if (sg_smart) return;
    sg_smart = [SGSmartMix new];
    SGAddPlayerStateObserver(sg_smart);
}
