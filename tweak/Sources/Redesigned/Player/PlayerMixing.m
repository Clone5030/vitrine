// The transition status capsule above the player's timeline: a countdown until the AutoMix window, then Mixing.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Shared/AutoMix/AutoMix.h"
#import "Shared/Sing/Sing.h"
#import "Player.h"

static const CGFloat kPillHeight = 26, kPillPad = 10, kPillGap = 4;
static char kPillKey, kGlassKey;

@interface SGRMixingPill : UIView
@end

@implementation SGRMixingPill {
    UIImageView *_icon;
    UILabel *_label;
    UISlider *_slider;
    UIView *_range;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.userInteractionEnabled = NO;
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.alpha = 0;
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightSemibold];
    _icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"waveform" withConfiguration:config]];
    _icon.tintColor = SGRPrimary();
    [self addSubview:_icon];
    _label = [UILabel new];
    _label.font = SGRFont(UIFontTextStyleCaption1, UIFontWeightSemibold, UIContentSizeCategoryAccessibilityMedium);
    _label.textColor = SGRPrimary();
    [self addSubview:_label];
    self.isAccessibilityElement = YES;
    self.accessibilityLabel = @"Mixing into the next song";
    return self;
}

- (CGSize)sizeThatFits:(CGSize)size {
    [_label sizeToFit];
    return CGSizeMake(kPillPad + 14 + kPillGap + _label.bounds.size.width + kPillPad, kPillHeight);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _icon.frame = CGRectMake(kPillPad, (kPillHeight - 14) / 2, 14, 14);
    _label.frame = CGRectMake(CGRectGetMaxX(_icon.frame) + kPillGap, 0, _label.bounds.size.width, kPillHeight);
    BOOL showProgress = SGFlag(SGKeyAutoMix, NO) && SGFlag(SGKeyAutoMixProgress, NO) && _slider && SGAutoMixPlannedSeconds() > 0;
    if (showProgress) {
        double duration = SGPlayerState().duration;
        CGFloat share = duration > 0 ? MIN(1, SGAutoMixPlannedSeconds() / duration) : 0;
        CGRect track = [_slider trackRectForBounds:_slider.bounds];
        CGRect thumb = [_slider thumbRectForBounds:_slider.bounds trackRect:track value:_slider.maximumValue];
        CGFloat end = CGRectGetMidX(thumb);
        thumb = [_slider thumbRectForBounds:_slider.bounds trackRect:track value:_slider.minimumValue];
        CGFloat begin = CGRectGetMidX(thumb);
        CGRect segment = CGRectMake(end - (end - begin) * share, CGRectGetMidY(track) - 1.5, (end - begin) * share, 3);
        if (!_range) { _range = [UIView new]; _range.backgroundColor = SGRPrimary(); _range.alpha = 0.8; _range.userInteractionEnabled = NO; [self.superview insertSubview:_range belowSubview:self]; }
        _range.frame = [_slider.superview convertRect:segment toView:self.superview];
        _range.layer.cornerRadius = 1.5;
        _range.hidden = NO;
    } else {
        _range.hidden = YES;
    }
}

- (void)updateStatus {
    double until = SGAutoMixSecondsUntilStart();
    BOOL mixing = SGAutoMixMixing();
    BOOL singing = SGFlag(SGKeySing, NO) && SGRPlayerLyricsOpen();
    BOOL status = SGFlag(SGKeyAutoMix, NO) && SGFlag(SGKeyAutoMixStatus, NO);
    BOOL pill = SGFlag(SGKeyAutoMix, NO) && SGFlag(SGKeyAutoMixPill, NO);
    SPTPlayerState *state = SGPlayerState();
    NSInteger seconds = MAX(0, (NSInteger)ceil(until));
    NSString *countdown = [NSString stringWithFormat:@"%ld:%02ld", (long)(seconds / 60), (long)(seconds % 60)];
    NSInteger start = state && state.duration > 0 ? MAX(0, (NSInteger)round(state.duration - SGAutoMixPlannedSeconds())) : 0;
    NSInteger end = start + (NSInteger)round(SGAutoMixPlannedSeconds());
    NSString *window = [NSString stringWithFormat:@"%ld:%02ld–%ld:%02ld", (long)(start / 60), (long)(start % 60), (long)(end / 60), (long)(end % 60)];
    NSString *text = singing ? @"Sing" : (status && (mixing || until >= 0) ? (mixing ? @"Mixing" : [NSString stringWithFormat:@"AutoMix in %@ · %@", countdown, window]) : (pill && mixing ? @"Mixing" : @""));
    BOOL textChanged = ![_label.text isEqualToString:text];
    if (textChanged) {
        _label.text = text;
        [_label sizeToFit];
    }
    self.accessibilityLabel = mixing ? @"Mixing into the next song" : (until < 0 ? @"No upcoming mix" : [NSString stringWithFormat:@"Next mix starts in %ld seconds", (long)seconds]);
    BOOL visible = singing || (status && (mixing || until >= 0)) || (pill && mixing);
    if (mixing && !SGRReduceMotion()) {
        if (![self.layer animationForKey:@"sgr.mixing.glow"]) {
            CABasicAnimation *glow = [CABasicAnimation animationWithKeyPath:@"shadowOpacity"];
            glow.fromValue = @0.12;
            glow.toValue = @0.85;
            glow.duration = 0.9;
            glow.autoreverses = YES;
            glow.repeatCount = HUGE_VALF;
            self.layer.shadowColor = SGRPrimary().CGColor;
            self.layer.shadowRadius = 8;
            self.layer.shadowOffset = CGSizeZero;
            [self.layer addAnimation:glow forKey:@"sgr.mixing.glow"];
        }
    } else {
        [self.layer removeAnimationForKey:@"sgr.mixing.glow"];
        self.layer.shadowOpacity = 0;
    }
    CGFloat alpha = visible ? 1 : 0;
    if (fabs(self.alpha - alpha) > 0.01) {
        if (SGRReduceMotion()) self.alpha = alpha;
        else [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction animations:^{ self.alpha = alpha; } completion:nil];
    }
    if (self.superview) {
        CGFloat right = CGRectGetMaxX(self.frame);
        CGSize size = [self sizeThatFits:CGSizeZero];
        if (fabs(self.bounds.size.width - size.width) > 0.5) {
            self.frame = CGRectMake(right - size.width, self.frame.origin.y, size.width, size.height);
            SGRGlassCapsuleInside(self, &kGlassKey, size, NO);
        }
    }
    if (textChanged) [self setNeedsLayout];
}

- (void)setSlider:(UISlider *)slider { _slider = slider; [self setNeedsLayout]; }
- (void)removeRange { [_range removeFromSuperview]; _range = nil; }

@end

static __weak SGRMixingPill *sg_pill;   // the player has one duration unit on screen at a time

// Called with every pass of the duration unit's layout: puts the pill over the slider's right end.
void SGRMixingPlace(UIView *host, UISlider *slider) {
    // Spotify's progress-bar identifier can belong to a non-slider wrapper on some builds.
    // Never send UISlider-only messages (including bounds) to that cached view.
    if (![slider isKindOfClass:UISlider.class]) slider = nil;
    SGRMixingPill *pill = objc_getAssociatedObject(host, &kPillKey);
    BOOL needed = SGFlag(SGKeyAutoMix, NO) && (SGFlag(SGKeyAutoMixPill, NO) || SGFlag(SGKeyAutoMixStatus, NO) || SGFlag(SGKeyAutoMixProgress, NO));
    if (!needed) { [pill removeRange]; [pill removeFromSuperview]; objc_setAssociatedObject(host, &kPillKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); return; }
    if (!pill) {
        pill = [SGRMixingPill new];
        objc_setAssociatedObject(host, &kPillKey, pill, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        sg_pill = pill;
        pill.alpha = 0;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            // Posted on the main thread; the pill in use is the latest made.
            [NSNotificationCenter.defaultCenter addObserverForName:SGAutoMixMixingDidChangeNotification object:nil queue:nil
                                                        usingBlock:^(NSNotification *n) {
                dispatch_async(dispatch_get_main_queue(), ^{ [sg_pill updateStatus]; });
            }];
        });
    }
    if (pill.superview != host) [host addSubview:pill];
    else if (host.subviews.lastObject != pill) [host bringSubviewToFront:pill];
    [pill updateStatus];
    CGSize size = [pill sizeThatFits:CGSizeZero];
    [pill setSlider:slider];
    CGRect bar = slider ? [host convertRect:slider.bounds fromView:slider] : CGRectMake(0, kPillHeight + kPillGap, host.bounds.size.width, 0);
    CGFloat y = MIN(host.bounds.size.height - size.height, CGRectGetMaxY(bar) + 5);
    pill.frame = CGRectMake(CGRectGetMaxX(bar) - size.width, y, size.width, size.height);
    SGRGlassCapsuleInside(pill, &kGlassKey, size, NO);
}

