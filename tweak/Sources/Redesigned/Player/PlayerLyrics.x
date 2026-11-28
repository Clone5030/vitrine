Warning: truncated output (original token count: 5170)
Total output lines: 350

// Player redesign: the lyrics come to the player itself, the way the Music app shows them. The player
// is one screen and does not scroll (PlayerScroll.x), so the footer's lyrics glyph is the only way to
// them: it shrinks the cover into a thumbnail at the top of the artwork band, lifts the track's title
// up beside it, and fades the Apple Music style lines (Redesigned/Lyrics/SGRKaraokeView.h) into the
// room that frees between the title and the progress bar. Tapping it again puts the cover back.
//
// Nothing of Spotify's is taken apart for it. The cover is the Kit's now playing artwork drawn again
// in a view of the redesign's own, flown from where Spotify's cover is drawn to where the thumbnail
// belongs, while Spotify's list of covers goes to alpha 0 underneath: one view to move instead of a
// paging list of them, and the two pictures are the same one, so the swap is not seen. The title row
// is Spotify's own unit translated, the way PlayerFooter.x moves the footer's controls -- a transform
// survives the stack view laying its arranged views out again -- with a mask over it where the controls
// it moved toward begin, so a long title fades out before them instead of running under them. The row
// of chips over it (Switch to video) goes while the lines are up, since they take the room it sits in.
//
// Tree (trees/clean/player/01.txt): SPTNowPlayingView (:26) holds the content layers, the header row
// (:91), and id=npv.bottomStackView {0, 576.67, 402, 236} (:127) whose arranged views are the
// information unit {0, 0, 402, 64} (:160, the title, the artist and the add button), the duration unit
// {0, 64, 402, 40} (:209), the controls (:240) and the footer (:295). The title is
// id=now-playing-title-label and the artist id=now-playing-subtitle-label (:174, :185), both inside one
// arranged element view {12, 2.33, 304, 43.33} of the unit's row. Every measurement here is taken from
// the views themselves, since a player with a volume row or another mode's units has other numbers.
//
// The geometry is re-applied on every layout pass of the units, since a new track rebuilds the
// elements inside them, and it is undone before the player closes: the bar morphs back into a full
// size cover, which a thumbnail would not match.
#import <UIKit/UIGestureRecognizerSubclass.h>
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Redesigned/Lyrics/SGRKaraokeView.h"
#import "Redesigned/Lyrics/SGRSingButton.h"
#import "Settings/SGPageStyle.h"
#import "Shared/Sing/Sing.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/LocalFiles/LocalFiles.h"
#import "Player.h"

static const CGFloat kThumbSide = 72;          // the cover once the lyrics are up
static const CGFloat kThumbGap = 16;           // between the thumbnail and the title beside it
static const CGFloat kTitleGap = 12;           // between the title and the controls at the trailing edge
static const CGFloat kTitleFade = 20;          // over how much of its end a title too long to fit fades out
static const CGFloat kThumbTop = 8;            // below the top of the artwork band
static const CGFloat kLyricsTop = 20;          // between the title row and the first line
static const CGFloat kLyricsBottom = 8;        // above the progress bar
// The lines are a surface arriving, not something moving: they come up from just under full size as the
// room for them opens, and go at once when it closes. An exit the eye waits through reads as a stall.
static const CGFloat kLyricsEnterScale = 0.96;
static const NSTimeInterval kLyricsIn = 0.3, kLyricsInDelay = 0.12, kLyricsOut = 0.16;
// A track that changes while the lines are up has this long to bring its own before they are put away. A
// look for them still running then is waited out, since a local file's sources are asked one after another,
// up to 6 s each, with a Musixmatch token fetched first the first time.
static const NSTimeInterval kLyricsGrace = 3;
// Below this the player has not laid out yet and nothing can be measured from it.
static const CGFloat kLivingHeight = 200;
// The lines on their own: the controls under them fade after this long without a touch.
static const NSTimeInterval kRest = 4;

static char kOverlayKey, kPlateKey, kTitleKey, kStackKey;
static BOOL sg_open;
static BOOL sg_moving;                      // the transition is in flight, so no layout pass may re-place it
static __weak UIView *sg_host;              // SPTNowPlayingView
static __weak UIViewController *sg_info, *sg_duration, *sg_floating, *sg_header;
static __weak UIView *sg_titleElement;      // the arranged element view holding the title and the artist
static __weak UIViewController *sg_player;  // NowPlayingViewController, whose units the controls are
static BOOL sg_alone;                       // the lines have the player to themselves
static BOOL sg_touching;                    // a finger is on the player, which holds the clock (SGRPlayerTouchWatcher)
static NSTimer *sg_rest;
static __weak UIGestureRecognizer *sg_wake; // on the player, on while alone: the tap that brings the controls back

#pragma mark - the overlay

// The thumbnail and the lines, side by side under one view so the lines' own view has no sibling of
// ours to hide: SGRKaraokeView takes the whole of whatever it is put in and dims what is next to it.
@interface SGRPlayerLyricsOverlay : UIView
@property (nonatomic, readonly) UIView *thumb;       // the cover, at full size, moved by its transform
@property (nonatomic, readonly) UIImageView *cover;
@property (nonatomic, readonly) UIView *stage;       // holds the lines' view alone
@property (nonatomic, readonly) SGRKaraokeView *lyrics;
@end

@implementation SGRPlayerLyricsOverlay {
    UIView *_thumb, *_stage;
    UIImageView *_cover;
    SGRKaraokeView *_lyrics;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _thumb = [[UIView alloc] initWithFrame:CGRectZero];
    // A tap on the cover beside the lines brings the full player back.
    [_thumb addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(sgr_thumbTapped)]];
    _thumb.isAccessibilityElement = YES;
    _thumb.accessibilityLabel = @"Show the player";
    _thumb.accessibilityTraits = UIAccessibilityTraitButton;
    _cover = [[UIImageView alloc] initWithFrame:CGRectZero];
    _cover.contentMode = UIViewContentModeScaleAspectFill;
    _cover.clipsToBounds = YES;
    _cover.layer.cornerCurve = kCACornerCurveContinuous;
    _cover.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_thumb addSubview:_cover];
    _stage = [[UIView alloc] initWithFrame:CGRectZero];
    [self addSubview:_stage];
    [self addSubview:_thumb];
    return self;
}

- (void)sgr_thumbTapped {
    if (SGRPlayerLyricsOpen() && !sg_moving) SGRPlayerToggleLyrics();
}

- (UIView *)thumb { return _thumb; }
- (UIImageView *)cover { return _cover; }
- (UIView *)stage { return _stage; }

// The lines seek when they are tapped and the thumbnail brings the player back, so everywhere else the
// overlay would only swallow touches: a view that takes them does, even with nothing on it.
//
// What it hands them to instead is the title row. Translated to the top of the player it is drawn well
// outside the stack view it is arranged in, and UIKit stops looking at a view whose bounds the touch is
// not in, so the add button and the menu that rode up with it are past Spotify's own reach. Asked here
// directly, the row answers for where it is drawn. Not while the lines are alone: the row is faded then,
// and a tap where its add button was is the player's, which brings everything back.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit != self) return hit;
    UIView *row = SGRPlayerLyricsOpen() && !sg_alone ? sg_info.viewIfLoaded : nil;
    UIView *inRow = row ? [row hitTest:[row convertPoint:point fromView:self] withEvent:event] : nil;
    return inRow == row ? nil : inRow;
}

// Made on the first tap and kept afterward: it measures the song for its width before it can place a
// line, so a view built again on every tap would show nothing for the first frames. Out of the window
// it costs nothing -- its display link only runs while it is in one.
- (SGRKaraokeView *)lyrics {
    if (!_lyrics) {
        _lyrics = [[SGRKaraokeView alloc] initWithFrame:_stage.bounds];
        _lyrics.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        // Sing's mic stays while the lines are on their own, moving down with them (setAlone).
        _lyrics.keepsSing = YES;
    }
    if (_lyrics.superview != _stage) [_stage addSubview:_lyrics];
    _lyrics.frame = _stage.bounds;
    return _lyrics;
}

@end

static SGR…670 tokens truncated…row);
    l.shift = title ? kThumbSide + kThumbGap : 0;
    CGFloat lines = MAX(CGRectGetMaxY(l.thumb), top + row.size.height) + kLyricsTop;
    l.stage = CGRectMake(CGRectGetMinX(area), lines, area.size.width, CGRectGetMinY(bar) - kLyricsBottom - lines);
    l.ok = l.stage.size.height > kLivingHeight / 2 && l.lift < 0;
    return l;
}

#pragma mark - the title row

// Where the row's trailing controls start, in the unit's coordinates: the nearest arranged view on the
// trailing side of the title that is still there to be seen. The title may not reach it.
static CGFloat trailingEdgeIn(UIView *info) {
    UIView *title = sg_titleElement, *row = title.superview;
    if (!title || !row) return CGFLOAT_MAX;
    CGFloat titleLeft = CGRectGetMinX(untransformed(title, info));
    CGFloat limit = CGRectGetMaxX(SGFrameIn(row, info));
    for (UIView *view in row.subviews) {
        if (view == title || view.hidden || view.alpha < 0.01 || view.bounds.size.width < 1) continue;
        CGFloat x = CGRectGetMinX(SGFrameIn(view, info));
        if (x > titleLeft && x < limit) limit = x;
    }
    return limit;
}

// The title moved right by the thumbnail would run into the add button beside it, and it cannot simply
// be narrowed: Spotify lays its marquee labels out with constraints, which put the width back the next
// time anything in the row lays out -- and a long title, being a marquee, lays out often. A mask on the
// element takes no part in that, so it holds between passes, and it fades the title out where Spotify's
// own fade would have been rather than cutting it.
static void clipTitle(UIView *element, CGFloat width) {
    CGRect bounds = element.bounds;
    if (width >= bounds.size.width - 0.5 || bounds.size.height < 1) {
        element.layer.mask = nil;
        return;
    }
    CAGradientLayer *mask = [element.layer.mask isKindOfClass:CAGradientLayer.class] ? (CAGradientLayer *)element.layer.mask : nil;
    if (!mask) {
        mask = [CAGradientLayer layer];
        mask.colors = @[(id)UIColor.whiteColor.CGColor, (id)UIColor.whiteColor.CGColor, (id)UIColor.clearColor.CGColor];
        mask.startPoint = CGPointMake(0, 0.5);
        mask.endPoint = CGPointMake(1, 0.5);
        element.layer.mask = mask;
    }
    CGFloat fade = MIN(kTitleFade, width);
    CGRect frame = CGRectMake(0, 0, MAX(0, width), bounds.size.height);
    if (CGRectEqualToRect(frame, mask.frame)) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    mask.frame = frame;
    mask.locations = @[@0, @(width > 0 ? (width - fade) / width : 0), @1];
    [CATransaction commit];
}

// The unit's row lays its arranged views out after the unit's own pass, so the transforms go on after it.
static void placeTitleRow(SGRLyricsLayout l) {
    UIView *info = sg_info.viewIfLoaded;
    if (!info) return;
    [SGRowIn(info) layoutIfNeeded];
    CGFloat lift = sg_open ? l.lift : 0, shift = sg_open ? l.shift : 0;
    CGAffineTransform rise = CGAffineTransformMakeTranslation(0, round(lift));
    if (!CGAffineTransformEqualToTransform(info.transform, rise)) info.transform = rise;
    UIView *title = sg_titleElement;
    if (!title) return;
    CGAffineTransform slide = CGAffineTransformMakeTranslation(round(shift), 0);
    if (!CGAffineTransformEqualToTransform(title.transform, slide)) title.transform = slide;
    // Closed it reaches as far as Spotify meant it to; moved, only as far as the controls it moved toward.
    CGFloat room = CGFLOAT_MAX;
    if (sg_open) room = trailingEdgeIn(info) - kTitleGap - (CGRectGetMinX(untransformed(title, info)) + shift);
    clipTitle(title, room);
}

#pragma mark - opening and closing

BOOL SGRPlayerLyricsAvailable(void) {
    NSString *track = SGKaraokePlayingTrack();
    return track != nil && SGKaraokeLinesForTrack(track) != nil;
}

BOOL SGRPlayerLyricsOpen(void) {
    return sg_open;
}

// Puts the overlay's own views where the measurements say, without animating. The thumbnail is laid out
// at the size and place Spotify draws its cover at and moved by its transform alone, so a pass that
// runs while it is up leaves it exactly where the eye has it: the two are worked out from one
// measurement. Bounds and a center, not a frame, since both views can be under a transform.
static void place(SGRPlayerLyricsOverlay *overlay, UIView *host, SGRLyricsLayout l) {
    overlay.frame = CGRectUnion(l.cover, CGRectUnion(l.thumb, l.stage));
    CGRect cover = [overlay convertRect:l.cover fromView:host], stage = [overlay convertRect:l.stage fromView:host];
    overlay.thumb.bounds = CGRectMake(0, 0, cover.size.width, cover.size.height);
    overlay.thumb.center = CGPointMake(CGRectGetMidX(cover), CGRectGetMidY(cover));
    overlay.cover.frame = overlay.thumb.bounds;
    SGRShadowPlate *plate = SGRShadowPlateIn(overlay.thumb, &kPlateKey);
    plate.bounds = overlay.thumb.bounds;
    plate.center = CGPointMake(CGRectGetMidX(overlay.thumb.bounds), CGRectGetMidY(overlay.thumb.bounds));
    overlay.stage.bounds = CGRectMake(0, 0, stage.size.width, stage.size.height);
    overlay.stage.center = CGPointMake(CGRectGetMidX(stage), CGRectGetMidY(stage));
}

// Where the thumbnail's view has to go to land on `l.thumb`, as a transform about its own center: the
// shadow and the corners travel with it that way, instead of a shadow redrawn on every frame.
static CGAffineTransform thumbTransform(SGRLyricsLayout l) {
    CGFloat scale = l.cover.size.width > 0 ? l.thumb.size.width / l.cover.size.width : 1;
    CGAffineTransform move = CGAffineTransformMakeTranslation(round(CGRectGetMidX(l.thumb) - CGRectGetMidX(l.cover)),
                                                             round(CGRectGetMidY(l.thumb) - CGRectGetMidY(l.cover)));
    return CGAffineTransformConcat(CGAffineTransformMakeScale(scale, scale), move);
}

// The corners as they will be drawn: a radius under a scale is drawn scaled, so the thumbnail asks for
// the radius it wants divided by the shrink, and the two ends of the animation are 12pt and 8pt corners.
static CGFloat thumbRadius(SGRLyricsLayout l, BOOL open) {
    if (!open) return SGRRadiusArtwork;
    CGFloat scale = l.cover.size.width > 0 ? l.thumb.size.width / l.cover.size.width : 1;
    return scale > 0 ? SGRRadiusCover / scale : SGRRadiusArtwork;
}

#pragma mark - the lines on their own

// After kRest without a touch while the song plays, everything but the lines fades -- the header row, the
// thumbnail, the title row and the controls -- and the lines grow up and down into the whole safe area, the
// way the Music app leaves its lyrics alone. The lines scroll as they always do and leave the rest hidden; a
// tap anywhere brings it all back and is not a seek. A pause brings it back and keeps it; VoiceOver, a sheet
// over the player and the app in the background keep it up. A scroll through the lines hides it at once.
// Sing's mic stays with the lines, and a touch on it is the mic's: it does not bring the rest back.
//
// The tap is a recognizer on the player that recognizes with any other, and a button takes its own tap:
// UIKit gives a control its tap over a tap recognizer above it. A faded view takes no touch (UIKit's hit
// test skips it), so a tap where the thumbnail or a button was only wakes. A drag or a second finger fails
// it. The lines' own tap, the one that seeks, is off while they are alone, which holds whichever of the two
// would have finished first.

// What fades: every view of Spotify's bottom stack but the chips (gone while the lines are up), which is the
// title row, the progress bar, the buttons, the footer and a volume row where the phone has one; the header
// row's unit; and the thumbnail. Each fades by its alpha and the stack is left alone. Without the stack, the
// units by name. Only views on screen are taken, and only the ones faded (sg_faded) come back, so nothing
// Spotify keeps hidden is shown.
static NSHashTable<UIView *> *sg_faded;

static NSArray<UIView *> *fadingViews(void) {
    UIView *floating = sg_floating.viewIfLoaded;
    NSMutableArray<UIView *> *views = [NSMutableArray array];
    SGRPlayerLyricsOverlay *overlay = objc_getAssociatedObject(sg_host, &kOverlayKey);
    UIView *header = sg_header.viewIfLoaded, *thumb = overlay.thumb;
    if (header && !header.hidden && header.alpha > 0.01) [views addObject:header];
    if (thumb && !thumb.hidden && thumb.alpha > 0.01) [views addObject:thumb];
    UIView *stack = SGRFindByIdentifier(sg_host, @"npv.bottomStackView", &kStackKey);
    if (stack) {
        for (UIView *view in stack.subviews) {
            if ([floating isDescendantOfView:view]) continue;
            if (!view.hidden && view.alpha > 0.01) [views addObject:view];
        }
        return views;
    }
    static NSArray<NSString *> *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{

        names = @[@"InformationElementsUnit", @"DurationElementUnit", @"PlaybackControlsElementsUnit", @"FooterElementsUnit"];
    });
    // A unit's view answers to its controller as its next responder, wherever the unit sits in the tree.
    SGForEachView(sg_host, ^(UIView *view) {
        UIResponder *owner = view.nextResponder;
        if (![owner isKindOfClass:UIViewController.class] || ((UIViewController *)owner).viewIfLoaded != view) return;
        NSString *name = NSStringFromClass(owner.class);
        for (NSString *unit in names) {
            if ([name hasSuffix:unit] && !view.hidden && view.alpha > 0.01) [views addObject:view];
        }
    });
    return views;
}

static void fadeControls(BOOL faded) {
    if (!sg_faded) sg_faded = [NSHashTable weakObjectsHashTable];
    if (faded) {
        for (UIView *view in fadingViews()) {
            view.alpha = 0;
            [sg_faded addObject:view];
        }
    } else {
        for (UIView *view in sg_faded) view.alpha = 1;
        [sg_faded removeAllObjects];
    }
}

// Where the lines go on their own: the whole safe area, kLyricsBottom in at both ends, over everything that
// faded. The safe area keeps them from under the status bar and the Dynamic Island.
static CGRect aloneStage(UIView *host, SGRLyricsLayout l) {
    CGRect safe = UIEdgeInsetsInsetRect(host.bounds, host.safeAreaInsets);
    CGFloat top = CGRectGetMinY(safe) + kLyricsBottom;
    return CGRectMake(CGRectGetMinX(l.stage), top, l.stage.size.width, CGRectGetMaxY(safe) - kLyricsBottom - top);
}

// The lines' tap seeks, so it is off while they are alone. Back on a turn of the run loop later: the tap
// that brought the controls back is still being handed round, and must not reach it.
static void letLinesSeek(SGRPlayerLyricsOverlay *overlay, BOOL seek) {
    void (^apply)(void) = ^{
        if (seek == sg_alone) return;   // alone again since
        for (UIGestureRecognizer *recognizer in overlay.lyrics.gestureRecognizers) {
            if ([recognizer isKindOfClass:UITapGestureRecognizer.class]) recognizer.enabled = seek;
        }
    };
    if (seek) dispatch_async(dispatch_get_main_queue(), apply);
    else apply();
}

static void setAlone(BOOL alone, BOOL animated);

// A sheet, a menu or an alert over the player: the top controller on screen is not one the player is drawn
// in. The queue, devices and ⋯ sheets can be presented from the player's topmost parent rather than the
// player, which the player's own presentedViewController would miss, and Sing's explanation is an alert on
// the top controller (SGRSingButton.m).
static BOOL coveredBySheet(void) {
    UIViewController *top = SGTopController();
    UIView *host = sg_host;
    if (!top.viewIfLoaded || !host || [host isDescendantOfView:top.viewIfLoaded]) return NO;
    static NSUInteger logged;
    if (logged++ < 3) SGLog(@"redesign player: %@ over the player keeps the controls up", NSStringFromClass(top.class));
    return YES;
}

// Whether the clock runs: the lines up with the controls, the song playing with the app in front, no finger
// on the player and VoiceOver off (which keeps the controls up, and starts the clock again when it goes).
static BOOL mayCount(void) {
    SPTPlayerState *state = SGPlayerState();
    UIView *host = sg_host;
    return SGEnabled(SGRKeyLyricsAutoHide) && sg_open && !sg_alone && !sg_touching && host.window && state && !state.isPaused
        && !UIAccessibilityIsVoiceOverRunning()
        && UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
}

// Whether the controls may fade as it runs out: not under a sheet, nor while Sing gets ready.
static BOOL mayRest(void) {
    return mayCount() && !coveredBySheet() && SGSingCurrentState() != SGSingStatePreparing;
}

// The clock starts again at every touch. Run out while something keeps the controls up (a sheet, Sing getting
// ready, lines still being measured), it starts over, so they fade once that has gone.
static void restartRest(void) {
    [sg_rest invalidate];
    sg_rest = nil;
    if (!mayCount()) return;
    sg_rest = [NSTimer scheduledTimerWithTimeInterval:kRest repeats:NO block:^(NSTimer *timer) {
        sg_rest = nil;
        if (mayRest()) setAlone(YES, YES);
        if (!sg_alone) restartRest();
    }];
}

@interface SGRPlayerTouchWatcher : UIGestureRecognizer <UIGestureRecognizerDelegate>
@end

// Sees every touch on the player and takes none. It never recognizes: it holds the clock while a finger is
// down, so a hold on Sing's slider that runs past the rest fades nothing under it, and starts the clock once
// the last finger lifts. Nothing can end its watch early, or a scroll or a hold that recognized would start
// the clock under the finger.
@implementation SGRPlayerTouchWatcher
- (instancetype)init {
    if (!(self = [super initWithTarget:nil action:nil])) return nil;
    self.delegate = self;
    self.cancelsTouchesInView = NO;
    self.delaysTouchesBegan = NO;
    self.delaysTouchesEnded = NO;
    return self;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}
- (BOOL)canBePreventedByGestureRecognizer:(UIGestureRecognizer *)other {
    return NO;
}
- (BOOL)canPreventGestureRecognizer:(UIGestureRecognizer *)other {
    return NO;
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    sg_touching = YES;
    [sg_rest invalidate];
    sg_rest = nil;
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self lifted:event];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self lifted:event];
}
- (void)lifted:(UIEvent *)event {
    for (UITouch *touch in [event touchesForGestureRecognizer:self]) {
        if (touch.phase != UITouchPhaseEnded && touch.phase != UITouchPhaseCancelled) return;
    }
    self.state = UIGestureRecognizerStateFailed;
}
// After the last finger, or the watch ended any other way.
- (void)reset {
    [super reset];
    if (!sg_touching) return;
    sg_touching = NO;
    if (!sg_alone) restartRest();
}
@end

@interface SGRPlayerWake : UITapGestureRecognizer <UIGestureRecognizerDelegate>
@end

// Takes no touch from anything under it, and lets every other recognizer have the same tap.
@implementation SGRPlayerWake
- (instancetype)init {
    if (!(self = [super initWithTarget:nil action:nil])) return nil;
    [self addTarget:self action:@selector(sgr_woke)];
    self.delegate = self;
    self.cancelsTouchesInView = NO;
    self.delaysTouchesEnded = NO;
    self.enabled = NO;
    return self;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}
// Sing's mic and its slider stay while the lines are alone, and a touch on them is theirs alone.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldReceiveTouch:(UITouch *)touch {
    for (UIView *v = touch.view; v; v = v.superview) {
        if ([v isKindOfClass:SGRSingButton.class]) return NO;
    }
    return YES;
}
- (void)sgr_woke {
    setAlone(NO, YES);
    restartRest();
}
@end

static void setAlone(BOOL alone, BOOL animated) {
    UIView *host = sg_host;
    if (alone == sg_alone || !host || (alone && !sg_open)) return;
    SGRLyricsLayout l = layoutIn(host);
    // Going alone needs somewhere to put the lines. Coming back never waits for it: the controls and the
    // lines' tap are given back even when the player can no longer be measured.
    if (alone && !l.ok) return;
    sg_alone = alone;
    if (alone) {
        [sg_rest invalidate];
        sg_rest = nil;
        l.stage = aloneStage(host, l);
    }
    SGRPlayerLyricsOverlay *overlay = objc_getAssociatedObject(host, &kOverlayKey);
    // Layout and opacity have their own timing; Reduce Motion dissolves the layout in place.
    void (^move)(void) = ^{
        if (!overlay.superview || !l.ok) return;
        place(overlay, host, l);
        overlay.thumb.transform = thumbTransform(l);
        // The lines take the new height in this same spring, so the sung line rides with the stage rather than
        // springing to the new anchor at the next line (SGRKaraokeView's layoutSubviews).
        [overlay.lyrics layoutIfNeeded];
    };
    void (^fade)(void) = ^{
        if (overlay.superview) overlay.lyrics.extrasHidden = alone;
        fadeControls(alone);
    };
    sg_wake.enabled = alone;
    if (overlay) letLinesSeek(overlay, !alone);
    if (animated) {
        SGRAnimateLayout(host, move, nil);
        // Going, the controls take their time, since nobody waits on them; coming back at a touch, they answer at
        // once, from wherever the fade out has got to.
        SGRAnimate(alone ? SGRMotionFade : SGRMotionRespond, fade, nil);
    } else {
        move();
        fade();
    }
    SGLog(@"redesign player: the lines %@", alone ? @"on their own" : @"with the controls");
}

static void setOpen(BOOL open, BOOL animated) {
    UIView *host = sg_host;
    if (open == sg_open) return;
    if (!host) {
        SGLog(@"redesign player: the lyrics were asked for before the player laid out");
        return;
    }
    SGRLyricsLayout l = layoutIn(host);
    if (open && !l.ok) {
        SGLog(@"redesign player: the lyrics have nowhere to go (stage %.0fx%.0f, lift %.0f)", l.stage.size.width, l.stage.size.height, l.lift);
        return;
    }
    // The thumbnail is the Kit's picture drawn again, and Spotify's cover goes as it appears: without a
    // picture there would be a hole where the cover was, so the cover stays and the lyrics wait.
    UIImage *picture = SGRNowPlayingArtwork(NULL, NULL);
    if (open && !picture) {
        SGLog(@"redesign player: no artwork read yet, the lyrics stay down");
        return;
    }
    if (!open) setAlone(NO, NO);
    sg_open = open;
    SGRMixingRefresh();
    SGRPlayerLyricsChanged();

    SGRPlayerLyricsOverlay *overlay = overlayIn(host);
    place(overlay, host, l);
    CGAffineTransform away = thumbTransform(l);
    // Over an animated artwork the cover is hidden, so the thumbnail fades where it sits rather than flying
    // to or from an empty slot.
    BOOL fades = SGRPlayerMotionShowing();
    // The state it starts from, so the animation has both ends of every value and nothing jumps into it.
    overlay.thumb.transform = open && !fades ? CGAffineTransformIdentity : away;
    overlay.thumb.alpha = open && fades ? 0 : 1;
    overlay.cover.layer.cornerRadius = thumbRadius(l, fades || !open);
    // Under Reduce Motion the lines only fade, without growing.
    CGAffineTransform entering = SGRReduceMotion() ? CGAffineTransformIdentity : CGAffineTransformMakeScale(kLyricsEnterScale, kLyricsEnterScale);
    if (open) {
        overlay.cover.image = SGRNowPlayingArtwork(NULL, NULL);
        overlay.stage.alpha = 0;
        overlay.stage.transform = entering;
        // Not under VoiceOver, which keeps the controls up, nor under a sheet.
        overlay.lyrics.browsingBegan = ^{
            if (!UIAccessibilityIsVoiceOverRunning() && !coveredBySheet()) setAlone(YES, YES);
        };
        // Spotify's cover goes the moment the redesign's own takes its place: the same picture at the
        // same size with the same corners, so there is nothing to see in the swap. Coming back it waits
        // for the thumbnail to land on it, or the two would be on screen at once, one of them half size.
        SGRPlayerCoverList().alpha = 0;
    }

    // Moves and fades apart, as in setAlone: Reduce Motion takes the move and keeps the thumbnail's fade over
    // an animated artwork and the chips'.
    void (^move)(void) = ^{
        overlay.thumb.transform = open || fades ? away : CGAffineTransformIdentity;
        overlay.cover.layer.cornerRadius = thumbRadius(l, open || fades);
        placeTitleRow(l);
    };
    void (^fade)(void) = ^{
        overlay.thumb.alpha = !open && fades ? 0 : 1;
        // Keep Spotify's floating action chips (including Switch to video) reachable above the lyrics.
        sg_floating.viewIfLoaded.alpha = 1;
    };
    void (^show)(void) = ^{
        overlay.stage.alpha = open ? 1 : 0;
        overlay.stage.transform = open ? CGAffineTransformIdentity : entering;
    };
    void (^settled)(BOOL) = ^(BOOL finished) {
        sg_moving = NO;
        if (sg_open) return;   // opened again while it was going away
        SGRPlayerCoverList().alpha = 1;
        [overlay removeFromSuperview];
    };

    if (!animated) {
        move();
        fade();
        show();
        settled(YES);
    } else {
        sg_moving = YES;
        // Settled once both the layout transition and the fade are done.
        __block NSInteger running = 2;
        void (^done)(BOOL) = ^(BOOL finished) {
            if (--running == 0) settled(finished);
        };
        SGRAnimateLayout(host, move, done);
        SGRAnimate(SGRMotionFade, fade, done);
        // The lines come in behind the cover leaving, and go before it comes back.
        [UIView animateWithDuration:open ? kLyricsIn : kLyricsOut delay:open ? kLyricsInDelay : 0
                            options:UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionBeginFromCurrentState
                         animations:show completion:nil];
    }
    if (open) restartRest();
    else {
        [sg_rest invalidate];
        sg_rest = nil;
    }
    SGLog(@"redesign player: lyrics %@, thumbnail %.0fx%.0f at %.0f,%.0f, title row up %.0f and right %.0f, lines %.0fx%.0f",
          open ? @"up" : @"away", l.thumb.size.width, l.thumb.size.height, l.thumb.origin.x, l.thumb.origin.y,
          -l.lift, l.shift, l.stage.size.width, l.stage.size.height);
}

void SGRPlayerToggleLyrics(void) {
    if (!sg_open && !SGRPlayerLyricsAvailable()) return;
    setOpen(!sg_open, YES);
}

// A layout pass, a new track or a turn of the phone: the state is put back where it belongs without
// animating, since the frames it is measured from have just changed.
static void replace(void) {
    UIView *host = sg_host;
    if (!host || sg_moving) return;   // a pass in the middle of the transition would cut it short
    SGRLyricsLayout l = layoutIn(host);
    if (sg_open && !l.ok) return;
    placeTitleRow(l);
    // Keep Spotify's floating action chips (including Switch to video) reachable above the lyrics.
    sg_floating.viewIfLoaded.alpha = 1;
    if (!sg_open) return;
    SGRPlayerLyricsOverlay *overlay = objc_getAssociatedObject(host, &kOverlayKey);
    if (!overlay.superview) return;
    if (overlay.superview == host && host.subviews.lastObject != overlay) [host bringSubviewToFront:overlay];
    if (sg_alone) {
        l.stage = aloneStage(host, l);
        fadeControls(YES);
    }
    place(overlay, host, l);
    overlay.thumb.transform = thumbTransform(l);
    overlay.cover.layer.cornerRadius = thumbRadius(l, YES);
    overlay.lyrics.frame = overlay.stage.bounds;
    SGRPlayerCoverList().alpha = 0;
}

#pragma mark - the units

%hook _TtC19NowPlaying_ViewImpl24NowPlayingViewController
- (void)viewDidLayoutSubviews {
    %orig;

    UIView *host = ((UIViewController *)self).viewIfLoaded;
    if (!host || host.bounds.size.height < kLivingHeight) return;
    sg_player = (UIViewController *)self;
    if (sg_host != host) {
        sg_host = host;
        [host addGestureRecognizer:[SGRPlayerTouchWatcher new]];
        SGRPlayerWake *wake = [SGRPlayerWake new];
        [host addGestureRecognizer:wake];
        sg_wake = wake;
        SGLog(@"redesign player: the lyrics have the player's view %.0fx%.0f", host.bounds.size.width, host.bounds.size.height);
    }
    replace();
}

// The bar morphs back out of a full size cover as the player closes, so the thumbnail is put away first.
- (void)viewWillDisappear:(BOOL)animated {
    if (sg_open) setOpen(NO, NO);
    // The landscape screen outlives the lines for a track without lyrics, but not the player.
    SGRPlayerShowLandscape(NO);
    %orig;
}
%end

// The ordinary player's units and the AI DJ's (DJMInformationUnitViewController, DJMDurationElementsUnit, which
// hold the same title row and progress bar) are measured the same way, so the DJ's player has these lyrics too.
static void informationUnitLaidOut(UIViewController *unit) {
    sg_info = unit;
    UIView *host = unit.viewIfLoaded;
    // The title and the artist are two labels of one arranged element view, which is what moves.
    UIView *label = SGRFindByIdentifier(host, @"now-playing-title-label", &kTitleKey);
    UIView *element = nil;
    for (UIView *v = label; v && v != host; v = v.superview) {
        if ([v.superview isKindOfClass:UIStackView.class]) { element = v; break; }
    }
    if (element && sg_titleElement != element) {
        UIView *oldTitle = sg_titleElement;
        oldTitle.transform = CGAffineTransformIdentity;
        oldTitle.layer.mask = nil;
        sg_titleElement = element;
        // Spotify replaces the arranged title element on track changes. Do not carry the old
        // lyrics-open horizontal offset into the newly-created row before measuring it.
        element.transform = CGAffineTransformIdentity;
        element.layer.mask = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ SGLog(@"redesign player: the title rides on %@ %@", NSStringFromClass(element.class), NSStringFromCGRect(element.frame)); });
    }
    replace();
}

static void durationUnitLaidOut(UIViewController *unit) {
    sg_duration = unit;
    replace();
}

%hook _TtC20NowPlaying_ModesImpl23InformationElementsUnit
- (void)viewDidLayoutSubviews {
    %orig;
    informationUnitLaidOut((UIViewController *)self);
}
%end

%hook _TtC20NowPlaying_ModesImpl19DurationElementUnit
- (void)viewDidLayoutSubviews {
    %orig;
    durationUnitLaidOut((UIViewController *)self);
}
%end

// The header row (the down arrow, Playing from, the ⋯; PlayerHeader.x has its tree), which fades with the
// controls while the lines are alone.
%hook _TtC20NowPlaying_ModesImpl18HeaderElementsUnit
- (void)viewDidLayoutSubviews {
    %orig;
    sg_header = (UIViewController *)self;
    replace();
}
%end

// The DJ player units are other classes, hooked only when the build has them (see %ctor).
%group SGRDJInformationHooks
%hook SGRDJInformationUnit
- (void)viewDidLayoutSubviews {
    %orig;
    informationUnitLaidOut((UIViewController *)self);
}
%end
%end

// The DJ's header row fades with the rest while the lines are alone.
%group SGRDJHeaderFadeHooks
%hook SGRDJHeaderFadeUnit
- (void)viewDidLayoutSubviews {
    %orig;
    sg_header = (UIViewController *)self;
    replace();
}
%end
%end

%group SGRDJDurationHooks
%hook SGRDJDurationUnit
- (void)viewDidLayoutSubviews {
    %orig;
    durationUnitLaidOut((UIViewController *)self);
}
%end
%end

// The chips over the title (Switch to video and whatever else a track brings) sit in the middle of the
// room the lines take, so they go while the lines are up. The row keeps its height: the rest of the
// bottom stack stays where it was, which is the whole point of lifting only the title out of it.
%hook _TtC20NowPlaying_ModesImpl20FloatingElementsUnit
- (void)viewDidLayoutSubviews {
    %orig;
    sg_floating = (UIViewController *)self;
    replace();
}
%end

#pragma mark - the track changing under them

@interface SGRPlayerLyricsWatcher : NSObject <SGPlayerStateObserver>
@end

@implementation SGRPlayerLyricsWatcher {
    NSString *_track;
    BOOL _graceOver;   // the track playing has had its kLyricsGrace
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    // An edit of a local file's names gives it a new lyrics key, and the sources search again under it.
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(editsChanged:) name:SGLocalFileEditsDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(linesKept:) name:SGKaraokeLinesKeptNotification object:nil];
    return self;
}

// A rename is looked up like a new track, so lines that stay up with none for the new names go once the
// look for them ends, as a new track's do after the grace.
- (void)editsChanged:(NSNotification *)note {
    if (![note.object isKindOfClass:NSString.class] || ![note.object isEqualToString:_track]) return;
    SGRPlayerLyricsChanged();
}

// Lines kept for the track playing, or the look for them over with none. The glyph is told only when they
// are here, since SGRPlayerLyricsChanged sets the animated artwork's blur each time.
- (void)linesKept:(NSNotification *)note {
    if (![note.object isEqual:SGKaraokePlayingTrack()]) return;
    if (SGRPlayerLyricsAvailable()) SGRPlayerLyricsChanged();
    else [self closeIfNone];
    SGRPlayerLandscapeLinesChanged();
}

- (BOOL)none {
    return _graceOver && !SGRPlayerLyricsAvailable() && !SGKaraokeLooking(SGKaraokePlayingTrack());
}

// The lines go once the grace is over and nothing is looking for the track's own any more.
- (void)closeIfNone {
    if (!_graceOver || !sg_open || SGRPlayerLyricsAvailable() || SGKaraokeLooking(SGKaraokePlayingTrack())) return;
    SGLog(@"redesign player: no lyrics for the track that came on, the cover is back");
    setOpen(NO, YES);
}

- (void)playerStateDidChange:(SPTPlayerState *)state {
    // A pause brings the controls back and keeps them; playing again starts the clock.
    if (state.isPaused) {
        setAlone(NO, YES);
        [sg_rest invalidate];
        sg_rest = nil;
    } else if (!sg_rest && !sg_alone) {
        restartRest();
    }
    NSString *track = SGURIString(state.track.URI);
    if (!track || [track isEqualToString:_track]) return;
    _track = track;
    _graceOver = NO;
    SGRPlayerLyricsChanged();
    // The lines already up wait out a grace for the new track's before they go, a track after it its own.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kLyricsGrace * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (![self->_track isEqualToString:track]) return;
        self->_graceOver = YES;
        [self closeIfNone];
        SGRPlayerLandscapeLinesChanged();
    });
}

@end

static SGRPlayerLyricsWatcher *sg_watcher;

BOOL SGRPlayerLyricsNone(void) {
    return [sg_watcher none];
}

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    Class djInformation = SGRDJClass(@"DJMInformationUnitViewController");
    if (djInformation) { %init(SGRDJInformationHooks, SGRDJInformationUnit = djInformation); }
    Class djDuration = SGRDJClass(@"DJMDurationElementsUnit");
    if (djDuration) { %init(SGRDJDurationHooks, SGRDJDurationUnit = djDuration); }
    Class djHeader = SGRDJClass(@"DJMHeaderElementsUnitViewController");
    if (djHeader) { %init(SGRDJHeaderFadeHooks, SGRDJHeaderFadeUnit = djHeader); }
    sg_watcher = [SGRPlayerLyricsWatcher new];
    SGAddPlayerStateObserver(sg_watcher);
    // In the background the controls stay up; back in front the clock starts again.
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        setAlone(NO, NO);
        [sg_rest invalidate];
        sg_rest = nil;
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        restartRest();
        // The lyrics button asked again on the way back and twice after, as the lines can land in the meantime;
        // it stayed dimmed after an instrumental heard in the background.
        SGRPlayerLyricsChanged();
        for (NSNumber *wait in @[@1, @3]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ SGRPlayerLyricsChanged(); });
        }
    }];
    // VoiceOver keeps the controls up: turned on, it brings them back.
    [NSNotificationCenter.defaultCenter addObserverForName:UIAccessibilityVoiceOverStatusDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        setAlone(NO, YES);
        restartRest();
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:SGRNowPlayingArtworkDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        if (!sg_open) return;
        SGRPlayerLyricsOverlay *overlay = objc_getAssociatedObject(sg_host, &kOverlayKey);
        overlay.cover.image = SGRNowPlayingArtwork(NULL, NULL);
    }];
    SGRequireClasses(@[
        @"_TtC19NowPlaying_ViewImpl24NowPlayingViewController",
        @"_TtC20NowPlaying_ModesImpl23InformationElementsUnit",
        @"_TtC20NowPlaying_ModesImpl19DurationElementUnit",
        @"_TtC20NowPlaying_ModesImpl20FloatingElementsUnit",
        @"_TtC20NowPlaying_ModesImpl18HeaderElementsUnit",
    ]);
}

