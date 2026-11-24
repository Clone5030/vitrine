// Player redesign: the lyrics turn sideways with the phone onto a landscape screen of their own. The cover
// is on the left with the title, the artist and the controls under it, and the lines are on the right.
// A track without lines keeps the screen: the cover grows to the screen's height with the title and the
// controls beside it, until a track with lines comes on.
// The controls fade after a few seconds without a touch and come back at a tap, as in the player: the
// tap that brings them back lands on a clear shield over the screen, so it never seeks. The button beside
// the title turns the screen back to portrait, as VoiceOver's escape does, for a phone held flat or on its
// side; the screen stays shut then until the phone has stood upright again.
//
// A track with animated artwork (the clip the portrait player plays, PlayerMotion.x) gets a left panel in place of
// the square cover: the clip fills the left half of the screen from edge to edge, playing, and melts into the
// field's blur on its right, which is the same artwork enlarged. A long press on the panel opens its adjustment:
// drag to move, pinch to zoom, Reset, and a tap to finish. The adjustment is kept for the clip's file, which is
// the artwork's own (the store names a file by its address), so it comes back with that artwork on any song,
// screen size and launch. A track with a still cover keeps the square cover; the panel is off while the track
// has no lines, when the cover takes the screen.
//
// Spotify's iPhone Info.plist allows portrait only, and UIKit asks the app delegate's
// -application:supportedInterfaceOrientationsForWindow: in its place where there is one. So the delegate
// answers landscape for this screen's own window and portrait for every other, and the scene is asked to
// turn while the window is up. Spotify's own windows never turn.
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Redesigned/Lyrics/SGRKaraokeView.h"
#import "Shared/AnimatedArtwork/AnimatedArtwork.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/Player/PlayerState.h"
#import "Player.h"

static const CGFloat kSide = 32, kCoverGap = 16, kControlSide = 44, kColumnShare = 0.38;
// The title and the controls beside the cover of a track without lines.
static const CGFloat kBareInfoWidth = 300, kBareControlsWidth = 200;
static const NSTimeInterval kLandscapeRest = 4;
// The seek line over the panel's foot: its height with the times under it.
static const CGFloat kSeekHeight = 40;

// The animated artwork's panel: its share of the screen's width, where its right edge starts to melt into the field,
// and how far the pinch goes either way.
static const CGFloat kPanelShare = 0.5, kMeltFrom = 0.78, kZoomLeast = 0.5, kZoomMost = 4;
// The adjustments kept, by clip file: {file name: [zoom, x, y]}, x and y in panels' widths and heights from centered.
static NSString *const kAdjustmentsKey = @"spotifyglass.redesign.landscape.artwork";

static BOOL adjustmentIsRest(CGFloat zoom, CGFloat x, CGFloat y) {
    return fabs(zoom - 1) < 0.001 && fabs(x) < 0.001 && fabs(y) < 0.001;
}

static void loadAdjustment(NSURL *file, CGFloat *zoom, CGFloat *x, CGFloat *y) {
    *zoom = 1;
    *x = 0;
    *y = 0;
    NSDictionary *all = [NSUserDefaults.standardUserDefaults dictionaryForKey:kAdjustmentsKey];
    NSArray *kept = [all[file.lastPathComponent] isKindOfClass:NSArray.class] ? all[file.lastPathComponent] : nil;
    if (kept.count != 3) return;
    *zoom = MIN(kZoomMost, MAX(kZoomLeast, [kept[0] doubleValue]));
    *x = [kept[1] doubleValue];
    *y = [kept[2] doubleValue];
}

static void saveAdjustment(NSURL *file, CGFloat zoom, CGFloat x, CGFloat y) {
    NSMutableDictionary *all = [[NSUserDefaults.standardUserDefaults dictionaryForKey:kAdjustmentsKey] mutableCopy] ?: [NSMutableDictionary dictionary];
    if (adjustmentIsRest(zoom, x, y)) [all removeObjectForKey:file.lastPathComponent];
    else all[file.lastPathComponent] = @[@(zoom), @(x), @(y)];
    [NSUserDefaults.standardUserDefaults setObject:all forKey:kAdjustmentsKey];
}

#pragma mark - the clip's view

// The clip filled into the panel, then zoomed about the middle and moved. Its own player, muted and looped, on the
// same local file as the portrait player's; the poster is the layer's contents until the video has a frame.
@interface SGRLandscapeClip : UIView
@property (nonatomic) CGFloat zoom, x, y;
- (void)playFile:(NSURL *)file poster:(UIImage *)poster;
- (void)setPlaying:(BOOL)playing;
- (void)stop;
@end

@implementation SGRLandscapeClip {
    AVQueuePlayer *_player;
    AVPlayerLooper *_looper;
    CALayer *_still;
    AVPlayerLayer *_video;
    CGSize _natural;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.clipsToBounds = YES;
    self.userInteractionEnabled = NO;
    _zoom = 1;
    _still = [CALayer layer];
    _still.contentsGravity = kCAGravityResizeAspectFill;
    _still.masksToBounds = YES;
    _video = [AVPlayerLayer layer];
    _video.videoGravity = AVLayerVideoGravityResizeAspectFill;
    [_still addSublayer:_video];
    [self.layer addSublayer:_still];
    return self;
}

- (void)playFile:(NSURL *)file poster:(UIImage *)poster {
    [self stop];
    _natural = poster.size;
    _still.contents = (__bridge id)poster.CGImage;
    _player = [AVQueuePlayer new];
    _player.muted = YES;
    _player.preventsDisplaySleepDuringVideoPlayback = NO;
    _looper = [AVPlayerLooper playerLooperWithPlayer:_player templateItem:[AVPlayerItem playerItemWithURL:file]];
    _video.player = _player;
    [self setNeedsLayout];
}

- (void)setPlaying:(BOOL)playing {
    if (playing && self.window) [_player play];
    else [_player pause];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) [_player pause];
}

- (void)stop {
    [_player pause];
    _video.player = nil;
    _looper = nil;
    _player = nil;
}

- (void)setZoom:(CGFloat)zoom {
    _zoom = MIN(kZoomMost, MAX(kZoomLeast, zoom));
    [self setNeedsLayout];
}

// The picture's size in the panel: filled at a zoom of 1.
- (CGSize)shown {
    CGSize panel = self.bounds.size;
    if (_natural.width <= 0 || _natural.height <= 0 || panel.width <= 0 || panel.height <= 0) return panel;
    CGFloat fill = MAX(panel.width / _natural.width, panel.height / _natural.height) * _zoom;
    return CGSizeMake(_natural.width * fill, _natural.height * fill);
}

// The most the picture may move either way: while it is larger than the panel, until its edge meets the panel's;
// smaller, until it meets the panel's edge from inside.
- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize panel = self.bounds.size, shown = [self shown];
    if (panel.width <= 0 || panel.height <= 0) return;
    CGFloat reachX = fabs(shown.width - panel.width) / 2 / panel.width, reachY = fabs(shown.height - panel.height) / 2 / panel.height;
    _x = MIN(reachX, MAX(-reachX, _x));
    _y = MIN(reachY, MAX(-reachY, _y));
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _still.bounds = CGRectMake(0, 0, shown.width, shown.height);
    _still.position = CGPointMake(panel.width / 2 + _x * panel.width, panel.height / 2 + _y * panel.height);
    _video.frame = _still.bounds;
    [CATransaction commit];
}

@end

static UIWindow *sg_window;
// Shut from the screen: turning the phone again does not reopen it until it has stood upright.
static BOOL sg_shut;

#pragma mark - the screen

@interface SGRLandscapeLyricsController : UIViewController <SGPlayerStateObserver, UIGestureRecognizerDelegate>
@end

@implementation SGRLandscapeLyricsController {
    SGRArtworkField *_field;
    UIImageView *_cover;
    SGMarqueeLabel *_title, *_artist;
    UIStackView *_controls;
    UIButton *_play, *_close;
    UIView *_stage;   // the lines' own view: the karaoke view dims every sibling it has
    SGRKaraokeView *_lyrics;
    NSTimer *_rest;
    UITapGestureRecognizer *_hide;   // only while the controls are up
    UIView *_shield;                 // only while they are not: the touch that brings them back
    BOOL _bare;                      // the track playing has no lines: the cover takes the screen
    // Animated artwork: the panel, its clip, the file playing, and the adjustment.
    UIView *_panel;
    SGRLandscapeClip *_clipView;
    CAGradientLayer *_melt, *_shade;
    NSURL *_clipFile;
    UIView *_adjustFrame, *_hint, *_resetPill;
    UIPanGestureRecognizer *_drag;
    UIPinchGestureRecognizer *_pinch;
    UITapGestureRecognizer *_finish;
    BOOL _adjusting;
    BOOL _clipReady;   // the poster is in and the clip plays
    // The seek line, with the panel: the track, how far it has played, and the two times.
    UIView *_seek, *_seekTrack, *_seekFill;
    UILabel *_elapsed, *_remaining;
    BOOL _scrubbing;
    CFTimeInterval _heldUntil;   // a seek just made is shown until the player's report has caught up
}

// Portrait once the screen is on its way out, or the scene could not turn back while it fades.
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return sg_window.rootViewController == self ? UIInterfaceOrientationMaskLandscape : UIInterfaceOrientationMaskPortrait;
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (BOOL)prefersHomeIndicatorAutoHidden {
    return YES;
}

// A glyph in a 44pt square, so the touch is as large as the default control whatever the glyph's size.
static UIButton *controlButton(NSString *symbol, CGFloat size, NSString *label, SEL action, id target) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setImage:[UIImage systemImageNamed:symbol withConfiguration:
        [UIImageSymbolConfiguration configurationWithPointSize:size weight:UIImageSymbolWeightBold]] forState:UIControlStateNormal];
    button.tintColor = UIColor.whiteColor;
    button.accessibilityLabel = label;
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    [button.widthAnchor constraintEqualToConstant:kControlSide].active = YES;
    [button.heightAnchor constraintEqualToConstant:kControlSide].active = YES;
    return button;
}

// The title and the artist at the phone's text size, capped where the column still holds a cover.
- (void)applyFonts {
    _title.font = SGRFont(UIFontTextStyleTitle3, UIFontWeightBold, UIContentSizeCategoryExtraExtraExtraLarge);
    _artist.font = SGRFont(UIFontTextStyleCallout, UIFontWeightRegular, UIContentSizeCategoryExtraExtraExtraLarge);
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    [self applyFonts];
    [self.view setNeedsLayout];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;

    // The player's own field behind the screen, so the colors carry over from the portrait player.
    _field = [[SGRArtworkField alloc] initWithFrame:self.view.bounds];
    _field.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _field.showsBackdrop = YES;
    _field.fluid = YES;
    NSString *identity = nil;
    UIImage *art = SGRNowPlayingArtwork(NULL, &identity);
    if (art) [_field setArtwork:art identity:identity animated:NO];
    [self.view addSubview:_field];

    _panel = [UIView new];
    _panel.hidden = YES;
    _panel.clipsToBounds = YES;
    _clipView = [[SGRLandscapeClip alloc] initWithFrame:CGRectZero];
    [_panel addSubview:_clipView];
    // The foot is darkened for the title and the controls over it; the right edge melts into the field.
    _shade = [CAGradientLayer layer];
    _shade.colors = @[(id)UIColor.clearColor.CGColor, (id)[UIColor colorWithWhite:0 alpha:0.6].CGColor];
    _shade.startPoint = CGPointMake(0.5, 0.45);
    _shade.endPoint = CGPointMake(0.5, 1);
    [_panel.layer addSublayer:_shade];
    _melt = [CAGradientLayer layer];
    _melt.colors = @[(id)UIColor.blackColor.CGColor, (id)UIColor.blackColor.CGColor, (id)UIColor.clearColor.CGColor];
    _melt.locations = @[@0, @(kMeltFrom), @1];
    _melt.startPoint = CGPointMake(0, 0.5);
    _melt.endPoint = CGPointMake(1, 0.5);
    _panel.layer.mask = _melt;
    [self.view addSubview:_panel];
    [self addAdjustment];

    _cover = [UIImageView new];
    _cover.contentMode = UIViewContentModeScaleAspectFill;
    _cover.clipsToBounds = YES;
    _cover.layer.cornerRadius = SGRRadiusArtwork;
    _cover.layer.cornerCurve = kCACornerCurveContinuous;
    _cover.image = art;
    [self.view addSubview:_cover];

    // A title or artist too long for the column scrolls, as the player's own do.
    _title = [SGMarqueeLabel new];
    _title.textColor = UIColor.whiteColor;
    _artist = [SGMarqueeLabel new];
    _artist.textColor = [UIColor colorWithWhite:1 alpha:0.6];
    [self applyFonts];
    [self.view addSubview:_title];
    [self.view addSubview:_artist];
    // Where the Music app keeps a song's ⋯: the way back to the player, for a phone that is not turned back.
    _close = controlButton(@"arrow.down.right.and.arrow.up.left", 17, @"Exit full screen", @selector(turnBack), self);
    [self.view addSubview:_close];

    _play = controlButton(@"pause.fill", 30, @"Pause", @selector(togglePlay), self);
    _controls = [[UIStackView alloc] initWithArrangedSubviews:@[
        controlButton(@"backward.fill", 24, @"Previous track", @selector(previous), self), _play,
        controlButton(@"forward.fill", 24, @"Next track", @selector(next), self),
    ]];
    _controls.distribution = UIStackViewDistributionEqualSpacing;
    _controls.alignment = UIStackViewAlignmentCenter;
    [self.view addSubview:_controls];

    [self addSeek];

    _stage = [UIView new];
    [self.view addSubview:_stage];
    _lyrics = [[SGRKaraokeView alloc] initWithFrame:CGRectZero];
    _lyrics.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_stage addSubview:_lyrics];
    __weak SGRLandscapeLyricsController *weakSelf = self;
    _lyrics.browsingBegan = ^{ [weakSelf rest]; };

    _hide = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(rest)];
    _hide.delegate = self;
    [self.view addGestureRecognizer:_hide];
    _shield = [[UIView alloc] initWithFrame:self.view.bounds];
    _shield.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _shield.accessibilityElementsHidden = YES;
    [_shield addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(wake)]];
    [_shield addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(wake)]];
    [self updateBare:YES];
    [self reloadClip];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reloadClip) name:SGRPlayerMotionDidChangeNotification object:nil];
    SGAddPlayerStateObserver(self);
    [self playerStateDidChange:SGPlayerState()];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(artworkChanged)
                                               name:SGRNowPlayingArtworkDidChangeNotification object:nil];
    // The shield is hidden from VoiceOver, so turning it on brings the controls back and keeps them.
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(wake)
                                               name:UIAccessibilityVoiceOverStatusDidChangeNotification object:nil];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_rest invalidate];
    [_clipView stop];
}

#pragma mark - the seek line

static NSString *clock(double seconds) {
    NSInteger whole = MAX(0, (NSInteger)llround(seconds));
    return [NSString stringWithFormat:@"%ld:%02ld", (long)(whole / 60), (long)(whole % 60)];
}

// A line to jump about the song with, as the player's slider is: a tap goes there, a drag moves along it, and
// the song seeks when the finger lets go. The times are under it. It follows the player a few times a second.
- (void)addSeek {
    _seek = [UIView new];
    _seek.hidden = YES;
    _seekTrack = [UIView new];
    _seekTrack.backgroundColor = [UIColor colorWithWhite:1 alpha:0.28];
    _seekTrack.clipsToBounds = YES;
    _seekTrack.userInteractionEnabled = NO;
    _seekFill = [UIView new];
    _seekFill.backgroundColor = UIColor.whiteColor;
    [_seekTrack addSubview:_seekFill];
    [_seek addSubview:_seekTrack];
    for (UILabel *label in @[_elapsed = [UILabel new], _remaining = [UILabel new]]) {
        label.font = SGRMonospacedDigitsFont([UIFont systemFontOfSize:12 weight:UIFontWeightMedium]);
        label.textColor = [UIColor colorWithWhite:1 alpha:0.6];
        label.userInteractionEnabled = NO;
        [_seek addSubview:label];
    }
    _remaining.textAlignment = NSTextAlignmentRight;
    _seek.isAccessibilityElement = YES;
    _seek.accessibilityLabel = @"Position";
    [_seek addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(scrubbed:)]];
    [_seek addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(seekTapped:)]];
    [self.view addSubview:_seek];
    __weak SGRLandscapeLyricsController *weakSelf = self;
    [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *timer) {
        SGRLandscapeLyricsController *strongSelf = weakSelf;
        if (!strongSelf) [timer invalidate];
        else [strongSelf updateSeek];
    }];
}

- (void)layoutSeek {
    CGFloat width = _seek.bounds.size.width;
    _seekTrack.frame = CGRectMake(0, 8, width, 4);
    _seekTrack.layer.cornerRadius = 2;
    _elapsed.frame = CGRectMake(0, 20, width / 2, 16);
    _remaining.frame = CGRectMake(width / 2, 20, width / 2, 16);
    [self updateSeek];
}

// Where the song is, or where a finger holds the line.
- (void)updateSeek {
    if (_seek.hidden || _scrubbing || CACurrentMediaTime() < _heldUntil) return;
    SPTPlayerState *state = SGPlayerState();
    double duration = state.duration, position = MIN(MAX(0, state.position), duration);
    [self showSeekShare:duration > 0 ? position / duration : 0 of:duration];
}

- (void)showSeekShare:(double)share of:(double)duration {
    share = MIN(1, MAX(0, share));
    _seekFill.frame = CGRectMake(0, 0, round(_seekTrack.bounds.size.width * share), _seekTrack.bounds.size.height);
    _elapsed.text = clock(share * duration);
    _remaining.text = [@"-" stringByAppendingString:clock((1 - share) * duration)];
    _seek.accessibilityValue = [NSString stringWithFormat:@"%@ of %@", clock(share * duration), clock(duration)];
}

- (double)seekShareAt:(CGPoint)point {
    return _seek.bounds.size.width > 0 ? MIN(1, MAX(0, point.x / _seek.bounds.size.width)) : 0;
}

- (void)seekToShare:(double)share {
    double duration = SGPlayerState().duration;
    if (duration <= 0) return;
    [self.player seekTo:share * duration];
    _heldUntil = CACurrentMediaTime() + 0.8;
    [self showSeekShare:share of:duration];
    [self restartRest];
}

- (void)seekTapped:(UITapGestureRecognizer *)tap {
    if (tap.state == UIGestureRecognizerStateEnded) [self seekToShare:[self seekShareAt:[tap locationInView:_seek]]];
}

- (void)scrubbed:(UIPanGestureRecognizer *)pan {
    double share = [self seekShareAt:[pan locationInView:_seek]], duration = SGPlayerState().duration;
    switch (pan.state) {
        case UIGestureRecognizerStateBegan:
        case UIGestureRecognizerStateChanged:
            _scrubbing = YES;
            [_rest invalidate];
            _rest = nil;
            [self showSeekShare:share of:duration];
            break;
        case UIGestureRecognizerStateEnded:
            _scrubbing = NO;
            [self seekToShare:share];
            break;
        default:
            _scrubbing = NO;
            break;
    }
}

#pragma mark - animated artwork

// A pill of the screen's own dark glass: the hint, and Reset.
static UIView *pillView(UIView *content, UIEdgeInsets insets) {
    UIView *pill = [UIView new];
    pill.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.78];
    pill.layer.cornerCurve = kCACornerCurveContinuous;
    CGSize size = [content sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)];
    pill.bounds = CGRectMake(0, 0, ceil(size.width) + insets.left + insets.right, ceil(size.height) + insets.top + insets.bottom);
    pill.layer.cornerRadius = pill.bounds.size.height / 2;
    content.frame = CGRectMake(insets.left, insets.top, ceil(size.width), ceil(size.height));
    [pill addSubview:content];
    return pill;
}

- (void)addAdjustment {
    // The panel's outline while it is being adjusted, and the two pills over the top of the screen.
    _adjustFrame = [UIView new];
    _adjustFrame.userInteractionEnabled = NO;
    _adjustFrame.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.85].CGColor;
    _adjustFrame.layer.borderWidth = 2;
    _adjustFrame.layer.cornerRadius = 28;
    _adjustFrame.layer.cornerCurve = kCACornerCurveContinuous;
    _adjustFrame.alpha = 0;
    [self.view addSubview:_adjustFrame];

    UILabel *hint = [UILabel new];
    hint.text = @"Drag to move · Pinch to zoom · Tap to finish";
    hint.textColor = UIColor.whiteColor;
    hint.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    _hint = pillView(hint, UIEdgeInsetsMake(10, 18, 10, 18));
    _hint.userInteractionEnabled = NO;
    _hint.alpha = 0;
    [self.view addSubview:_hint];

    UIButton *reset = [UIButton buttonWithType:UIButtonTypeSystem];
    [reset setTitle:@"Reset" forState:UIControlStateNormal];
    reset.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    reset.tintColor = UIColor.whiteColor;
    [reset addTarget:self action:@selector(resetAdjustment) forControlEvents:UIControlEventTouchUpInside];
    _resetPill = pillView(reset, UIEdgeInsetsMake(10, 18, 10, 18));
    _resetPill.alpha = 0;
    _resetPill.userInteractionEnabled = NO;
    [self.view addSubview:_resetPill];

    // On the whole screen, which sees the touch the controls and the shield would otherwise keep from it.
    UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(pressed:)];
    press.cancelsTouchesInView = NO;
    [self.view addGestureRecognizer:press];
    _drag = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragged:)];
    _drag.maximumNumberOfTouches = 2;
    _pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(pinched:)];
    _finish = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(finishAdjusting)];
    for (UIGestureRecognizer *recognizer in @[_drag, _pinch, _finish]) {
        recognizer.enabled = NO;
        recognizer.delegate = self;
        [_panel addGestureRecognizer:recognizer];
    }
}

// A touch on the seek line is its own: it must not also put the controls away.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldReceiveTouch:(UITouch *)touch {
    return gesture != _hide || ![touch.view isDescendantOfView:_seek];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return (gesture == _drag && other == _pinch) || (gesture == _pinch && other == _drag);
}

// The panel's clip is the playing track's, or none. The clip is read back into the panel here, with the
// adjustment kept for its file; a track with a still cover (or none) puts the square cover back.
- (void)reloadClip {
    NSURL *file = SGRPlayerMotionClip();
    if ([file isEqual:_clipFile] || (!file && !_clipFile)) return;
    if (_adjusting) [self setAdjusting:NO];
    _clipFile = file;
    _clipReady = NO;
    if (!file) {
        [_clipView stop];
        [self.view setNeedsLayout];
        return;
    }
    __weak SGRLandscapeLyricsController *weakSelf = self;
    SGMotionPoster(file, ^(UIImage *poster) {
        SGRLandscapeLyricsController *strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf->_clipFile isEqual:file] || !poster || poster.size.width <= 0) return;
        CGFloat zoom, x, y;
        loadAdjustment(file, &zoom, &x, &y);
        strongSelf->_clipView.zoom = zoom;
        strongSelf->_clipView.x = x;
        strongSelf->_clipView.y = y;
        [strongSelf->_clipView playFile:file poster:poster];
        strongSelf->_clipReady = YES;
        [strongSelf updateClipPlaying];
        SGLog(@"redesign player: landscape animated artwork %@, zoom %.2f", file.lastPathComponent, zoom);
        [strongSelf.view setNeedsLayout];
    });
}

- (BOOL)clipShown {
    return _clipFile && _clipReady && !_bare;
}

- (void)updateClipPlaying {
    BOOL may = !SGPlayerState().isPaused && !SGRReduceMotion() && !NSProcessInfo.processInfo.lowPowerModeEnabled;
    [_clipView setPlaying:may];
}

- (void)pressed:(UILongPressGestureRecognizer *)press {
    if (press.state != UIGestureRecognizerStateBegan || _adjusting || ![self clipShown]) return;
    if (!CGRectContainsPoint(_panel.bounds, [press locationInView:_panel])) return;
    [[UIImpactFeedbackGenerator new] impactOccurred];
    [self setAdjusting:YES];
}

- (void)setAdjusting:(BOOL)adjusting {
    if (adjusting == _adjusting) return;
    _adjusting = adjusting;
    _drag.enabled = _pinch.enabled = _finish.enabled = adjusting;
    _resetPill.userInteractionEnabled = adjusting;
    [_rest invalidate];
    _rest = nil;
    if (adjusting) {
        // Over the lines, which reach under Reset.
        for (UIView *view in @[_adjustFrame, _hint, _resetPill]) [self.view bringSubviewToFront:view];
        [self setControlsShown:YES];
    } else {
        saveAdjustment(_clipFile, _clipView.zoom, _clipView.x, _clipView.y);
        [self restartRest];
    }
    SGRAnimate(SGRMotionRespond, ^{
        self->_adjustFrame.alpha = self->_hint.alpha = self->_resetPill.alpha = adjusting ? 1 : 0;
    }, nil);
}

- (void)dragged:(UIPanGestureRecognizer *)drag {
    CGSize panel = _panel.bounds.size;
    if (panel.width <= 0 || panel.height <= 0) return;
    CGPoint move = [drag translationInView:_panel];
    [drag setTranslation:CGPointZero inView:_panel];
    _clipView.x += move.x / panel.width;
    _clipView.y += move.y / panel.height;
    [_clipView setNeedsLayout];
    [_clipView layoutIfNeeded];
}

- (void)pinched:(UIPinchGestureRecognizer *)pinch {
    _clipView.zoom = _clipView.zoom * pinch.scale;
    pinch.scale = 1;
    [_clipView layoutIfNeeded];
}

- (void)finishAdjusting {
    [self setAdjusting:NO];
}

- (void)resetAdjustment {
    _clipView.zoom = 1;
    _clipView.x = 0;
    _clipView.y = 0;
    SGRAnimate(SGRMotionLayout, ^{ [self->_clipView layoutIfNeeded]; }, nil);
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect safe = UIEdgeInsetsInsetRect(self.view.bounds, self.view.safeAreaInsets);
    CGFloat column = round(safe.size.width * kColumnShare);
    CGFloat left = CGRectGetMinX(safe) + kSide;
    CGFloat titleHeight = ceil(_title.font.lineHeight), artistHeight = ceil(_artist.font.lineHeight);
    CGFloat textHeight = MAX(titleHeight + artistHeight, kControlSide), controlsHeight = kControlSide;
    CGFloat side = MIN(column - kSide, safe.size.height - 2 * kSide - textHeight - controlsHeight - 2 * kCoverGap);
    CGFloat top = CGRectGetMidY(safe) - (side + kCoverGap + textHeight + kCoverGap + controlsHeight) / 2;
    _cover.frame = CGRectMake(left, top, side, side);
    // The close button at the text's trailing end, its glyph (about 20pt in the 44pt square) at the cover's edge.
    CGFloat textTop = CGRectGetMaxY(_cover.frame) + kCoverGap;
    _close.frame = CGRectMake(left + side - kControlSide + 12, textTop + (textHeight - kControlSide) / 2, kControlSide, kControlSide);
    _title.frame = CGRectMake(left, textTop + (textHeight - titleHeight - artistHeight) / 2, side - kControlSide, titleHeight);
    _artist.frame = CGRectMake(left, CGRectGetMaxY(_title.frame), side - kControlSide, artistHeight);
    _controls.frame = CGRectMake(left + side * 0.1, textTop + textHeight + kCoverGap, side * 0.8, controlsHeight);
    CGFloat linesLeft = left + side + kSide;
    _stage.frame = CGRectMake(linesLeft, CGRectGetMinY(safe), CGRectGetMaxX(safe) - linesLeft, safe.size.height);
    _lyrics.frame = _stage.bounds;
    BOOL panel = [self clipShown];
    _panel.hidden = !panel;
    _seek.hidden = !panel;
    _cover.alpha = panel ? 0 : 1;
    if (panel) {
        // The panel from the screen's left edge to its middle, whatever the safe area; the text and the controls
        // over its foot, inside the safe area, and the lines on the right.
        CGFloat width = round(self.view.bounds.size.width * kPanelShare), height = self.view.bounds.size.height;
        _panel.frame = CGRectMake(0, 0, width, height);
        _clipView.frame = _panel.bounds;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        _melt.frame = _panel.bounds;
        _shade.frame = _panel.bounds;
        [CATransaction commit];
        _adjustFrame.frame = CGRectInset(_panel.frame, 6, 6);
        CGFloat inner = width - left - kSide;
        CGFloat controlsTop = CGRectGetMaxY(safe) - kSide - controlsHeight;
        textTop = controlsTop - kCoverGap - textHeight;
        _close.frame = CGRectMake(left + inner - kControlSide + 12, textTop + (textHeight - kControlSide) / 2, kControlSide, kControlSide);
        _title.frame = CGRectMake(left, textTop + (textHeight - titleHeight - artistHeight) / 2, inner - kControlSide, titleHeight);
        _artist.frame = CGRectMake(left, CGRectGetMaxY(_title.frame), inner - kControlSide, artistHeight);
        _controls.frame = CGRectMake(left + inner * 0.1, controlsTop, inner * 0.8, controlsHeight);
        // The seek line between the words and the controls; the words move up to make room.
        CGFloat seekTop = controlsTop - kSeekHeight - 6;
        textTop -= kSeekHeight + 6;
        _close.frame = CGRectMake(left + inner - kControlSide + 12, textTop + (textHeight - kControlSide) / 2, kControlSide, kControlSide);
        _title.frame = CGRectMake(left, textTop + (textHeight - titleHeight - artistHeight) / 2, inner - kControlSide, titleHeight);
        _artist.frame = CGRectMake(left, CGRectGetMaxY(_title.frame), inner - kControlSide, artistHeight);
        _seek.frame = CGRectMake(left, seekTop, inner, kSeekHeight);
        [self layoutSeek];
        linesLeft = width + kSide;
        _stage.frame = CGRectMake(linesLeft, CGRectGetMinY(safe), CGRectGetMaxX(safe) - linesLeft, safe.size.height);
        _lyrics.frame = _stage.bounds;
    }
    // The hint and Reset side by side, centered at the top.
    CGFloat gap = 12, pills = _hint.bounds.size.width + gap + _resetPill.bounds.size.width;
    CGFloat pillsLeft = CGRectGetMidX(self.view.bounds) - pills / 2, pillsTop = MAX(CGRectGetMinY(safe), 8) + 8;
    _hint.frame = CGRectMake(pillsLeft, pillsTop, _hint.bounds.size.width, _hint.bounds.size.height);
    _resetPill.frame = CGRectMake(CGRectGetMaxX(_hint.frame) + gap, pillsTop, _resetPill.bounds.size.width, _resetPill.bounds.size.height);
    if (!_bare) return;

    // The cover at the screen's height and the title and controls beside it, the two centered as one. The
    // lines keep their place above, so they come back from where they will stand.
    side = safe.size.height - 2 * kSide;
    CGFloat info = MIN(kBareInfoWidth, safe.size.width - 3 * kSide - side);
    CGFloat x = CGRectGetMidX(safe) - (side + kSide + info) / 2;
    _cover.frame = CGRectMake(x, CGRectGetMidY(safe) - side / 2, side, side);
    CGFloat infoLeft = x + side + kSide;
    textTop = CGRectGetMidY(safe) - (textHeight + kCoverGap + controlsHeight) / 2;
    _close.frame = CGRectMake(infoLeft + info - kControlSide + 12, textTop + (textHeight - kControlSide) / 2, kControlSide, kControlSide);
    _title.frame = CGRectMake(infoLeft, textTop + (textHeight - titleHeight - artistHeight) / 2, info - kControlSide, titleHeight);
    _artist.frame = CGRectMake(infoLeft, CGRectGetMaxY(_title.frame), info - kControlSide, artistHeight);
    _controls.frame = CGRectMake(infoLeft, textTop + textHeight + kCoverGap, MIN(kBareControlsWidth, info), controlsHeight);
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self restartRest];
}

// The window comes up clear and fades in as the scene turns, so the screen is never seen laid out upright.
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    UIWindow *window = self.view.window;
    if (!window || window != sg_window || size.width <= size.height) return;
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        window.alpha = 1;
    } completion:nil];
}

- (void)artworkChanged {
    NSString *identity = nil;
    UIImage *art = SGRNowPlayingArtwork(NULL, &identity);
    if (!art) return;
    // On the field's clock, so the cover and the colors behind it change as one.
    UIImageView *cover = _cover;
    [UIView transitionWithView:cover duration:SGRCrossfade options:UIViewAnimationOptionTransitionCrossDissolve
                    animations:^{ cover.image = art; } completion:nil];
    [_field setArtwork:art identity:identity animated:YES];
}

// Lines in: the lines' layout at once. None (the player's own verdict, after its grace): the cover's.
// Otherwise the layout stays, so a track change does not flash between the two. A track change alone never
// takes the lines away: the player may not have heard of it yet, and would still count the last one's grace.
- (void)updateBare:(BOOL)mayGoBare {
    BOOL bare = _bare;
    if (SGRPlayerLyricsAvailable()) bare = NO;
    else if (mayGoBare && SGRPlayerLyricsNone()) bare = YES;
    if (bare == _bare) return;
    _bare = bare;
    SGLog(@"redesign player: landscape %@", bare ? @"without lines, the cover takes the screen" : @"with lines");
    // The lines leave the window while they are away, so their display link stops with them.
    if (!bare) [self.view insertSubview:_stage aboveSubview:_controls];
    UIView *stage = _stage;
    void (^change)(void) = ^{
        [self.view setNeedsLayout];
        [self.view layoutIfNeeded];
        stage.alpha = bare ? 0 : 1;
    };
    void (^done)(BOOL) = ^(BOOL finished) {
        if (self->_bare) [stage removeFromSuperview];
    };
    if (self.view.window) SGRAnimateLayout(self.view, change, done);
    else {
        change();
        done(YES);
    }
    // Without lines there is nothing to read past the controls, so they stay.
    if (bare) [self wake];
    else [self restartRest];
}

- (void)playerStateDidChange:(SPTPlayerState *)state {
    if (!state) return;
    [self updateBare:NO];
    _title.text = state.track.trackTitle;
    _artist.text = state.track.artistName;
    [_play setImage:[UIImage systemImageNamed:state.isPaused ? @"play.fill" : @"pause.fill" withConfiguration:
        [UIImageSymbolConfiguration configurationWithPointSize:30 weight:UIImageSymbolWeightBold]] forState:UIControlStateNormal];
    _play.accessibilityLabel = state.isPaused ? @"Play" : @"Pause";
    _field.motionHeld = state.isPaused;
    [self updateClipPlaying];
    // A pause brings the controls back and keeps them; playing again, from here or anywhere, starts the
    // clock. The tap on the play button cannot: the state saying so arrives a beat after it.
    if (state.isPaused) [self setControlsShown:YES];
    else if (!_rest && !_shield.superview) [self restartRest];
}

#pragma mark - controls

- (id<SPTPlayer>)player {
    id player = SGKaraokePlayer();
    return [player conformsToProtocol:@protocol(SPTPlayer)] || [player respondsToSelector:@selector(pause:)] ? player : nil;
}

- (void)togglePlay {
    id<SPTPlayer> player = self.player;
    if (SGPlayerState().isPaused) [player resume:nil];
    else [player pause:nil];
    [self restartRest];
}

- (void)previous {
    [self.player skipToPreviousTrackWithOptions:nil];
    [self restartRest];
}

- (void)next {
    [self.player skipToNextTrackWithOptions:nil];
    [self restartRest];
}

- (void)turnBack {
    sg_shut = YES;
    SGRPlayerShowLandscape(NO);
}

// VoiceOver's two-finger scrub.
- (BOOL)accessibilityPerformEscape {
    [self turnBack];
    return YES;
}

// The lines on their own, unless VoiceOver needs the controls to be there.
- (void)rest {
    if (!_bare && !_adjusting && !UIAccessibilityIsVoiceOverRunning()) [self setControlsShown:NO];
}

- (void)wake {
    [self setControlsShown:YES];
}

- (void)setControlsShown:(BOOL)shown {
    [_rest invalidate];
    _rest = nil;
    _hide.enabled = shown;
    if (shown) [_shield removeFromSuperview];
    else if (!_shield.superview) {
        _shield.frame = self.view.bounds;
        [self.view addSubview:_shield];
    }
    // Back at a tap with the Kit's response, from where a fade out is; they go with the slow fade, as the
    // portrait player's do (PlayerLyrics.x).
    SGRAnimate(shown ? SGRMotionRespond : SGRMotionFade, ^{
        for (UIView *view in @[self->_controls, self->_close, self->_title, self->_artist, self->_seek]) view.alpha = shown ? 1 : 0;
        self->_lyrics.extrasHidden = !shown;
    }, nil);
    if (shown) [self restartRest];
}

- (void)restartRest {
    [_rest invalidate];
    _rest = nil;
    if (_bare || _adjusting || !SGEnabled(SGRKeyLyricsAutoHide) || SGPlayerState().isPaused || UIAccessibilityIsVoiceOverRunning()) return;
    __weak SGRLandscapeLyricsController *weakSelf = self;
    _rest = [NSTimer scheduledTimerWithTimeInterval:kLandscapeRest repeats:NO block:^(NSTimer *timer) {
        // A sheet over the lines (a line's meanings) keeps them up, and the clock runs again behind it.
        SGRLandscapeLyricsController *strongSelf = weakSelf;
        if (strongSelf.presentedViewController) [strongSelf restartRest];
        else [strongSelf rest];
    }];
}

@end

#pragma mark - turning

static UIInterfaceOrientationMask (*sg_origOrientations)(id, SEL, UIApplication *, UIWindow *);

static UIInterfaceOrientationMask orientationsFor(id self, SEL _cmd, UIApplication *application, UIWindow *window) {
    if (window && window == sg_window) return UIInterfaceOrientationMaskLandscape;
    return sg_origOrientations ? sg_origOrientations(self, _cmd, application, window) : UIInterfaceOrientationMaskPortrait;
}

// The delegate's own answer stays for every window but the landscape one; one that has none answers
// portrait, which is what the Info.plist said.
static void answerForOrientations(void) {
    static BOOL done;
    id delegate = UIApplication.sharedApplication.delegate;
    if (done || !delegate) return;
    done = YES;
    SEL selector = @selector(application:supportedInterfaceOrientationsForWindow:);
    Method method = class_getInstanceMethod([delegate class], selector);
    if (method) sg_origOrientations = (void *)method_setImplementation(method, (IMP)orientationsFor);
    else class_addMethod([delegate class], selector, (IMP)orientationsFor, "Q@:@@");
    SGLog(@"redesign player: landscape lyrics answer for %@ (%@)", NSStringFromClass([delegate class]), method ? @"its own answer kept" : @"portrait otherwise");
}

// A landscape window still clear when no turn is coming to fade it in.
static void reveal(UIWindow *window) {
    if (window && window == sg_window && window.alpha < 1) SGRAnimate(SGRMotionFade, ^{ window.alpha = 1; }, nil);
}

static void requestOrientations(UIWindowScene *scene, UIInterfaceOrientationMask mask) {
    __weak UIWindow *window = sg_window;
    if (@available(iOS 16.0, *)) {
        UIWindowSceneGeometryPreferencesIOS *preferences = [[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:mask];
        [scene requestGeometryUpdateWithPreferences:preferences errorHandler:^(NSError *error) {
            SGLog(@"redesign player: the scene did not turn: %@", error.localizedDescription);
            dispatch_async(dispatch_get_main_queue(), ^{ reveal(window); });
        }];
    }
}

void SGRPlayerLandscapeLinesChanged(void) {
    id screen = sg_window.rootViewController;
    if ([screen isKindOfClass:SGRLandscapeLyricsController.class]) [screen updateBare:YES];
}

void SGRPlayerShowLandscape(BOOL show) {
    UIWindowScene *scene = (UIWindowScene *)UIApplication.sharedApplication.connectedScenes.anyObject;
    if (![scene isKindOfClass:UIWindowScene.class]) return;
    if (show && !sg_window) {
        answerForOrientations();
        sg_window = [[UIWindow alloc] initWithWindowScene:scene];
        sg_window.windowLevel = UIWindowLevelNormal + 1;
        // The window is the mod's own, so what it presents (Sing's alerts, a line's meanings) is dark too.
        sg_window.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        sg_window.alpha = 0;
        sg_window.rootViewController = [SGRLandscapeLyricsController new];
        [sg_window makeKeyAndVisible];
        requestOrientations(scene, UIInterfaceOrientationMaskLandscape);
        if (UIInterfaceOrientationIsLandscape(scene.interfaceOrientation)) reveal(sg_window);
        SGLog(@"redesign player: the lyrics turn sideways");
    } else if (!show && sg_window) {
        UIWindow *window = sg_window;
        sg_window = nil;
        window.userInteractionEnabled = NO;
        // A sheet up over the lines (a line's meanings) goes with them, or it would be left on a hidden window.
        [window.rootViewController dismissViewControllerAnimated:NO completion:nil];
        if (@available(iOS 16.0, *)) [window.rootViewController setNeedsUpdateOfSupportedInterfaceOrientations];
        requestOrientations(scene, UIInterfaceOrientationMaskPortrait);
        // Faded out as the scene turns back; the player is key again once it is gone, unless the lines came
        // back meanwhile.
        SGRAnimate(SGRMotionFade, ^{ window.alpha = 0; }, ^(BOOL finished) {
            window.hidden = YES;
            if (sg_window) return;
            for (UIWindow *other in scene.windows) {
                if (other != window && !other.hidden && other.windowLevel == UIWindowLevelNormal) {
                    [other makeKeyWindow];
                    break;
                }
            }
        });
        SGLog(@"redesign player: the lyrics turn back");
    }
}

static void orientationChanged(void) {
    UIDeviceOrientation orientation = UIDevice.currentDevice.orientation;
    if (UIDeviceOrientationIsLandscape(orientation)) {
        if (!sg_shut && SGEnabled(SGRKeyLyricsLandscape) && SGRPlayerLyricsOpen()) SGRPlayerShowLandscape(YES);
    } else if (orientation == UIDeviceOrientationPortrait) {
        sg_shut = NO;
        SGRPlayerShowLandscape(NO);
    }
}

%ctor {
    if (!SGRedesignedUI()) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIDevice.currentDevice beginGeneratingDeviceOrientationNotifications];
        [NSNotificationCenter.defaultCenter addObserverForName:UIDeviceOrientationDidChangeNotification object:nil queue:nil
                                                    usingBlock:^(NSNotification *note) { orientationChanged(); }];
    });
}
