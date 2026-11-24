// Player redesign: Animated artwork, the track's Canvas or Apple Music's animated cover behind the player,
// the way the Music app draws it. The clip runs edge to edge from the top, sharp to near its foot, where
// it dissolves into the color of its last rows, drawn on down to the bottom of the field, so it ends in
// its own color rather than on the Fluid field. A blur comes in from the seam (from above the controls for a
// Canvas as tall as the screen) and lies under the controls; behind the lyrics the whole clip is blurred.
// The player's square cover goes while a clip plays, so a track without one keeps its cover over Fluid
// (PlayerField.x keeps the field Fluid for this choice). The player's ⋯ menu switches between Animated
// and Fluid at once (Shared/Player/SpeedPitch.h).
//
// The clip is a subview of the field, not of the background plane: the plane's layout brings the field to
// the front on every pass, and a sibling would end up under it. Each of the field's layout passes attaches
// it (SGRPlayerMotionFieldLaidOut), so a clip that came in before the player first opened, or a field
// Spotify built again, gets it.
//
// The clip holds still when the moving field does (SGRField.m): out of a window, with the app not in front,
// while the player opens or closes, and while the song is paused. Under Reduce Motion and in Low Power Mode
// no clip plays at all: the cover stays over Fluid, as for a track without one, until both are off again.
// While a clip is showing, the Fluid field under it is held still too, and once the clip has faded in it is
// hidden (the field's covered): the field's color is what shows above the clip on the pull that dismisses.
//
// The clip is dimmed by how bright it is (SGRPlayerClipDim): three of its frames are measured as it comes in,
// so a white Canvas is drawn darker than a black one and the white text over it keeps its contrast.
//
// A track that changes while the player cannot be seen (out of a window, or with the app not in front, which a
// locked phone's player is while it stays in its window) takes the last clip away at once, without a fade, so
// the last track's clip does not greet the player as it opens.
//
// The clip and the cover cross over: the clip fades in from its first frame (the poster, under the video
// until the video has decoded one) as the cover fades out, and fades out as the cover comes back. A clip
// that has drawn no frame of its own after kGiveUp seconds on screen is given up, and the cover comes back.
// On a skip the last clip stays a moment (kHandOver), so a clip already in the store (the next track's is
// fetched ahead, SGMotionFollower) crosses over it with no cover between.
//
// Spotify's music video (Switch to video) draws in one of three of its units, each told by its video surface
// as the video comes and goes: while one shows it, the clip goes and the cover comes back, as for Fluid.
#import <AVFoundation/AVFoundation.h>
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Shared/AnimatedArtwork/AnimatedArtwork.h"
#import "Shared/Player/PlayerState.h"
#import "Shared/Player/SGLastTrack.h"
#import "Shared/Player/SpeedPitch.h"
#import "Player.h"

// Where the clip starts dissolving into its foot, as a share of its height.
static const CGFloat kFootFrom = 0.9;
// The share of the poster's height, at its bottom, whose mean color the foot is.
static const CGFloat kFootRows = 0.03;
// A clip this much taller than wide is a Canvas (9:16), drawn to the window's full height and centered, cut at its
// sides. Apple Music's tall cover (3:4) keeps its own height from the top, whole, as the Music app draws it
// (issues #40 and #57: drawn to the window's height it lost two fifths of its width).
static const CGFloat kCanvasAspect = 1.5;
// The blur starts at the seam, or this share of the screen down where that is higher, so it is under the
// controls whatever the clip's shape; it is whole kBlurRamp points below its start.
static const CGFloat kBlurByControls = 0.6, kBlurRamp = 96;
// Seconds a clip may be on screen in front without drawing a frame before it is given up.
static const NSTimeInterval kGiveUp = 5;
// Seconds the last track's clip stays on a skip for the next one's to come in over it.
static const NSTimeInterval kHandOver = 0.4;
// The dim's floor and ceiling, and what the lyrics add to it.
static const CGFloat kDimLeast = 0.10, kDimMost = 0.80, kDimLyrics = 0.15;
// The frames measured for the dim besides the poster, in seconds into the clip (one past its end is skipped).
static const double kMeasuredAt[] = {1, 2};

CGFloat SGRPlayerClipDim(CGFloat luminance, BOOL contrast, BOOL lyrics) {
    // White is 1, so (1 + 0.05) / (L + 0.05) >= ratio puts the clip's luminance at `most` or under.
    CGFloat ratio = contrast ? 7 : 4.5, most = 1.05 / ratio - 0.05;
    // A black layer scales the clip's encoded values, which Core Animation blends, so its linear luminance
    // goes down by about the 2.2nd power of what the layer leaves.
    CGFloat dim = luminance > most ? 1 - pow(most / luminance, 1 / 2.2) : 0;
    dim = MIN(MAX(dim, kDimLeast), kDimMost);
    return lyrics ? dim + kDimLyrics : dim;
}

// Each pixel's linear luminance, of the image drawn 16 points square, onto `into` as floats.
static void addLuminances(CGImageRef image, NSMutableData *into) {
    if (!image) return;
    enum { kSide = 16 };
    uint8_t pixels[kSide * kSide * 4];
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(pixels, kSide, kSide, 8, kSide * 4, space, (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
    CGColorSpaceRelease(space);
    if (!context) return;
    CGContextDrawImage(context, CGRectMake(0, 0, kSide, kSide), image);
    CGContextRelease(context);
    for (int i = 0; i < kSide * kSide; i++) {
        float linear[3];
        for (int c = 0; c < 3; c++) {
            float v = pixels[i * 4 + c] / 255.0f;
            linear[c] = v <= 0.04045f ? v / 12.92f : powf((v + 0.055f) / 1.055f, 2.4f);
        }
        float luminance = 0.2126f * linear[0] + 0.7152f * linear[1] + 0.0722f * linear[2];
        [into appendBytes:&luminance length:sizeof luminance];
    }
}

// The 75th percentile of the luminances: the bright end the text has to stand out against, past a few
// highlights.
static CGFloat brightEnd(NSData *luminances) {
    NSUInteger count = luminances.length / sizeof(float);
    if (!count) return 0;
    NSMutableData *sorted = [luminances mutableCopy];
    qsort_b(sorted.mutableBytes, count, sizeof(float), ^int(const void *a, const void *b) {
        float x = *(const float *)a, y = *(const float *)b;
        return x < y ? -1 : x > y;
    });
    return ((const float *)sorted.bytes)[(count - 1) * 3 / 4];
}

// The mean color of the poster's last rows (kFootRows): drawn 16 pixels wide and averaged. A row's own colors
// stretched on down read as vertical streaks (issue #40).
static UIColor *footColor(CGImageRef poster) {
    enum { kWide = 16 };
    size_t height = CGImageGetHeight(poster), rows = MAX(1, (size_t)(height * kFootRows));
    CGImageRef strip = CGImageCreateWithImageInRect(poster, CGRectMake(0, height - rows, CGImageGetWidth(poster), rows));
    uint8_t pixels[kWide * 4] = {0};
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(pixels, kWide, 1, 8, kWide * 4, space, (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
    CGColorSpaceRelease(space);
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGContextDrawImage(context, CGRectMake(0, 0, kWide, 1), strip);
    CGContextRelease(context);
    CGImageRelease(strip);
    CGFloat sum[3] = {0};
    for (int i = 0; i < kWide; i++) {
        for (int c = 0; c < 3; c++) sum[c] += pixels[i * 4 + c];
    }
    return [UIColor colorWithRed:sum[0] / (kWide * 255.0) green:sum[1] / (kWide * 255.0) blue:sum[2] / (kWide * 255.0) alpha:1];
}

@interface SGRPlayerMotionView : UIView <SGPlayerStateObserver>
@property (nonatomic) CGFloat screenHeight;
// Runs when the clip has drawn nothing kGiveUp seconds after it was first on screen in front.
@property (nonatomic, copy) void (^gaveUp)(void);
- (void)playFile:(NSURL *)file poster:(UIImage *)poster;
// The cover alone, filled to the screen as a Canvas is, for a track with no clip (Full-screen cover).
- (void)playStill:(UIImage *)cover;
- (void)appear:(BOOL)animated then:(void (^)(void))done;
- (void)setBlurred:(BOOL)blurred animated:(BOOL)animated;
@end

@implementation SGRPlayerMotionView {
    AVQueuePlayer *_player;
    AVPlayerLooper *_looper;
    UIView *_picture;   // the clip over its foot, faded in as one
    CALayer *_still;    // the poster, with the video drawn over it
    AVPlayerLayer *_clip;
    CAGradientLayer *_clipMask, *_seamMask;
    CALayer *_foot;   // the color of the poster's last rows, from the seam down
    CALayer *_dim;   // black over the clip and its foot, as dark as the clip is bright
    NSMutableData *_luminances;   // of the frames measured so far
    BOOL _lyricsUp;
    UIVisualEffectView *_seamBlur, *_lyricsBlur;
    CGFloat _aspect;
    BOOL _timing;   // the give-up's count is running
    BOOL _fills;    // a still cover: sharp at the screen's width, melting into a blurred copy of itself
    CALayer *_backdrop;   // that copy, over the whole player, under the cover
}

// What fades is the effect views' effect, never their alpha or an ancestor's: UIKit draws a blur under a
// fading alpha or a mask wrongly or not at all.
static UIBlurEffect *blurEffect(void) {
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.userInteractionEnabled = NO;
    self.accessibilityElementsHidden = YES;
    _picture = [[UIView alloc] initWithFrame:frame];
    [self addSubview:_picture];
    _foot = [CALayer layer];
    [_picture.layer addSublayer:_foot];
    // An AVPlayerLayer draws nothing until its first frame is decoded, so the poster, the clip's first
    // frame and where the looper starts, is the contents of the layer the video draws in: there is a
    // picture from the first frame, and the video covers it exactly.
    _backdrop = [CALayer layer];
    _backdrop.contentsGravity = kCAGravityResizeAspectFill;
    _backdrop.masksToBounds = YES;
    _backdrop.hidden = YES;
    [_picture.layer addSublayer:_backdrop];
    _still = [CALayer layer];
    _still.contentsGravity = kCAGravityResizeAspectFill;
    _still.masksToBounds = YES;
    _clip = [AVPlayerLayer layer];
    _clip.videoGravity = AVLayerVideoGravityResizeAspectFill;
    [_still addSublayer:_clip];
    _clipMask = [CAGradientLayer layer];
    _clipMask.colors = @[(id)UIColor.blackColor.CGColor, (id)UIColor.blackColor.CGColor, (id)UIColor.clearColor.CGColor];
    _clipMask.locations = @[@0, @(kFootFrom), @1];
    _still.mask = _clipMask;
    [_picture.layer addSublayer:_still];
    _dim = [CALayer layer];
    _dim.backgroundColor = UIColor.blackColor.CGColor;
    _dim.opacity = kDimLeast;
    [_picture.layer addSublayer:_dim];

    _seamBlur = [[UIVisualEffectView alloc] initWithEffect:nil];
    _seamBlur.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    UIView *mask = [UIView new];
    _seamMask = [CAGradientLayer layer];
    _seamMask.colors = @[(id)UIColor.clearColor.CGColor, (id)UIColor.blackColor.CGColor];
    [mask.layer addSublayer:_seamMask];
    _seamBlur.maskView = mask;
    [self addSubview:_seamBlur];
    _lyricsBlur = [[UIVisualEffectView alloc] initWithEffect:nil];
    _lyricsBlur.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [self addSubview:_lyricsBlur];

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (NSNotificationName name in @[UIApplicationDidBecomeActiveNotification, UIApplicationWillResignActiveNotification,
                                      NSProcessInfoPowerStateDidChangeNotification, UIAccessibilityReduceMotionStatusDidChangeNotification]) {
        [center addObserver:self selector:@selector(updateMotionSoon) name:name object:nil];
    }
    [center addObserver:self selector:@selector(updateDim) name:UIAccessibilityDarkerSystemColorsStatusDidChangeNotification object:nil];
    SGRObservePlayerTransition(self, ^(id owner) { [owner updateMotion]; }, ^(id owner) { [owner updateMotion]; });
    SGAddPlayerStateObserver(self);
    return self;
}

- (void)playerStateDidChange:(SPTPlayerState *)state {
    [self updateMotion];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)setScreenHeight:(CGFloat)height {
    if (height == _screenHeight) return;
    _screenHeight = height;
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    CGFloat width = bounds.size.width, total = MAX(1, bounds.size.height);
    CGFloat screen = _screenHeight > 0 ? _screenHeight : total;
    CGFloat height = round(width * _aspect);
    if (_aspect > kCanvasAspect) height = MAX(height, screen);
    CGFloat seam = round(height * kFootFrom), blurFrom = MIN(seam, round(screen * kBlurByControls));
    _picture.frame = bounds;
    _seamBlur.frame = bounds;
    _seamBlur.maskView.frame = bounds;
    _lyricsBlur.frame = bounds;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _still.frame = CGRectMake(0, 0, width, height);
    _backdrop.frame = bounds;
    _clip.frame = _still.bounds;
    _clipMask.frame = _still.bounds;
    _foot.frame = CGRectMake(0, seam, width, MAX(0, total - seam));
    _dim.frame = bounds;
    _seamMask.frame = bounds;
    _seamMask.locations = @[@(MIN(1, blurFrom / total)), @(MIN(1, (blurFrom + kBlurRamp) / total))];
    [CATransaction commit];
}

- (void)playFile:(NSURL *)file poster:(UIImage *)poster {
    _aspect = poster.size.height / poster.size.width;
    _foot.backgroundColor = footColor(poster.CGImage).CGColor;
    _still.contents = (__bridge id)poster.CGImage;
    _player = [AVQueuePlayer new];
    _player.muted = YES;
    _player.preventsDisplaySleepDuringVideoPlayback = NO;
    _looper = [AVPlayerLooper playerLooperWithPlayer:_player templateItem:[AVPlayerItem playerItemWithURL:file]];
    _clip.player = _player;
    [self setNeedsLayout];
    [self updateMotion];
    [self measure:file poster:poster];
}

- (void)playStill:(UIImage *)cover {
    _fills = YES;
    // The copy is drawn small and scaled up, which is all the blur it needs; the cover's foot melts into it.
    CGSize tiny = CGSizeMake(32, 32);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    UIImage *small = [[[UIGraphicsImageRenderer alloc] initWithSize:tiny format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [cover drawInRect:CGRectMake(0, 0, tiny.width, tiny.height)];
    }];
    _backdrop.contents = (__bridge id)small.CGImage;
    _backdrop.magnificationFilter = kCAFilterLinear;
    _backdrop.hidden = NO;
    _foot.hidden = YES;
    _clipMask.locations = @[@0, @0.72, @1];
    _aspect = cover.size.height / cover.size.width;
    _foot.backgroundColor = footColor(cover.CGImage).CGColor;
    _still.contents = (__bridge id)cover.CGImage;
    [self setNeedsLayout];
    _luminances = [NSMutableData data];
    addLuminances(cover.CGImage, _luminances);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [self updateDim];
    [CATransaction commit];
}

// The poster now, so the clip comes in already dimmed, and two later frames as they are read.
- (void)measure:(NSURL *)file poster:(UIImage *)poster {
    _luminances = [NSMutableData data];
    addLuminances(poster.CGImage, _luminances);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [self updateDim];
    [CATransaction commit];
    AVAssetImageGenerator *generator = [AVAssetImageGenerator assetImageGeneratorWithAsset:[AVURLAsset assetWithURL:file]];
    generator.appliesPreferredTrackTransform = YES;
    generator.maximumSize = CGSizeMake(64, 64);
    __weak SGRPlayerMotionView *weakSelf = self;
    NSMutableData *into = _luminances;
    for (size_t i = 0; i < sizeof kMeasuredAt / sizeof *kMeasuredAt; i++) {
        [generator generateCGImageAsynchronouslyForTime:CMTimeMakeWithSeconds(kMeasuredAt[i], 600)
                                      completionHandler:^(CGImageRef image, CMTime actual, NSError *error) {
            if (!image) return;
            NSMutableData *frame = [NSMutableData data];
            addLuminances(image, frame);
            dispatch_async(dispatch_get_main_queue(), ^{
                SGRPlayerMotionView *view = weakSelf;
                if (!view || view->_luminances != into) return;
                [into appendData:frame];
                [view updateDim];
            });
        }];
    }
}

- (void)updateDim {
    CGFloat dim = SGRPlayerClipDim(brightEnd(_luminances), UIAccessibilityDarkerSystemColorsEnabled(), _lyricsUp);
    _dim.opacity = (float)dim;
}

// `done` runs once the clip is opaque, unless something cut the fade in short.
- (void)appear:(BOOL)animated then:(void (^)(void))done {
    _picture.alpha = 0;
    void (^apply)(void) = ^{
        self->_picture.alpha = 1;
        self->_seamBlur.effect = blurEffect();
    };
    if (animated) {
        SGRAnimate(SGRMotionFade, apply, ^(BOOL finished) {
            if (finished) done();
        });
    } else {
        apply();
        done();
    }
}

// The clip and both blurs fade out; `done` runs once they have.
- (void)disappear:(void (^)(void))done {
    SGRAnimate(SGRMotionFade, ^{
        self->_picture.alpha = 0;
        self->_seamBlur.effect = nil;
        self->_lyricsBlur.effect = nil;
    }, ^(BOOL finished) { done(); });
}

// The lyrics' blur, and their share of the dim, which a layer's own animation carries over the same fade.
- (void)setBlurred:(BOOL)blurred animated:(BOOL)animated {
    _lyricsUp = blurred;
    void (^apply)(void) = ^{ self->_lyricsBlur.effect = blurred ? blurEffect() : nil; };
    [CATransaction begin];
    [CATransaction setDisableActions:!animated];
    [CATransaction setAnimationDuration:SGRCrossfade];
    [self updateDim];
    [CATransaction commit];
    if (animated) SGRAnimate(SGRMotionFade, apply, nil);
    else apply();
}

// The power state is reported off the main thread.
- (void)updateMotionSoon {
    dispatch_async(dispatch_get_main_queue(), ^{ [self updateMotion]; });
}

// A locked phone keeps the player in its window, so being in front counts as much as being in one.
- (void)updateMotion {
    BOOL front = UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
    BOOL may = self.window && front && !SGRPlayerIsTransitioning() && !SGRReduceMotion() && !NSProcessInfo.processInfo.lowPowerModeEnabled
        && !SGPlayerState().isPaused;
    if (may) [_player play];
    else [_player pause];
    // A paused player still draws the clip's first frame, so the count runs whenever it is on screen in front.
    if (_player && self.window && front && !_timing && !_clip.readyForDisplay) {
        _timing = YES;
        __weak SGRPlayerMotionView *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kGiveUp * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            SGRPlayerMotionView *view = weakSelf;
            if (!view) return;
            view->_timing = NO;
            // Taken off screen meanwhile, the count starts again when it is back.
            BOOL shown = view.window && UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
            if (shown && !view->_clip.readyForDisplay && view.gaveUp) view.gaveUp();
        });
    }
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self updateMotion];
}

@end

static SGRPlayerMotionView *sg_motion;
static NSString *sg_track;   // the track playing
static NSString *sg_shown;   // the track sg_motion is the clip of
static NSUInteger sg_begun;   // counts the walks begun, so a poster read for an earlier one is dropped
// The clip sg_motion plays and its poster, for the Player page's showcase (SGRPlayerMotionPreview).
static NSURL *sg_motionFile;
static UIImage *sg_motionPoster;
// The clip is in and opaque, so the field under it is covered.
static BOOL sg_covering;
// The list the mask went on, so it comes off even while the player is closed and the list cannot be found,
// and the mask, told from any other.
static __weak CALayer *sg_maskedCovers, *sg_coverMask;

// The clip from the top of the field, as wide as it is, its foot down to the bottom of the field's bleed.
static void layOut(void) {
    SGRArtworkField *field = SGRPlayerField();
    if (!sg_motion || !field) return;
    if (sg_motion.superview != field) [field addSubview:sg_motion];
    CGSize size = field.bounds.size;
    CGFloat screen = field.window.bounds.size.height ?: size.height;
    CGRect frame = CGRectMake(0, 0, size.width, MAX(size.height, screen) + field.bleed.bottom);
    if (!CGRectEqualToRect(sg_motion.frame, frame)) sg_motion.frame = frame;
    sg_motion.screenHeight = screen;
    // A field Spotify built again, or the first one after a clip that came in before it, is covered too.
    field.covered = sg_covering;
}

static void cover(BOOL covering) {
    sg_covering = covering;
    SGRPlayerField().covered = covering;
}

// The Fluid field under a clip holds still, as it does for a paused song (PlayerField.x): the clip covers it.
static void holdField(void) {
    SGRPlayerHoldField();
}

// The mask's opacity to `opacity`, from where it is drawn now, over the clip's own fade. The frame reaches a
// few covers past the list's bounds either way, which move as the list scrolls: it counts only during a fade,
// since at 0 the mask hides everything and at 1 it comes off.
static void fadeCoverMask(CALayer *covers, CALayer *mask, float opacity, BOOL animated, void (^done)(void)) {
    // A list out of a window, a closed player's, has nothing to fade.
    id list = covers.delegate;
    animated = animated && [list isKindOfClass:UIView.class] && ((UIView *)list).window;
    CGRect bounds = covers.bounds;
    float from = (mask.presentationLayer ?: mask).opacity;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    mask.frame = CGRectInset(bounds, -3 * bounds.size.width, -bounds.size.height);
    mask.opacity = opacity;
    if (animated) {
        CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
        fade.fromValue = @(from);
        fade.toValue = @(opacity);
        fade.duration = SGRCrossfade;
        fade.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [CATransaction setCompletionBlock:done];
        [mask addAnimation:fade forKey:@"opacity"];
    } else {
        [mask removeAnimationForKey:@"opacity"];
    }
    [CATransaction commit];
    if (!animated && done) done();
}

// A mask rather than alpha: the covers still take the swipe that changes track, and the lyrics, which fade
// the list by its alpha as they come and go, cannot bring the cover back. Asked again for where it is going,
// it does nothing, so the field's layout passes do not cut a fade short.
static void setCoverShown(BOOL shown, BOOL animated) {
    CALayer *covers = shown ? sg_maskedCovers : SGRPlayerCoverList().layer;
    if (!covers) return;
    CALayer *mask = covers.mask;
    BOOL ours = mask && mask == sg_coverMask;
    if (shown) {
        sg_maskedCovers = nil;
        if (!ours) return;
        // A newer fade ends this one early, and the mask stays for it.
        fadeCoverMask(covers, mask, 1, animated, ^{
            if (covers.mask == mask && sg_maskedCovers != covers) covers.mask = nil;
        });
        return;
    }
    if (covers == sg_maskedCovers || (mask && !ours)) return;
    if (!mask) {
        mask = [CALayer layer];
        mask.backgroundColor = UIColor.blackColor.CGColor;
        covers.mask = mask;
        sg_coverMask = mask;
    }
    sg_maskedCovers = covers;
    fadeCoverMask(covers, mask, 0, animated, nil);
}

void SGRPlayerMotionFieldLaidOut(void) {
    layOut();
    setCoverShown(sg_motion == nil, NO);
}

// A clip that came in before the player opened finds no cover to hide at the field's first pass, the covers
// laying out after it (issue #19: the cover over the clip after a relaunch), so each cover's layout asks too.
void SGRPlayerMotionCoverLaidOut(void) {
    setCoverShown(sg_motion == nil, NO);
}

BOOL SGRPlayerMotionShowing(void) {
    return sg_motion != nil;
}

static UIView *previewOf(NSURL *file, UIImage *poster) {
    SGRPlayerMotionView *preview = [[SGRPlayerMotionView alloc] initWithFrame:CGRectZero];
    [preview playFile:file poster:poster];
    [preview appear:NO then:^{}];
    return preview;
}

// The playing track's clip the Player page looked up itself while the player had none, and its poster; the
// file is nil while the walk is out or after it found nothing. The walk is the player's (SGMotionClipFor, at
// the size SGMotionFollower asks for), so its file lands in the store, where the player's own walk finds it.
// With no track playing, the track is the last one played (Shared/Player/SGLastTrack.h).
static NSString *sg_previewTrack;
static NSURL *sg_previewFile;
static UIImage *sg_previewPoster;
static void (^sg_previewArrived)(void);

UIView *SGRPlayerMotionPreview(void (^arrived)(void)) {
    if (sg_motionFile) return previewOf(sg_motionFile, sg_motionPoster);
    SGShownTrack *shown = SGShownTrackNow();
    NSString *track = shown.uri;
    if (!track) return nil;
    BOOL asked = [track isEqualToString:sg_previewTrack];
    if (asked && sg_previewFile) return previewOf(sg_previewFile, sg_previewPoster);
    if (!arrived) return nil;
    // The newest page's to be told; a walk already out for this track is waited on rather than asked again.
    sg_previewArrived = [arrived copy];
    if (asked) return nil;
    sg_previewTrack = track;
    sg_previewFile = nil;
    sg_previewPoster = nil;
    SGLog(@"redesign player: the Player page looks up the clip of %@%@", track, shown.current ? @"" : @", the last played");
    SGMotionClipFor(track, shown.canvasURL, shown.artist, shown.album, SGMotionTall, SGMotionPixels(),
                    ^(NSURL *file, NSString *source) {
        if (![track isEqualToString:sg_previewTrack]) return;
        // Nothing found is not kept: the page asks again the next time it shows Animated.
        if (!file) {
            sg_previewTrack = nil;
            sg_previewArrived = nil;
            return;
        }
        SGMotionPoster(file, ^(UIImage *poster) {
            if (![track isEqualToString:sg_previewTrack]) return;
            void (^done)(void) = sg_previewArrived;
            sg_previewArrived = nil;
            if (!poster || poster.size.width <= 0) {
                sg_previewTrack = nil;
                return;
            }
            sg_previewFile = file;
            sg_previewPoster = poster;
            SGLog(@"redesign player: the Player page's clip from %@, %@", source, file.lastPathComponent);
            if (done) done();
        });
    });
    return nil;
}

static SGMotionFollower *sg_follower;

// Spotify's units that are showing its music video, held weakly: one that goes without saying so lets go.
static NSHashTable *sg_videos;

static BOOL videoShowing(void) {
    return sg_videos.allObjects.count > 0;
}

// Reduce Motion asks for no looping clip, and Low Power Mode for no video decoding behind the player.
static BOOL motionAllowed(void) {
    return !SGRReduceMotion() && !NSProcessInfo.processInfo.lowPowerModeEnabled;
}

// The clip can be seen: in a window, with the app in front.
static BOOL seen(UIView *view) {
    return view.window && UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
}

// The clip fades out over the cover coming back where the player is seen, and goes at once where not.
static void clear(BOOL animated) {
    SGRPlayerMotionView *old = sg_motion;
    sg_motion = nil;
    sg_shown = nil;
    sg_motionFile = nil;
    sg_motionPoster = nil;
    // Uncovered before the clip starts to fade, so the field is there under it.
    cover(NO);
    holdField();
    animated = animated && seen(old);
    setCoverShown(YES, animated);
    if (animated) [old disappear:^{ [old removeFromSuperview]; }];
    else [old removeFromSuperview];
}

static BOOL fullCoverOn(void) {
    return SGFlag(SGKeyMotionFullCover, NO);
}

// Where the still cover shown is the track's, and how wide it is, so a sharper one replaces it and the same one does not.
static NSString *sg_stillFor;   // the track waiting for its cover to come in
static CGFloat sg_stillWidth;

// Full-screen cover: the playing track's cover over the whole player where it has no clip. The cover is the one
// the player published; until that is this track's, the track waits for the notice that it has come.
static void showStill(NSString *track) {
    if (!fullCoverOn() || ![track isEqualToString:sg_track]) return;
    NSString *of = nil;
    UIImage *picture = SGRNowPlayingArtwork(&of, NULL);
    if (!picture || picture.size.width <= 0 || picture.size.height <= 0 || (of && ![of isEqualToString:track])) {
        sg_stillFor = track;
        return;
    }
    sg_stillFor = nil;
    BOOL same = [track isEqualToString:sg_shown] && !sg_motionFile;
    if (same && sg_stillWidth >= picture.size.width) return;
    clear(YES);
    sg_motion = [[SGRPlayerMotionView alloc] initWithFrame:CGRectZero];
    sg_shown = track;
    sg_stillWidth = picture.size.width;
    SGRPlayerMotionView *motion = sg_motion;
    [motion playStill:picture];
    layOut();
    holdField();
    [motion setBlurred:SGRPlayerLyricsOpen() animated:NO];
    BOOL animated = seen(motion);
    [motion appear:animated then:^{
        if (sg_motion == motion) cover(YES);
    }];
    setCoverShown(NO, animated);
    SGLog(@"redesign player: full-screen cover of %@, %.0fx%.0f", track, picture.size.width, picture.size.height);
}

static void show(NSString *track, NSURL *file) {
    if (!file || ![track isEqualToString:sg_track]) return;
    NSUInteger begun = sg_begun;
    SGMotionPoster(file, ^(UIImage *poster) {
        // A walk begun while the poster was read (switched off, Spotify's video) has the say.
        if (!poster || poster.size.width <= 0 || begun != sg_begun) return;
        clear(YES);
        sg_motion = [[SGRPlayerMotionView alloc] initWithFrame:CGRectZero];
        sg_shown = track;
        SGRPlayerMotionView *motion = sg_motion;
        motion.gaveUp = ^{
            if (sg_motion != motion) return;
            SGLog(@"redesign player: animated artwork %@ drew nothing in %.0f s, given up", file.lastPathComponent, kGiveUp);
            clear(YES);
        };
        [sg_motion playFile:file poster:poster];
        sg_motionFile = file;
        sg_motionPoster = poster;
        layOut();
        holdField();
        [sg_motion setBlurred:SGRPlayerLyricsOpen() animated:NO];
        BOOL animated = seen(sg_motion);
        [motion appear:animated then:^{
            if (sg_motion == motion) cover(YES);
        }];
        setCoverShown(NO, animated);
        SGLog(@"redesign player: animated artwork %@, %.0fx%.0f", file.lastPathComponent, poster.size.width, poster.size.height);
    });
}

void SGRPlayerMotionLyricsChanged(void) {
    [sg_motion setBlurred:SGRPlayerLyricsOpen() animated:sg_motion.window != nil];
}

static void videoSurface(id unit, BOOL attached) {
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL was = videoShowing();
        if (attached) [sg_videos addObject:unit];
        else [sg_videos removeObject:unit];
        if (videoShowing() == was) return;
        SGLog(@"redesign player: Spotify's video %@", was ? @"gone, the clip looked up again" : @"showing, the clip away");
        [sg_follower restart];
    });
}

// A skip on screen leaves the last clip a moment for the next one's to cross over, and the same track
// walked again (its Canvas came late) keeps its clip until the new one does. Otherwise the clip goes: at
// once where it cannot be seen, with a fade for Spotify's video, under Reduce Motion or Low Power Mode, and
// when the background is not Animated.
static BOOL beginTrack(NSString *track) {
    sg_track = track;
    sg_begun++;
    // Read on every track, since the ⋯ menu switches it.
    BOOL animatedBackground = SGRPlayerBackground() == SGRPlayerBackgroundAnimated && !videoShowing();
    BOOL wanted = animatedBackground && motionAllowed();
    if (wanted && [track isEqualToString:sg_shown]) return YES;
    sg_stillFor = nil;
    if (!wanted || !seen(sg_motion)) {
        // Where no clip may play (Reduce Motion, Low Power Mode) the cover still fills the player.
        if (!wanted && animatedBackground && fullCoverOn()) {
            if ([track isEqualToString:sg_shown] && !sg_motionFile) return NO;
            clear(YES);
            showStill(track);
            return NO;
        }
        clear(YES);
        return wanted;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kHandOver * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if ([track isEqualToString:sg_track] && sg_motion && ![track isEqualToString:sg_shown]) clear(YES);
    });
    return YES;
}

#pragma mark - the ⋯ menu's switch (Shared/Player/SpeedPitch.h)

// Fluid, Animated and the Visualizer share the field, so the menu moves between them without a restart. The
// other backgrounds are a field of another kind, chosen on the Player page (PlayerSettings.m).
BOOL SGPlayerMenuOffersAnimatedArtwork(void) {
    return sg_follower && SGRPlayerBackground() >= SGRPlayerBackgroundFluid;
}

BOOL SGPlayerMenuAnimatedArtwork(void) {
    return SGRPlayerBackground() == SGRPlayerBackgroundAnimated;
}

void SGPlayerMenuSetAnimatedArtwork(BOOL on) {
    if (!SGPlayerMenuOffersAnimatedArtwork() || on == SGPlayerMenuAnimatedArtwork()) return;
    SGSetInt(SGRKeyPlayerBackground, on ? SGRPlayerBackgroundAnimated : SGRPlayerBackgroundFluid);
    SGLog(@"redesign player: animated artwork switched %@ from the menu", on ? @"on" : @"off");
    // The playing track is let go, and looked up again when switched on.
    clear(YES);
    [sg_follower restart];
    // From the Visualizer, whose hills go.
    SGRPlayerVisualiserUpdate();
}

%group SGRVideoSurfaces
%hook _TtC28NowPlaying_ContentLayersImpl24HorizontalVideoViewModel
- (void)videoSurfaceDidAttachVideo:(id)surface {
    %orig;
    videoSurface(self, YES);
}
- (void)videoSurfaceDidDetachVideo:(id)surface {
    %orig;
    videoSurface(self, NO);
}
%end

%hook _TtC28NowPlaying_ContentLayersImpl31VerticalVideoCellImplementation
- (void)videoSurfaceDidAttachVideo:(id)surface {
    %orig;
    videoSurface(self, YES);
}
- (void)videoSurfaceDidDetachVideo:(id)surface {
    %orig;
    videoSurface(self, NO);
}
%end

%hook _TtC22NowPlaying_ElementsKit14VideoElementUI
- (void)videoSurfaceDidAttachVideo:(id)surface {
    %orig;
    videoSurface(self, YES);
}
- (void)videoSurfaceDidDetachVideo:(id)surface {
    %orig;
    videoSurface(self, NO);
}
%end
%end

%ctor {
    if (!SGRedesignedUI()) return;
    SGRPlayerBackgroundKind background = SGRPlayerBackground();
    if (background < SGRPlayerBackgroundFluid) return;
    sg_videos = [NSHashTable weakObjectsHashTable];
    // Here rather than on the clip's view, which is gone while they hold it off: the track is walked again
    // as either changes. The power state is reported off the main thread, which must not wait for main
    // (AGENTS.md), so the observer takes it where it is posted and hops.
    __block BOOL allowed = motionAllowed();
    for (NSNotificationName name in @[NSProcessInfoPowerStateDidChangeNotification, UIAccessibilityReduceMotionStatusDidChangeNotification]) {
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (motionAllowed() == allowed) return;
                allowed = !allowed;
                SGLog(@"redesign player: animated artwork %@", allowed ? @"allowed again, the clip looked up" : @"held off by Reduce Motion or Low Power Mode, Fluid shows");
                [sg_follower restart];
            });
        }];
    }
    // The cover for the track may come in after the track does.
    [NSNotificationCenter.defaultCenter addObserverForName:SGRNowPlayingArtworkDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *track = sg_stillFor ?: sg_shown;
            if (!track || sg_motionFile || ![track isEqualToString:sg_track]) return;
            if (sg_stillFor || sg_motion) showStill(track);
        });
    }];
    sg_follower = [[SGMotionFollower alloc] initWithBegin:^BOOL(NSString *uri, SPTPlayerState *state) {
        return beginTrack(uri);
    } found:^(NSString *uri, NSURL *file) {
        if (file) show(uri, file);
        else if (fullCoverOn() && SGRPlayerBackground() == SGRPlayerBackgroundAnimated && !videoShowing()) showStill(uri);
        else clear(YES);
    }];
    %init(SGRVideoSurfaces);
}
