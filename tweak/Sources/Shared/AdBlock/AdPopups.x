// The Premium prompts Spotify presents as Encore pop-ups, dropped when their words sell Premium
// (EeveeSpotify's UpsellPopupBlocker). The words are read where the dialog model is made, since
// the dialog handed to the presenter does not expose them on every build; the presenter reads
// them itself as a fallback.
#import "Core/SGCore.h"
#import "AdBlock.h"

static NSString *const words[] = {
    @"premium", @"upgrade", @"subscribe", @"subscription", @"listening without limits", @"unlimited skips",
    @"play the songs you love", @"go premium", @"like listening", @"free account", @"ad-free", @"ad free", @"try free",
    @"get premium", @"start premium", @"upsell", @"paywall", @"free tier", @"limited listening",
    @"předplatn", @"bez reklam",
};

static char kUpsellKey;

static BOOL djCountryNotice(NSString *text) {
    if (![text isKindOfClass:NSString.class]) return NO;
    NSString *lower = text.lowercaseString;
    BOOL namesDJ = [lower containsString:@"dj"] || [lower containsString:@"deejay"];
    BOOL namesPlace = [lower containsString:@"country"] || [lower containsString:@"region"];
    BOOL unavailable = [lower containsString:@"unavailable"] || [lower containsString:@"not available"] ||
                       [lower containsString:@"isn't available"] || [lower containsString:@"aren't available"];
    return namesDJ && namesPlace && unavailable;
}

static BOOL sells(NSString *text) {
    if (![text isKindOfClass:NSString.class]) return NO;
    text = text.lowercaseString;
    for (size_t i = 0; i < sizeof(words) / sizeof(words[0]); i++) {
        if ([text containsString:words[i]]) return YES;
    }
    return NO;
}

static void mark(id object) {
    objc_setAssociatedObject(object, &kUpsellKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL marked(id object) {
    return objc_getAssociatedObject(object, &kUpsellKey) != nil;
}

// valueForKey: on a key the object lacks raises, so it is only asked what it answers to.
static id readKey(id object, NSString *key) {
    return [object respondsToSelector:NSSelectorFromString(key)] ? [object valueForKey:key] : nil;
}

%group SGEncorePopupHooks
%hook SPTEncorePopUpDialogModel
- (id)initWithTitle:(NSString *)title description:(NSString *)description image:(id)image primaryButtonTitle:(NSString *)primary secondaryButtonTitle:(NSString *)secondary {
    id model = %orig;
    if (model && SGHidden(SGKeyHideUpsells) && (sells(title) || sells(description) || sells(primary) || sells(secondary))) mark(model);
    return model;
}
%end

%hook SPTEncorePopUpDialog
- (void)update:(id)model {
    if (marked(model)) mark(self);
    %orig;
}
%end

%hook SPTEncorePopUpPresenter
- (void)presentPopUp:(id)popUp {
    id model = readKey(popUp, @"model") ?: popUp;
    NSString *title = readKey(model, @"title") ?: readKey(model, @"dialogTitle");
    NSString *body = readKey(model, @"descriptionText") ?: readKey(model, @"body") ?: readKey(model, @"subtitle");
    if (djCountryNotice(title) || djCountryNotice(body)) {
        SGLog(@"dismissed DJ country-availability notice");
        return;
    }
    if (!SGHidden(SGKeyHideUpsells)) { %orig; return; }
    SGAdBlockSawOne(@"Popups");
    if (marked(popUp) || sells(title) || sells(body)) {
        SGAdBlockCountOne(@"Popups");
        SGLog(@"dropped pop-up %@", title ?: @"(marked at its model)");
        return;
    }
    %orig;
}
%end
%end

// Some Spotify builds present the same notice as a UIKit alert rather than an Encore popup.
%hook UIViewController
- (void)presentViewController:(UIViewController *)presented animated:(BOOL)animated completion:(void (^)(void))completion {
    if ([presented isKindOfClass:UIAlertController.class]) {
        UIAlertController *alert = (UIAlertController *)presented;
        if (djCountryNotice(alert.title) || djCountryNotice(alert.message)) {
            SGLog(@"dismissed DJ country-availability alert");
            if (completion) completion();
            return;
        }
    }
    %orig;
}
%end

%ctor {
    %init;
    if (NSClassFromString(@"SPTEncorePopUpDialogModel") && NSClassFromString(@"SPTEncorePopUpDialog") &&
        NSClassFromString(@"SPTEncorePopUpPresenter")) {
        %init(SGEncorePopupHooks);
        SGRequireClasses(@[@"SPTEncorePopUpDialogModel", @"SPTEncorePopUpDialog", @"SPTEncorePopUpPresenter"]);
    }
}
