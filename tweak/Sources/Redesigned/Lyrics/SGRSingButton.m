#import "Core/SGCore.h"
#import "Settings/SGPageStyle.h"
#import "Shared/Sing/Sing.h"
#import "Redesigned/Kit/SGRAccent.h"
#import "Redesigned/Kit/SGRGlass.h"
#import "Redesigned/Kit/SGRTokens.h"
#import "SGRSingButton.h"

static const CGFloat kGlyph = 17, kRingWidth = 2.5, kRingInset = 1.5;
// The slider's capsule over the button, and the gap between them: wider than SGRGlassSpacing (16), so the
// two glass shapes stay apart rather than sampling each other.
static const CGFloat kPanelHeight = 168, kPanelGap = 24, kLevelWidth = 120, kLevelHeight = 20;
// The capsule opens from just under full size at the mic, the way a popover grows out of what opened it.
static const CGFloat kPanelEnterScale = 0.95;
static const NSTimeInterval kPanelStays = 2.5;
static const float kLevelStep = 0.05f;
// As sung (1) holds the thumb this close either side, 4% of the slider's travel: a detent caught with a tick, as the
// Sing page's tall slider ticks there.
static const float kAsSungCatch = 0.08f;
static const CGFloat kMarkWidth = 14;
static char kPanelGlassKey;
// The button is a tall white capsule with a dark mic and sparkles on it, as Apple Music's Sing button is, so its
// glyphs are dark. The mic and the sparkles are drawn once into one template image, so the button's tint colors them.
static const CGFloat kPillMicTilt = 40;   // degrees clockwise: the mic's head leans to the upper right

static UIColor *ink(void) {
    return [UIColor colorWithWhite:0.1 alpha:1];
}

static UIImage *singGlyph(void) {
    static UIImage *image;
    if (image) return image;
    CGSize size = CGSizeMake(32, 40);
    UIImage *mic = [UIImage systemImageNamed:@"mic.fill" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightSemibold]];
    UIImage *big = [UIImage systemImageNamed:@"sparkle" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:10 weight:UIImageSymbolWeightBold]];
    UIImage *small = [UIImage systemImageNamed:@"sparkle" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:7 weight:UIImageSymbolWeightBold]];
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    UIImage *drawn = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGContextRef c = context.CGContext;
        CGContextSaveGState(c);
        CGContextTranslateCTM(c, size.width / 2, size.height / 2 + 1);
        CGContextRotateCTM(c, kPillMicTilt * M_PI / 180);
        [[mic imageWithTintColor:UIColor.blackColor renderingMode:UIImageRenderingModeAlwaysOriginal] drawInRect:CGRectMake(-mic.size.width / 2, -mic.size.height / 2, mic.size.width, mic.size.height)];
        CGContextRestoreGState(c);
        [[big imageWithTintColor:UIColor.blackColor renderingMode:UIImageRenderingModeAlwaysOriginal] drawInRect:CGRectMake(0, 2, big.size.width, big.size.height)];
        [[small imageWithTintColor:UIColor.blackColor renderingMode:UIImageRenderingModeAlwaysOriginal] drawInRect:CGRectMake(size.width - small.size.width - 1, size.height - small.size.height - 3, small.size.width, small.size.height)];
    }];
    image = [drawn imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    return image;
}

@implementation SGRSingButton {
    UIView *_pill;       // the white capsule behind the glyph; not glass, so it fades by its alpha
    UIButton *_button;   // holds no glass, so its alpha is free to fade
    CAShapeLayer *_ring;
    BOOL _ringShown;
    NSString *_glyph;
    UIView *_panel;
    UISlider *_slider;
    UIView *_mark;       // across the track at As sung
    UISelectionFeedbackGenerator *_feedback;
    BOOL _caught;        // the thumb is held at As sung
    UILabel *_level;
    NSTimer *_hide;
    BOOL _panelShown;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    // A white capsule behind a plain button (layoutSubviews), which fades by its alpha when the controls go.
    _pill = [UIView new];
    _pill.backgroundColor = UIColor.whiteColor;
    _pill.layer.cornerCurve = kCACornerCurveContinuous;
    _pill.userInteractionEnabled = NO;
    [self addSubview:_pill];
    UIButtonConfiguration *config = [UIButtonConfiguration plainButtonConfiguration];
    config.preferredSymbolConfigurationForImage = [UIImageSymbolConfiguration configurationWithPointSize:kGlyph weight:UIImageSymbolWeightSemibold];
    _button = [UIButton buttonWithConfiguration:config primaryAction:nil];
    // Light, so the glyph's dark ink reads on the white capsule whatever the system's appearance is.
    _button.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    _button.tintColor = ink();
    _button.isAccessibilityElement = NO;
    [_button addTarget:self action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];
    [_button addGestureRecognizer:[[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(held:)]];
    [self addSubview:_button];

    // VoiceOver has the mic itself as one adjustable button: the slider shows only for a held finger and
    // goes again on a timer, which a swipe up or down never holds open.
    self.isAccessibilityElement = YES;
    self.accessibilityLabel = @"Karaoke";
    self.accessibilityHint = @"Turns the vocals down";
    self.accessibilityTraits = UIAccessibilityTraitButton | UIAccessibilityTraitAdjustable;

    _ring = [CAShapeLayer layer];
    _ring.fillColor = UIColor.clearColor.CGColor;
    _ring.strokeColor = ink().CGColor;
    _ring.lineWidth = kRingWidth;
    _ring.lineCap = kCALineCapRound;
    _ring.opacity = 0;
    [self.layer addSublayer:_ring];

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:SGSingChangedNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:UIAccessibilityReduceMotionStatusDidChangeNotification object:nil];
    [self refresh];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_hide invalidate];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    _button.frame = bounds;
    _pill.frame = bounds;
    _pill.layer.cornerRadius = MIN(bounds.size.width, bounds.size.height) / 2;
    _ring.frame = bounds;
    // A circle in the middle of the capsule, as wide as the capsule: it turns about its centre, which a
    // capsule-shaped ring could not. Starting at the top and running clockwise, as a download ring does.
    CGFloat radius = MIN(bounds.size.width, bounds.size.height) / 2 - kRingInset - kRingWidth / 2;
    _ring.path = [UIBezierPath bezierPathWithArcCenter:CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds)) radius:radius
                                            startAngle:-M_PI_2 endAngle:3 * M_PI_2 clockwise:YES].CGPath;
    if (_panel) SGRShowGlass([self placePanel], _panelShown);
}

// Goes with the host's controls, in the host's animation: the capsule, the glyph and the ring fade, and an open
// slider goes with them.
- (void)setTucked:(BOOL)tucked {
    _tucked = tucked;
    _pill.alpha = tucked ? 0 : 1;
    _button.alpha = tucked ? 0 : 1;
    [self showRing];
    self.userInteractionEnabled = !tucked;
    if (tucked && _panelShown) [self panelGone];
}

#pragma mark - what Sing is doing

- (void)refresh {
    SGSingState state = SGSingCurrentState();
    // "mic.fill" stands for the capsule's own glyph, the tilted mic with its sparkles (singGlyph); the other
    // states keep a plain symbol that says what they are.
    NSString *glyph = @"mic.fill";
    UIColor *tint = ink();
    CGFloat alpha = 1;
    double progress = -1;   // a ring at a fraction; 2 for a turning one, -1 for none
    switch (state) {
        case SGSingStateUnavailable: glyph = @"mic.slash"; alpha = 0.5; break;
        case SGSingStateNoModel: alpha = 0.7; break;
        case SGSingStateDownloading:
            // Offline, the ring stays where the download stopped and the glyph says why, dimmed like the other
            // states that wait.
            if (SGSingModelWaitingForNetwork()) {
                glyph = @"wifi.slash";
                alpha = 0.7;
            } else {
                glyph = @"arrow.down";
            }
            progress = SGSingModelProgress();
            break;
        case SGSingStateOff: alpha = 0.55; break;
        case SGSingStatePreparing:
        case SGSingStateBuffering: progress = 2; break;
        case SGSingStateWaiting: alpha = 0.7; break;
        case SGSingStateSinging: tint = SGRAccentColor() ?: UIColor.systemGreenColor; break;
        case SGSingStateBehind: glyph = @"tortoise.fill"; break;
        case SGSingStateHot: glyph = @"thermometer.high"; tint = UIColor.systemOrangeColor; break;
        case SGSingStateFailed: glyph = @"exclamationmark.triangle.fill"; tint = UIColor.systemRed; break;
    }
    // One glyph replaces the other in place, as the Kit's download glyph does (none under Reduce Motion),
    // and the color crossfades. Set only on a change: the download's progress refreshes many times a second.
    if (![glyph isEqualToString:_glyph]) {
        _glyph = glyph;
        UIButtonConfiguration *config = _button.configuration;
        if (@available(iOS 26.0, *)) {
            config.symbolContentTransition = SGRReduceMotion() || !self.window ? nil
                : [UISymbolContentTransition transitionWithContentTransition:[NSSymbolReplaceContentTransition replaceDownUpTransition]];
        }
        config.image = [glyph isEqualToString:@"mic.fill"] ? singGlyph() : [UIImage systemImageNamed:glyph];
        _button.configuration = config;
    }
    UIColor *color = [tint colorWithAlphaComponent:alpha];
    if (![color isEqual:_button.tintColor]) {
        if (self.window) SGRAnimate(SGRMotionFade, ^{ self->_button.tintColor = color; }, nil);
        else _button.tintColor = color;
    }

    // A turning ring under Reduce Motion is a quarter of one standing still: repetitive motion is what it asks
    // to be left out.
    _ringShown = progress >= 0;
    BOOL turns = progress > 1 && !SGRReduceMotion();
    if (progress > 1) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        _ring.strokeEnd = 0.25;
        [CATransaction commit];
    } else if (progress >= 0) {
        _ring.strokeEnd = progress;
    }
    if (turns && ![_ring animationForKey:@"turn"]) {
        CABasicAnimation *turn = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
        turn.fromValue = @0;
        turn.toValue = @(2 * M_PI);
        turn.duration = 1;
        turn.repeatCount = HUGE_VALF;
        turn.removedOnCompletion = NO;
        [_ring addAnimation:turn forKey:@"turn"];
    } else if (!turns && progress >= 0) {
        [_ring removeAnimationForKey:@"turn"];
    }
    [self showRing];
}

// The ring fades rather than popping in and out; a turning one keeps turning until it is gone.
- (void)showRing {
    float opacity = _ringShown && !_tucked ? 1 : 0;
    if (_ring.opacity == opacity) return;
    [CATransaction begin];
    [CATransaction setAnimationDuration:SGRCrossfade];
    [CATransaction setCompletionBlock:^{
        if (self->_ring.opacity == 0) [self->_ring removeAnimationForKey:@"turn"];
    }];
    _ring.opacity = opacity;
    [CATransaction commit];
}

#pragma mark - VoiceOver

- (NSString *)accessibilityValue {
    return [NSString stringWithFormat:@"%@. Vocals level: %@", SGSingStatusText(), SGSingLevelText(SGSingLevel())];
}

- (BOOL)accessibilityActivate {
    [self tapped];
    return YES;
}

// Two of the slider's steps at a time, so the whole range is twenty swipes.
- (void)accessibilityIncrement {
    [self stepLevel:1];
}

- (void)accessibilityDecrement {
    [self stepLevel:-1];
}

- (void)stepLevel:(int)direction {
    SGSetSingLevel(roundf((SGSingLevel() + direction * 2 * kLevelStep) / kLevelStep) * kLevelStep);
    if (_panel) {
        _slider.value = SGSingLevel();
        [self showLevel];
    }
}

#pragma mark - the tap

static void tell(NSString *message, NSString *action, void (^then)(void)) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Karaoke" message:message preferredStyle:UIAlertControllerStyleAlert];
    // Over the player, which is dark whatever the system's appearance.
    alert.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    if (action) [alert addAction:[UIAlertAction actionWithTitle:action style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { then(); }]];
    [alert addAction:[UIAlertAction actionWithTitle:action ? @"Cancel" : @"OK" style:UIAlertActionStyleCancel handler:nil]];
    [SGTopController() presentViewController:alert animated:YES completion:nil];
}

- (void)tapped {
    switch (SGSingCurrentState()) {
        case SGSingStateUnavailable:
            tell(SGSingMissing(), nil, nil);
            return;
        case SGSingStateNoModel:
            tell([NSString stringWithFormat:@"Karaoke turns the vocals down with a voice model that runs on this iPhone. Download it now (%@)? It is best over Wi-Fi.%@",
                  SGSingModelSizeText(), SGSingModelError() ? [NSString stringWithFormat:@"\n\nThe last try failed: %@", SGSingModelError()] : @""],
                 @"Download", ^{
                     SGSingDownloadModel();
                     // Downloaded for the mic, so the mic is on once it is in.
                     SGSetSingOn(YES);
                 });
            return;
        case SGSingStateDownloading:
            tell(SGSingStatusDetail(), @"Stop the download", ^{ SGSingCancelModelDownload(); });
            return;
        case SGSingStateFailed:
            tell(SGSingStatusDetail(), @"Turn Karaoke off", ^{ SGSetSingOn(NO); });
            return;
        default:
            SGSetSingOn(!SGSingOn());
    }
}

#pragma mark - the slider

- (void)held:(UILongPressGestureRecognizer *)hold {
    if (hold.state != UIGestureRecognizerStateBegan) return;
    [self showPanel];
}

- (void)showPanel {
    if (!_panel) {
        _panel = [UIView new];
        _panel.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        _panel.layer.anchorPoint = CGPointMake(0.5, 1);   // its bottom edge, over the mic
        _slider = [UISlider new];
        _slider.minimumValue = 0;
        _slider.maximumValue = 2;
        _slider.transform = CGAffineTransformMakeRotation(-M_PI_2);
        _slider.accessibilityLabel = @"Vocals";
        [_slider addTarget:self action:@selector(slid) forControlEvents:UIControlEventValueChanged];
        [_slider addTarget:self action:@selector(holdPanel) forControlEvents:UIControlEventTouchDown];
        [_slider addTarget:self action:@selector(letPanelGo) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
        [_panel addSubview:_slider];
        _mark = [UIView new];
        _mark.backgroundColor = [UIColor colorWithWhite:1 alpha:0.35];
        _mark.userInteractionEnabled = NO;
        [_panel insertSubview:_mark belowSubview:_slider];
        _feedback = [UISelectionFeedbackGenerator new];
        _level = [UILabel new];
        _level.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        _level.textColor = [UIColor colorWithWhite:1 alpha:0.8];
        _level.textAlignment = NSTextAlignmentRight;
        _level.isAccessibilityElement = NO;
        [self addSubview:_panel];
        [self addSubview:_level];
        _slider.alpha = _mark.alpha = _level.alpha = 0;
        SGRShowGlass([self placePanel], NO);
        if (!SGRReduceMotion()) _panel.transform = CGAffineTransformMakeScale(kPanelEnterScale, kPanelEnterScale);
    }
    _slider.minimumTrackTintColor = SGRAccentColor() ?: UIColor.systemGreenColor;
    _slider.value = SGSingLevel();
    [self showLevel];
    UIView *glass = [self placePanel];
    _panelShown = YES;
    // The fade answers the hold at once; the growth is motion, which Reduce Motion leaves out.
    SGRAnimate(SGRMotionRespond, ^{
        SGRShowGlass(glass, YES);
        self->_slider.alpha = self->_mark.alpha = self->_level.alpha = 1;
    }, nil);
    SGRAnimateLayout(self, ^{ self->_panel.transform = CGAffineTransformIdentity; }, nil);
    [self letPanelGo];
}

// Bounds and a center rather than a frame, since the capsule can be under its entering scale.
- (UIView *)placePanel {
    CGFloat width = self.bounds.size.width, top = -kPanelGap - kPanelHeight;
    _panel.bounds = CGRectMake(0, 0, width, kPanelHeight);
    _panel.center = CGPointMake(width / 2, -kPanelGap);
    UIView *glass = SGRGlassCapsuleInside(_panel, &kPanelGlassKey, _panel.bounds.size, NO);
    _slider.bounds = CGRectMake(0, 0, kPanelHeight - 24, 31);
    _slider.center = CGPointMake(width / 2, kPanelHeight / 2);
    // The slider is centered, so As sung, the middle of its range, is the capsule's middle.
    _mark.frame = CGRectMake((width - kMarkWidth) / 2, kPanelHeight / 2 - 0.5, kMarkWidth, 1);
    _level.frame = CGRectMake(width - kLevelWidth, top - kLevelHeight - 4, kLevelWidth, kLevelHeight);
    return glass;
}

- (void)showLevel {
    _level.text = SGSingLevelText(_slider.value);
    _slider.accessibilityValue = _level.text;
}

// Near As sung the thumb holds there, with a tick as it catches; the finger drags it on out of the band.
- (void)slid {
    BOOL caught = fabsf(_slider.value - 1) <= kAsSungCatch;
    if (caught) _slider.value = 1;
    if (caught && !_caught) [_feedback selectionChanged];
    _caught = caught;
    SGSetSingLevel(roundf(_slider.value / kLevelStep) * kLevelStep);
    [self showLevel];
}

- (void)holdPanel {
    [_hide invalidate];
    _hide = nil;
    _caught = fabsf(_slider.value - 1) <= kAsSungCatch;
    [_feedback prepare];
}

- (void)letPanelGo {
    [_hide invalidate];
    __weak SGRSingButton *weakSelf = self;
    _hide = [NSTimer scheduledTimerWithTimeInterval:kPanelStays repeats:NO block:^(NSTimer *timer) { [weakSelf hidePanel]; }];
}

// Out faster than it came, and without shrinking: nothing is watched on its way out.
- (void)hidePanel {
    if (!_panelShown) return;
    SGRAnimate(SGRMotionRespond, ^{ [self panelGone]; }, ^(BOOL finished) {
        if (!self->_panelShown && !SGRReduceMotion()) self->_panel.transform = CGAffineTransformMakeScale(kPanelEnterScale, kPanelEnterScale);
    });
}

// The capsule's glass and the slider gone, in whatever animation the caller has open.
- (void)panelGone {
    _panelShown = NO;
    [_hide invalidate];
    _hide = nil;
    SGRShowGlass(SGRGlassCapsuleInside(_panel, &kPanelGlassKey, _panel.bounds.size, NO), NO);
    _slider.alpha = _mark.alpha = _level.alpha = 0;
}

// The slider sits outside the button's bounds, above it, and takes touches while it shows.
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (_panelShown && CGRectContainsPoint(_panel.frame, point)) return YES;
    return [super pointInside:point withEvent:event];
}

@end
