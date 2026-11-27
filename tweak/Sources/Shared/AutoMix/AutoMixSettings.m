// The AutoMix page (App/ModSettings.x links it from the root, under either look): the switch, then the style and
// the blend length, which read Spotify's own settings and gray out while the switch is off.
// It has no restart note: Spotify's player takes a new setting at the next track change.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "AutoMix.h"

// Spotify's own crossfade slider (Settings > Playback) runs from 0, which is off and is the switch here, to 12 s.
static const double kShortest = 1, kLongest = 12;

UIViewController *SGAutoMixSettingsPage(void) {
    SGModRow *toggle = SGOptionRow(@"AutoMix", nil, SGKeyAutoMix);
    toggle.changed = ^(BOOL on) { SGAutoMixApply(on); };

    NSArray<NSString *> *styles = @[@"Beat-matched", @"Crossfade"];
    SGModRow *style = SGMenuRow(@"Style", styles, ^NSString *{ return styles[(NSUInteger)SGAutoMixCurrentStyle()]; },
                                ^(NSInteger index) { SGAutoMixSetStyle(index); });
    style.waitsOn = SGKeyAutoMix;

    SGModRow *blend = SGSliderRow(@"Blend length", nil, kShortest, kLongest, 1,
        ^double {
            SGTransitionSettings s;
            return SGTransitionSettingsRead(&s) ? MAX(kShortest, MIN(kLongest, s.milliseconds / 1000.0)) : 5;
        },
        ^(double value) { SGAutoMixSetSeconds(lround(value)); },
        ^NSString *(double value) { return [NSString stringWithFormat:@"%ld s", lround(value)]; });
    blend.waitsOn = SGKeyAutoMix;

    SGModRow *smart = SGOptionRow(@"Smart blend length", nil, SGKeyAutoMixSmart);
    smart.waitsOn = SGKeyAutoMix;
    smart.changed = ^(BOOL on) { if (on && SGFlag(SGKeyAutoMix, NO)) SGSmartMixStart(); };
    SGModRow *pill = SGOptionRow(@"Mixing pill", nil, SGKeyAutoMixPill);
    pill.waitsOn = SGKeyAutoMix;
    pill.changed = ^(BOOL on) { if (on && SGFlag(SGKeyAutoMix, NO)) SGSmartMixStart(); };

    SGModRow *artwork = SGOptionRow(@"Artwork moves with the mix", nil, SGKeyAutoMixArtwork);
    artwork.waitsOn = SGKeyAutoMix;
    artwork.changed = ^(BOOL on) { if (on && SGFlag(SGKeyAutoMix, NO)) SGSmartMixStart(); };
    SGModRow *progress = SGOptionRow(@"Transitions in the progress bar", @"Show the transition range on the player scrubber", SGKeyAutoMixProgress);
    progress.waitsOn = SGKeyAutoMix;
    progress.changed = ^(BOOL on) { if (on && SGFlag(SGKeyAutoMix, NO)) SGSmartMixStart(); };
    SGModRow *status = SGOptionRow(@"Transition status", @"Shows over the player which mix is next and when it starts", SGKeyAutoMixStatus);
    status.waitsOn = SGKeyAutoMix;
    status.changed = ^(BOOL on) { if (on && SGFlag(SGKeyAutoMix, NO)) SGSmartMixStart(); };

    NSString *note = SGAutoMixAccountAllows() ? nil : @"AutoMix needs Premium, or Spoof Premium under Premium, ads & privacy.";
    return [[SGModPage alloc] initWithTitle:@"AutoMix" intro:nil sections:@[
        SGNotedSection(nil, @[toggle, style, blend], note),
        SGNotedSection(nil, @[smart, pill, artwork, progress, status], @"These extra player features are off until enabled. Smart blend picks a length for each pair from Spotify's track details; it does not listen for beats. Beat-matched is Spotify's own."),
    ] footer:nil];
}
