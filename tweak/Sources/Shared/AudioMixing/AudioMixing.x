// Adds Apple's Mix With Others option to Spotify's playback audio session when enabled in Mod Settings.
// This changes Spotify's own session only; iOS and the other app still control their audio-session behavior.
#import <AVFoundation/AVFoundation.h>
#import "Core/SGCore.h"
#import "AudioMixing.h"

static AVAudioSessionCategoryOptions mixedOptions(AVAudioSessionCategory category,
                                                    AVAudioSessionCategoryOptions options) {
    if (SGEnabled(SGKeyAudioMixing) && [category isEqualToString:AVAudioSessionCategoryPlayback]) {
        if (!(options & AVAudioSessionCategoryOptionMixWithOthers)) {
            options |= AVAudioSessionCategoryOptionMixWithOthers;
            SGLog(@"audio mixing: added Mix With Others to Spotify playback session");
        }
    }
    return options;
}

%hook AVAudioSession
- (BOOL)setCategory:(AVAudioSessionCategory)category
               mode:(AVAudioSessionMode)mode
            options:(AVAudioSessionCategoryOptions)options
              error:(NSError **)outError {
    return %orig(category, mode, mixedOptions(category, options), outError);
}

- (BOOL)setCategory:(AVAudioSessionCategory)category
        withOptions:(AVAudioSessionCategoryOptions)options
              error:(NSError **)outError {
    return %orig(category, mixedOptions(category, options), outError);
}

- (BOOL)setCategory:(AVAudioSessionCategory)category error:(NSError **)outError {
    if (SGEnabled(SGKeyAudioMixing) && [category isEqualToString:AVAudioSessionCategoryPlayback]) {
        return [self setCategory:category withOptions:AVAudioSessionCategoryOptionMixWithOthers error:outError];
    }
    return %orig(category, outError);
}
%end

%ctor {
    %init;
    SGRequireClasses(@[@"AVAudioSession"]);
}
