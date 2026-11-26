// Keep Spotify's video switch visible unless the user asks to hide it.
//
// The switch is the chip Spotify puts over the track's title for a song with a music video, Switch to
// video and, once switched, Switch to audio. Its accessibility identifier is nowplaying-npv-musicvideos-switch:
// in 9.1.78's strings it sits between NowPlaying_ElementsKit's AudioVideoSwitchButtonAdapter and the
// sNowPlayingMusicVideosSwitchToVideo and ...SwitchToAudio strings, and no recorded tree shows it yet. The
// chips are FloatingElementsUnit's (Redesigned/Player/PlayerLyrics.x), a unit of Spotify's player that both
// looks keep, so its pass looks for it there. It goes by alpha, not hidden, since it may sit in one of
// Spotify's stacks (AGENTS.md), and takes no touches and says nothing to VoiceOver.
#import "Core/SGCore.h"
#import "PlayerSettings.h"

static NSString *const kSwitchIdentifier = @"nowplaying-npv-musicvideos-switch";

static UIView *switchIn(UIView *root, int depth) {
    if ([root.accessibilityIdentifier isEqualToString:kSwitchIdentifier]) return root;
    if (depth > 10) return nil;
    for (UIView *child in root.subviews) {
        UIView *found = switchIn(child, depth + 1);
        if (found) return found;
    }
    return nil;
}

%hook _TtC20NowPlaying_ModesImpl20FloatingElementsUnit
- (void)viewDidLayoutSubviews {
    %orig;
    UIView *videoSwitch = switchIn(((UIViewController *)self).viewIfLoaded, 0);
    if (!videoSwitch) return;
    BOOL hidden = SGHidden(SGKeyHideVideoSwitch);
    videoSwitch.alpha = hidden ? 0 : 1;
    videoSwitch.userInteractionEnabled = !hidden;
    videoSwitch.accessibilityElementsHidden = hidden;
    static BOOL logged;
    if (!logged) {
        logged = YES;
        SGLog(@"player: Spotify supplied its music video switch (%@ %@), %@", NSStringFromClass(videoSwitch.class), NSStringFromCGRect(videoSwitch.frame), hidden ? @"hidden by setting" : @"left visible");
    }
}
%end

%ctor {
    %init;
    SGRequireClasses(@[@"_TtC20NowPlaying_ModesImpl20FloatingElementsUnit"]);
}
