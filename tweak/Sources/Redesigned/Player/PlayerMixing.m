// The Mixing pill: a small glass capsule over the right end of the player's timeline while AutoMix is blending the
// playing song into the next (Shared/AutoMix/SmartMix.m says when). It belongs to the duration unit's view, above the
// slider, and fades in and out; it takes no touches. Where the unit's view clips, it sits inside the view's top edge.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Shared/AutoMix/AutoMix.h"
#import "Player.h"

static const CGFloat kPillHeight = 26, kPillPad = 10, kPillGap = 4;

@interface SGRMixingPill : UIView
@end

@implementation SGRMixingPill {
    UIImageView *_icon;
    UILabel *_label;
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
    _label.text = @"Mixing";
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
}

@end

static char kPillKey, kGlassKey;
static __weak SGRMixingPill *sg_pill;   // the player has one duration unit on screen at a time

static void setShown(SGRMixingPill *pill, BOOL shown) {
    if (SGRReduceMotion()) { pill.alpha = shown ? 1 : 0; return; }
    [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{ pill.alpha = shown ? 1 : 0; } completion:nil];
}

// Called with every pass of the duration unit's layout: puts the pill over the slider's right end.
void SGRMixingPlace(UIView *host, UISlider *slider) {
    SGRMixingPill *pill = objc_getAssociatedObject(host, &kPillKey);
    if (!SGFlag(SGKeyAutoMix, NO) || !SGFlag(SGKeyAutoMixPill, YES)) { [pill removeFromSuperview]; objc_setAssociatedObject(host, &kPillKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); return; }
    if (!pill) {
        pill = [SGRMixingPill new];
        objc_setAssociatedObject(host, &kPillKey, pill, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        sg_pill = pill;
        pill.alpha = SGAutoMixMixing() ? 1 : 0;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            // Posted on the main thread; the pill in use is the latest made.
            [NSNotificationCenter.defaultCenter addObserverForName:SGAutoMixMixingDidChangeNotification object:nil queue:nil
                                                        usingBlock:^(NSNotification *n) {
                dispatch_async(dispatch_get_main_queue(), ^{ if (sg_pill) setShown(sg_pill, SGAutoMixMixing()); });
            }];
        });
    }
    if (pill.superview != host) [host addSubview:pill];
    else if (host.subviews.lastObject != pill) [host bringSubviewToFront:pill];
    CGSize size = [pill sizeThatFits:CGSizeZero];
    CGRect bar = slider ? [host convertRect:slider.bounds fromView:slider] : CGRectMake(0, kPillHeight + kPillGap, host.bounds.size.width, 0);
    CGFloat y = MAX(0, CGRectGetMinY(bar) - size.height - kPillGap);
    pill.frame = CGRectMake(CGRectGetMaxX(bar) - size.width, y, size.width, size.height);
    SGRGlassCapsuleInside(pill, &kGlassKey, size, NO);
}
