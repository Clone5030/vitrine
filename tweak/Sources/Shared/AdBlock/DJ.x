// Spotify can still play the DJ when its country eligibility check reports false. Answer yes here to skip the
// misleading country alert when opening the DJ from the Library; playback remains Spotify's.
#import "Core/SGCore.h"

%hook _TtC16Endless_AIDJImpl26AIDJEligibilityCheckerImpl
- (void)isEligibleForDJWithCompletion:(void (^)(BOOL))completion {
    if (completion) completion(YES);
}
%end

%ctor {
    %init;
    SGRequireClasses(@[@"_TtC16Endless_AIDJImpl26AIDJEligibilityCheckerImpl"]);
}
