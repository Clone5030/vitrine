// Adds Apple's Mix With Others option to Spotify's playback audio session when enabled in Mod Settings.
// This changes Spotify's own session only; iOS and the other app still control their audio-session behavior.
#import <AVFoundation/AVFoundation.h>
#import "Core/SGCore.h"
#import "AudioMixing.h"

static AVAudioSessionCategoryOptions SGAudioMixingOptions(AVAudioSessionCategory category,
                                                           AVAudioSessionCategoryOptions options) {
    if (SGEnabled(SGKeyAudioMixing) &&
        [category isEqualToString:AVAudioSessionCategoryPlayback]) {
        options |= AVAudioSessionCategoryOptionMixWithOthers;
    }
    return options;
}

%hook AVAudioSession

// Older category setter.
- (BOOL)setCategory:(AVAudioSessionCategory)category error:(NSError **)outError {
    if (SGEnabled(SGKeyAudioMixing) &&
        [category isEqualToString:AVAudioSessionCategoryPlayback]) {
        return [self setCategory:category
                    withOptions:AVAudioSessionCategoryOptionMixWithOthers
                          error:outError];
    }
    return %orig(category, outError);
}

// Category + options setter.
- (BOOL)setCategory:(AVAudioSessionCategory)category
        withOptions:(AVAudioSessionCategoryOptions)options
              error:(NSError **)outError {
    return %orig(category, SGAudioMixingOptions(category, options), outError);
}

// Category + mode + options setter.
- (BOOL)setCategory:(AVAudioSessionCategory)category
               mode:(AVAudioSessionMode)mode
            options:(AVAudioSessionCategoryOptions)options
              error:(NSError **)outError {
    return %orig(category, mode, SGAudioMixingOptions(category, options), outError);
}

// Modern category + mode + route-sharing-policy + options setter.
// Spotify or an Apple framework may use this overload instead of the simpler setters.
- (BOOL)setCategory:(AVAudioSessionCategory)category
               mode:(AVAudioSessionMode)mode
 routeSharingPolicy:(AVAudioSessionRouteSharingPolicy)policy
            options:(AVAudioSessionCategoryOptions)options
              error:(NSError **)outError {
    AVAudioSessionCategoryOptions adjusted = policy == AVAudioSessionRouteSharingPolicyDefault
        ? SGAudioMixingOptions(category, options) : options;
    return %orig(category, mode, policy, adjusted, outError);
}

%end

%ctor {
    %init;
    SGRequireClasses(@[@"AVAudioSession"]);
}
