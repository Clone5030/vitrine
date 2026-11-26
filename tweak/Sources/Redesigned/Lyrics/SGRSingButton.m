#import "Core/SGCore.h"
#import "Settings/SGPageStyle.h"
#import "Shared/Sing/Sing.h"
#import "Redesigned/Kit/SGRAccent.h"
#import "Redesigned/Kit/SGRGlass.h"
#import "Redesigned/Kit/SGRTokens.h"
#import "SGRSingButton.h"

static const CGFloat kGlyph = 17, kRingWidth = 2.5, kRingInset = 1.5;
// The pill the circle grows into, this tall from its bottom edge up, and the level's label over it.
static const CGFloat kPillHeight = 176, kLevelWidth = 120, kLevelHeight = 20, kLevelGap = 6;
static const NSTimeInterval kOpenStays = 4;
// Held, the pill is a little wider; pulled past either end it stretches by up to kStretchMost points, like rubber.
static const CGFloat kHeldWiden = 6, kStretchMost = 24;
static const float kLevelStep = 0.05f;
// As sung (1) holds the level this close either side, 4% of the pill's travel: a detent caught with a tick, as the
// Sing page's tall slider ticks there.
static const float kAsSungCatch = 0.08f;
// The button is a white circle with a dark mic and sparkles on it, as Apple Music's Sing button is, so its
// glyphs are dark. The mic and the sparkles are drawn once into one template image, so the button's tint colors them.
static const CGFloat kPillMicTilt = 40;   // degrees clockwise: the mic's head leans to the upper right

static UIColor *ink(void) {
    return [UIColor colorWithWhite:0.1 alpha:1];
}

static UIImage *singGlyph(void) {
    static UIImage *image;
    if (image) return image;
    CGSize size = CGSizeMake(30, 32);
    UIImage *mic = [UIImage systemImageNamed:@"mic.fill" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:19 weight:UIImageSymbolWeightSemibold]];
    UIImage *big = [UIImage systemImageNamed:@"sparkle" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:10 weight:UIImageSymbolWeightBold]];
    UIImage *small = [UIImage systemImageNamed:@"sparkle" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:7 weight:UIImageSymbolWeightBold]];
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    UIImage *drawn = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGContextRef c = context.CGContext;
        CGContextSaveGState(c);
        CGContextTranslateCTM(c, size.width / 2, size.height / 2 + 0.5);
        CGContextRotateCTM(c, kPillMicTilt * M_PI / 180);
        [[mic imageWithTintColor:UIColor.blackColor renderingMode:UIImageRenderingModeAlwaysOriginal] drawInRect:CGRectMake(-mic.size.width / 2, -mic.size.height / 2, mic.size.width, mic.size.height)];
        CGContextRestoreGState(c);
        [[big imageWithTintColor:UIColor.blackColor renderingMode:UIImageRenderingModeAlwaysOriginal] drawInRect:CGRectMake(0, 1, big.size.width, big.size.height)];
        [[small imageWithTintColor:UIColor.blackColor renderingMode:UIImageRenderingModeAlwaysOriginal] drawInRect:CGRectMake(size.width - small.size.width - 0.5, size.height - small.size.height - 1.5, small.size.width, small.size.height)];
    }];
    image = [drawn imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    return image;
}

@implementation SGRSingButton {
    UIView *_track;      // the dark capsule behind the pill, as tall as the pill when it is open
    UIView *_fill;       // the white capsule: the circle itself, growing up with the level when it is open
    UIButton *_button;   // holds no glass, so its alpha is free to fade
    CAShapeLayer *_ring;
    BOOL _ringShown;
    NSString *_glyph;
    UIPanGestureRecognizer *_pan;
    UISelectionFeedbackGenerator *_feedback;
    BOOL _caught;        // the level is held at As sung
    float _panStart;     // the level when the finger came down
    UILabel *_level;
    NSTimer *_hide;
    BOOL _open;
    CGFloat _stretch;    // points the pill is pulled past its top (+) or its bottom (-) by a finger beyond the ends
    CGFloat _widen;      // points the pill is wider than the circle while a finger holds it
    CGFloat _placedSide; // the circle's side the shapes were last laid out for
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    // A circle with a mic. A tap grows it into a pill that a finger drags up and down to set the mix; no glass,
    // so everything fades by its alpha when the controls go.
    _track = [UIView new];
    // Open, a glass pill in the screen's own colors: the track a light tint over them with a fine edge, the level
    // a lighter fill in it, and the mic white. Closed, the fill is the white circle and the mic dark on it.
    _track.backgroundColor = [UIColor colorWithWhite:1 alpha:0.2];
    _track.layer.borderWidth = 1;
    _track.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.3].CGColor;
    _track.layer.cornerCurve = kCACornerCurveContinuous;
    _track.userInteractionEnabled = NO;
    _track.alpha = 0;
    [self addSubview:_track];
    _fill = [UIView new];
    _fill.backgroundColor = UIColor.whiteColor;
    _fill.layer.cornerCurve = kCACornerCurveContinuous;
    _fill.userInteractionEnabled = NO;
    [self addSubview:_fill];

    UIButtonConfiguration *config = [UIButtonConfiguration plainButtonConfiguration];
    config.preferredSymbolConfigurationForImage = [UIImageSymbolConfiguration configurationWithPointSize:kGlyph weight:UIImageSymbolWeightSemibold];
    _button = [UIButton buttonWithConfiguration:config primaryAction:nil];
    // Light, so the glyph's dark ink reads on the white whatever the system's appearance is.
    _button.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    _button.tintColor = ink();
    _button.isAccessibilityElement = NO;
    [_button addTarget:self action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_button];

    _pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panned:)];
    _pan.maximumNumberOfTouches = 1;
    [self addGestureRecognizer:_pan];
    _feedback = [UISelectionFeedbackGenerator new];

    _level = [UILabel new];
    _level.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    _level.textColor = [UIColor colorWithWhite:1 alpha:0.8];
    _level.textAlignment = NSTextAlignmentRight;
    _level.isAccessibilityElement = NO;
    _level.alpha = 0;
    [self addSubview:_level];

    // VoiceOver has the mic itself as one adjustable button: the pill shows only for a finger and goes again
    // on a timer, which a swipe up or down never holds open.
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

#pragma mark - the circle and the pill

// The circle's side, which is the pill's width: the host gives the button a square.
- (CGFloat)side {
    return self.bounds.size.width;
}

// The shapes are laid out by frames, so nothing here may run under a transform. A finger beyond the ends stretches
// them (_stretch) and a held pill is wider (_widen); both come back by themselves with a spring.
- (CGRect)trackFrame {
    CGFloat side = [self side];
    if (!_open) return CGRectMake(0, 0, side, side);
    CGFloat up = MAX(0, _stretch), down = MAX(0, -_stretch);
    return CGRectMake(-_widen / 2, side - kPillHeight - up, side + _widen, kPillHeight + up + down);
}

// White from the bottom up: the circle at its least, the whole pill at the vocals alone.
- (CGRect)fillFrame {
    CGFloat side = [self side];
    if (!_open) return CGRectMake(0, 0, side, side);
    float level = MAX(0, MIN(2, SGSingLevel()));
    CGFloat height = side + (kPillHeight - side) * level / 2;
    CGFloat up = MAX(0, _stretch), down = MAX(0, -_stretch);
    return CGRectMake(-_widen / 2, side - height - up, side + _widen, height + up + down);
}

- (CGRect)levelFrame {
    CGFloat side = [self side];
    return CGRectMake(side - kLevelWidth, side - kPillHeight - kLevelHeight - kLevelGap, kLevelWidth, kLevelHeight);
}

// Every shape where the state puts it. Called inside an animation it moves them with it; the corner radius
// follows the width so a held pill stays a capsule.
- (void)applyShape {
    CGFloat radius = ([self side] + (_open ? _widen : 0)) / 2;
    _track.layer.cornerRadius = radius;
    _fill.layer.cornerRadius = radius;
    // In the open pill, the moving level is a flat horizontal edge. Keep only the bottom corners
    // rounded so the fill still follows the capsule at its base; the closed mic remains a circle.
    _fill.layer.maskedCorners = _open
        ? (kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner)
        : (kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner | kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner);
    _track.frame = [self trackFrame];
    _fill.frame = [self fillFrame];
    _level.frame = [self levelFrame];
}

// The pill follows the level and the finger on a spring with a little bounce, so it trails the finger and settles
// like something with weight, rather than jumping to each value.
- (void)followFill {
    if (!_open) return;
    // Already headed there (the frames read back as the animation's end): nothing to start, as the download's
    // many refreshes ask.
    if (CGRectEqualToRect(_fill.frame, [self fillFrame]) && CGRectEqualToRect(_track.frame, [self trackFrame]) &&
        _track.layer.cornerRadius == ([self side] + _widen) / 2) return;
    SGRAnimate(SGRMotionPress, ^{ [self applyShape]; }, nil);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    _button.frame = bounds;
    // Placed for a new size only: a layout pass in the middle of the pill's spring would cut it short.
    if (fabs([self side] - _placedSide) > 0.5) {
        _placedSide = [self side];
        [self applyShape];
    }
    _ring.frame = bounds;
    // A circle around the mic, which turns about its centre. Starting at the top and running clockwise, as a
    // download ring does.
    CGFloat radius = MIN(bounds.size.width, bounds.size.height) / 2 - kRingInset - kRingWidth / 2;
    _ring.path = [UIBezierPath bezierPathWithArcCenter:CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds)) radius:radius
                                            startAngle:-M_PI_2 endAngle:3 * M_PI_2 clockwise:YES].CGPath;
}

// Open or closed, in whatever animation the caller has open, or in one of its own.
// Opening is a spring with a little bounce, growing up out of the circle; closing is a spring with none, drawing back
// into it. Only the end state is set before the animation, so nothing jumps ahead of it.
- (void)setOpen:(BOOL)open animated:(BOOL)animated {
    if (_open == open) return;
    _open = open;
    _stretch = 0;
    _widen = 0;
    [_hide invalidate];
    _hide = nil;
    if (open) _level.text = SGSingLevelText(SGSingLevel());
    void (^change)(void) = ^{
        self->_track.alpha = open ? 1 : 0;
        self->_level.alpha = open ? 1 : 0;
        self->_fill.backgroundColor = open ? [UIColor colorWithWhite:1 alpha:0.45] : UIColor.whiteColor;
        self->_ring.strokeColor = (open ? UIColor.whiteColor : ink()).CGColor;
        [self applyShape];
    };
    if (animated) SGRAnimate(open ? SGRMotionPress : SGRMotionLayout, change, nil);
    else [UIView performWithoutAnimation:change];
    [self refresh];   // the mic's color: white on the glass, dark on the white circle
    if (open) [self letGo];
}

// Goes with the host's controls, in the host's animation: the circle, the glyph and the ring fade, and an open
// pill goes with them.
- (void)setTucked:(BOOL)tucked {
    _tucked = tucked;
    if (tucked) [self setOpen:NO animated:NO];
    _fill.alpha = tucked ? 0 : 1;
    _button.alpha = tucked ? 0 : 1;
    [self showRing];
    self.userInteractionEnabled = !tucked;
}

// The level's words and the white's height, which follow the level wherever it is set from.
- (void)updateLevel {
    _level.text = SGSingLevelText(SGSingLevel());
    [self followFill];
}

#pragma mark - what Sing is doing

- (void)refresh {
    SGSingState state = SGSingCurrentState();
    // "mic.fill" stands for the circle's own glyph, the tilted mic with its sparkles (singGlyph); the other
    // states keep a plain symbol that says what they are.
    NSString *glyph = @"mic.fill";
    UIColor *tint = _open ? UIColor.whiteColor : ink();
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
        case SGSingStateFailed: glyph = @"exclamationmark.triangle.fill"; tint = UIColor.systemRedColor; break;
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
    [self updateLevel];
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
    [self updateLevel];
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

// The circle opens into the pill, turning Karaoke on if it is off; the mic at the foot of the open pill puts
// it away again, turning Karaoke off. Where Karaoke cannot run yet, a tap says what is missing instead.
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
            break;
    }
    if (_open) {
        SGSetSingOn(NO);
        [self setOpen:NO animated:YES];
    } else {
        if (!SGSingOn()) SGSetSingOn(YES);
        [self setOpen:YES animated:YES];
    }
}

#pragma mark - the drag

// Up is more of the voice and down is more of the music: the vocals alone at the top, the song as sung in the
// middle, the music alone at the bottom. The level follows the finger by how far it has moved, so a touch
// anywhere on the pill picks up where it is.
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)recognizer {
    if (recognizer == _pan) return _open;
    return [super gestureRecognizerShouldBegin:recognizer];
}

- (void)panned:(UIPanGestureRecognizer *)pan {
    switch (pan.state) {
        case UIGestureRecognizerStateBegan:
            [_hide invalidate];
            _hide = nil;
            _panStart = SGSingLevel();
            _caught = fabsf(_panStart - 1) <= kAsSungCatch;
            [_feedback prepare];
            // Held, the pill swells a little, as a pressed thing does.
            _widen = kHeldWiden;
            [self followFill];
            break;
        case UIGestureRecognizerStateChanged: {
            CGFloat travel = MAX(1, kPillHeight - [self side]);
            float raw = _panStart - (float)([pan translationInView:self].y / travel) * 2;
            // A finger beyond the top or the bottom stretches the pill like rubber, harder the further it goes.
            float over = raw > 2 ? raw - 2 : (raw < 0 ? raw : 0);
            _stretch = over == 0 ? 0 : copysign(kStretchMost * (1 - expf(-fabsf(over) * 2.2f)), over);
            raw = MAX(0, MIN(2, raw));
            BOOL caught = fabsf(raw - 1) <= kAsSungCatch;
            float level = caught ? 1 : raw;
            if (caught && !_caught) [_feedback selectionChanged];
            _caught = caught;
            SGSetSingLevel(roundf(level / kLevelStep) * kLevelStep);
            [self updateLevel];
            break;
        }
        default:
            // Let go, it springs back to its width and its length, with a bounce.
            _widen = 0;
            _stretch = 0;
            [self followFill];
            [self letGo];
            break;
    }
}

// The pill closes itself after a while without a touch, leaving Karaoke as it is set.
- (void)letGo {
    [_hide invalidate];
    __weak SGRSingButton *weakSelf = self;
    _hide = [NSTimer scheduledTimerWithTimeInterval:kOpenStays repeats:NO block:^(NSTimer *timer) { [weakSelf setOpen:NO animated:YES]; }];
}

// The open pill reaches above the circle's own bounds, and takes touches there while it shows.
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    CGRect reach = _open ? CGRectUnion(self.bounds, _track.frame) : self.bounds;
    return CGRectContainsPoint(reach, point);
}

@end
