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

    SGModRow *smart = SGSwitchRow(@"Smart blend length", nil, SGKeyAutoMixSmart);
    smart.waitsOn = SGKeyAutoMix;
    SGModRow *pill = SGSwitchRow(@"Mixing pill", nil, SGKeyAutoMixPill);
    pill.waitsOn = SGKeyAutoMix;

    NSString *note = SGAutoMixAccountAllows() ? nil : @"AutoMix needs Premium, or Spoof Premium under Premium, ads & privacy.";
    return [[SGModPage alloc] initWithTitle:@"AutoMix" intro:nil sections:@[
        SGNotedSection(nil, @[toggle, style, blend], note),
        SGNotedSection(nil, @[smart, pill], @"Smart blend picks a length for each pair of songs from what Spotify reports about them: none between songs that run on in an album, shorter for short songs, longest between artists. The Blend length is its ceiling. It does not listen for beats; Beat-matched is Spotify's own. The pill shows over the player's timeline while a blend plays."),
    ] footer:nil];
}
