// The redesign's Apple Music style lyrics, always on: the line being sung lights up word by word, the
// rest dim and blur with distance. Lines two voices sing at once are lit together, an instrumental
// break holds three dots, and a line can show its pronunciation and its translation under it. The
// lines and the clock are Shared/Lyrics/Lyrics.h's.
//
// Only words the source timed are swept. A line timed by the line lights up whole as it starts, as
// Apple Music lights such a line, unless the Lyrics page's "Simulate word-by-word timing" asks for
// its estimated words to be swept; lyrics with no timing at all are shown as plain text, every line
// lit, nothing following the clock.
#import <NaturalLanguage/NaturalLanguage.h>
#import "Core/SGCore.h"
#import "SGRKaraokeView.h"
#import "LyricsText.h"
#import "LyricsLook.h"
#import "MeaningSheet.h"
#import "SGRSingButton.h"
#import "Shared/Sing/Sing.h"
#import "Shared/LyricsSources/LyricsSources.h"
#import "Shared/LyricsTranslation/LyricsTranslation.h"
#import "Settings/SGPageStyle.h"
#import "Shared/Player/PlayerEvents.h"
#import "Shared/Player/PlayerState.h"
#import "Shared/Haptics/Haptics.h"
#import "Redesigned/Kit/SGRGlass.h"
#import "Redesigned/Kit/SGRTokens.h"

// The size of the words and the room between lines are the Lyrics page's (LyricsLook.h).
static const CGFloat kMargin = 24, kRowTighten = 2;
static const CGFloat kDimAlpha = 0.3, kFillEdge = 22, kLift = 2.5, kDimScale = 0.97;
static const CGFloat kAnchor = 0.28;   // where the sung line rests, as a share of the height
static const CGFloat kEdgeFade = 0.1;  // the lines fade out over this share at the top and bottom
static const CGFloat kBlurPerLine = 1.4, kMaxBlur = 6;   // Apple Music's, scaled by the Lyrics page's blur
// The (oh, aye) hanging under a line: smaller, a little dimmer, and just clear of it.
static const CGFloat kBackingScale = 0.62, kBackingAlpha = 0.8, kBackingGap = 4;
// The mark of a line Genius explains: a bubble after it for the artist's own word, a dotted underline
// for anyone else's.
static const CGFloat kBubbleSide = 22, kBubbleGap = 8, kBubbleGlyph = 11, kBubbleAlpha = 0.75, kBubbleReach = 14;
static const CGFloat kUnderlineDrop = 1, kUnderlineWidth = 2, kUnderlineAlpha = 0.35;
// The line naming the source, under the lyrics, which fade out above it and the buttons beside it. It
// wraps onto a second line rather than run under the buttons beside it, and a tap this far around it
// opens the pages it links to.
static const CGFloat kCreditSize = 12, kCreditGap = 12, kCreditSlop = 8;
// The button for the pronunciation and the translation, in the bottom leading corner as Apple Music
// has it, and the gap between it and the credit beside it. The translate glyph is half again as wide as the
// mic's across from it, so it is drawn smaller to weigh the same: 14 pt is about the mic's 17 pt in area.
static const CGFloat kExtrasSide = 44, kExtrasBottom = 12, kExtrasGlyph = 14;
static const CGFloat kSingWidth = 34, kSingHeight = 88;   // Sing's capsule: long and skinny
static char kExtrasGlassKey;
static const NSTimeInterval kRestyleFade = 0.3;   // the lines crossfading to a new style
static const NSTimeInterval kBrowseHold = 3;   // after scrolling by hand, how long until it follows the song again
static const double kFloatMinMs = 700, kFloatLeadMs = 80;   // a short word still floats up this slowly
// A word held this long starts to glow, and one held kGlowFullMs glows fully. The glow grows over the
// word and fades over kGlowFadeMs after it.
static const double kGlowFromMs = 900, kGlowFullMs = 2400, kGlowFadeMs = 450;
static const CGFloat kGlowRadius = 9, kGlowOpacity = 0.85;
// The room the sweep's mask leaves around the lit part of a word for its glow: past the widest shadow's
// visible tail, so the glow is cut nowhere but at the sweep's feathered edge (issue #68).
static const CGFloat kGlowReach = kGlowRadius * 4;
// How strongly the glow and the wave below are drawn, the Lyrics page's (LyricsLook.h), 1 being as here.
static CGFloat sgr_glowScale = 1, sgr_waveScale = 1;
// A word held long enough to glow lifts its letters one after another as the sweep reaches each, a wave
// running through it, as high as this share of the font for the word held longest: a letter starts up a
// little before the sweep's edge reaches its middle and is up over this share of the word's time. They come
// down with the glow once the word is sung, and the wave is left out under Reduce Motion.
static const CGFloat kWaveShare = 0.1;
static const double kWaveLead = 0.08, kWaveSpan = 0.3;
// A line lit whole: how long its words take to come up to full white, and to float up together.
static const NSTimeInterval kWholeFade = 0.35;
static const double kWholeRiseMs = 900;
static const double kClockSnapMs = 250, kClockPull = 0.08;
// After a tap seeks to a line, the clock holds at it until the player reports a position this near it,
// or for this long at the most: the player takes a few frames to report a seek.
static const double kSeekNearMs = 500;
static const CFTimeInterval kSeekWait = 1.5;
// Lines get views this far outside the visible part, in screen heights: half a screen above it
// and below, and a quarter more before a view is let go. Every view held is one more for the window
// to take in and let go when the lyrics come up; a line comes into view about once in three seconds,
// and a page flung by hand fills in at a few lines a frame.
static const CGFloat kSightBehind = 0.5, kSightAhead = 0.5, kSightSlack = 0.25;
static const NSTimeInterval kTransitionSlack = 0.05;   // after the player's animation, before the link is back
static NSString *const kBlurPath = @"filters.gaussianBlur.inputRadius";
// Two voices can sing at once, rarely more; past this many, the latest ones wait their turn.
enum { kMostSung = 6 };
// A pause in the singing this long is an instrumental break, and three dots hold its place: from the
// end of the last line sung before it to the start of the next, or from the top of the song to the
// first line. BiniLyrics' web player, which copies Apple Music's, draws them from seven seconds.
static const NSInteger kBreakMinMs = 7000;
// The dots' size and the room between them, as shares of the font, which is Apple Music's proportion.
static const CGFloat kDotShare = 0.5, kDotGapShare = 0.27;
// Their timeline, Apple Music's as that player reads it off: in over 0.4 s, breathing between 85 % and
// 112 % of their size in eight second cycles, filling one after another, then swelling to 120 % and
// shrinking away in 0.35 s, which ends half a second before the next line starts so it has that long
// to move up into their place. A cycle is timed to end small, so the swell starts from the bottom.
// They wait a quarter of a second before they come, for the line before them to move up out of the way.
static const double kBreakWait = 0.25, kBreakIn = 0.4, kBreakFadeIn = 0.16, kBreathHalf = 4, kBreathLow = 0.85, kBreathHigh = 1.12;
static const double kBreakOut = 0.35, kBreakSwell = 1.2, kBreakSwellShare = 0.35, kBreakCollapse = 0.5;
// The dots' clock is set again only once it is this far from the song's, or the song stops or starts.
static const double kBreakSlack = 0.03;
// A position that has not moved for this long is a paused player, not two frames between readings.
static const CFTimeInterval kStillFor = 0.1;
// How long after the last thing set moving the page's link drops its rate: past the longest placement
// (0.3 s of delay and a 0.7 s spring) and a sung line's 0.9 s sink.
static const CFTimeInterval kCalmAfter = 1.5;

@interface CAFilter : NSObject
+ (instancetype)filterWithType:(NSString *)type;
@end

// Whether a line is written right to left, told by its first letter the way the Unicode bidi algorithm
// tells a paragraph's direction. Each line is asked on its own, since a song can mix scripts, and the
// phone's language has no say in it.
static BOOL readsRightToLeft(NSString *text) {
    static NSCharacterSet *rightToLeft, *leftToRight;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableCharacterSet *scripts = [NSMutableCharacterSet new];
        [scripts addCharactersInRange:NSMakeRange(0x0590, 0x370)];    // Hebrew, Arabic, Syriac, Thaana, N'Ko and on
        [scripts addCharactersInRange:NSMakeRange(0xFB1D, 0x2E3)];    // Hebrew and Arabic presentation forms
        [scripts addCharactersInRange:NSMakeRange(0xFE70, 0x90)];     // Arabic presentation forms B
        [scripts addCharactersInRange:NSMakeRange(0x10800, 0x800)];   // the old scripts written right to left
        [scripts addCharactersInRange:NSMakeRange(0x1E800, 0x800)];   // Mende Kikakui and Adlam
        NSMutableCharacterSet *letters = [NSCharacterSet.letterCharacterSet mutableCopy];
        [letters formIntersectionWithCharacterSet:scripts.invertedSet];
        leftToRight = [letters copy];
        [scripts formIntersectionWithCharacterSet:NSCharacterSet.letterCharacterSet];
        rightToLeft = [scripts copy];
    });
    NSUInteger first = [text rangeOfCharacterFromSet:rightToLeft].location;
    return first != NSNotFound && first < [text rangeOfCharacterFromSet:leftToRight].location;
}

// Laid against the right edge: a line written right to left, or a second voice's written left to right.
static BOOL alignsRight(SGKaraokeLine *line) {
    return (line.align == SGKaraokeAlignTrailing) != readsRightToLeft(SGKaraokeLineText(line));
}

static UILabel *wordLabel(NSString *text, UIFont *font, UIColor *color, CGRect frame, BOOL rightToLeft) {
    UILabel *label = [[UILabel alloc] initWithFrame:frame];
    label.text = text;
    label.font = font;
    label.textColor = color;
    if (!rightToLeft) return label;
    // A word of a line written right to left is set in the line's direction, so the punctuation at its
    // ends falls where the whole line would put it, a word of a left to right script among them too.
    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    paragraph.baseWritingDirection = NSWritingDirectionRightToLeft;
    label.attributedText = [[NSAttributedString alloc] initWithString:text attributes:@{
        NSFontAttributeName: font, NSForegroundColorAttributeName: color, NSParagraphStyleAttributeName: paragraph}];
    return label;
}

#pragma mark - a word

// The word twice: dim underneath, white on top behind a mask whose feathered edge slides across it,
// from the edge its script starts at.
@interface SGRKaraokeWordView : UIView
@property (nonatomic, readonly) SGKaraokeWord *word;
@property (nonatomic, readonly) UIView *lit;   // a label, or for a word that waves a view of its letters
@property (nonatomic) CGFloat offset;   // where the word starts along its line, rows laid end to end
// Lit with the rest of its line at once rather than swept, and floated up with it over riseStart to
// riseEnd, which are the word's own times until the sweep says otherwise.
@property (nonatomic) BOOL whole;
@property (nonatomic) double riseStart, riseEnd;
- (void)fillTo:(CGFloat)cursor;
- (void)floatAt:(double)ms;
- (void)settle;   // land and unglow at once
- (void)land;     // back down from its float
- (void)unglow;   // the glow off
@end

@implementation SGRKaraokeWordView {
    CAGradientLayer *_fill;
    CGFloat _filled, _lift, _glow;
    BOOL _rightToLeft;
    // A word that waves: its letters, dim and lit, each letter's middle as a share of the word's width,
    // and how high each is lifted now.
    NSArray<UILabel *> *_dimLetters, *_litLetters;
    CGFloat *_letterAt, *_letterLift;
    CGFloat _waveHeight;
}

// The word set letter by letter, each where the whole word would put it, in a view the word's size.
static UIView *lettersOf(NSArray<NSString *> *letters, NSArray<NSNumber *> *xs, UIFont *font, UIColor *color, CGSize size,
                         NSMutableArray<UILabel *> *made) {
    UIView *run = [[UIView alloc] initWithFrame:(CGRect){CGPointZero, size}];
    for (NSUInteger i = 0; i < letters.count; i++) {
        CGFloat x = xs[i].doubleValue, next = i + 1 < xs.count ? xs[i + 1].doubleValue : size.width;
        UILabel *label = wordLabel(letters[i], font, color, CGRectMake(x, 0, ceil(next - x) + 2, size.height), NO);
        [run addSubview:label];
        [made addObject:label];
    }
    return run;
}

- (instancetype)initWithWord:(SGKaraokeWord *)word font:(UIFont *)font rightToLeft:(BOOL)rightToLeft {
    CGSize size = [word.text sizeWithAttributes:@{NSFontAttributeName: font}];
    self = [super initWithFrame:CGRectMake(0, 0, ceil(size.width), ceil(font.lineHeight))];
    if (!self) return nil;
    _word = word;
    _riseStart = word.start;
    _riseEnd = word.end;
    _rightToLeft = rightToLeft;
    // Only a word held long enough to glow waves, and only one written left to right: a script that joins
    // its letters, as Arabic does, cannot be set a letter at a time.
    NSMutableArray<NSString *> *letters = [NSMutableArray array];
    NSMutableArray<NSNumber *> *xs = [NSMutableArray array];
    if (word.end - word.start >= kGlowFromMs && !rightToLeft && !SGRReduceMotion()) {
        NSDictionary *attributes = @{NSFontAttributeName: font};
        [word.text enumerateSubstringsInRange:NSMakeRange(0, word.text.length) options:NSStringEnumerationByComposedCharacterSequences
                                   usingBlock:^(NSString *letter, NSRange range, NSRange enclosing, BOOL *stop) {
            [letters addObject:letter];
            [xs addObject:@([[word.text substringToIndex:range.location] sizeWithAttributes:attributes].width)];
        }];
    }
    if (letters.count > 1) {
        NSMutableArray<UILabel *> *dim = [NSMutableArray array], *lit = [NSMutableArray array];
        [self addSubview:lettersOf(letters, xs, font, [UIColor colorWithWhite:1 alpha:kDimAlpha], self.bounds.size, dim)];
        _lit = lettersOf(letters, xs, font, UIColor.whiteColor, self.bounds.size, lit);
        _dimLetters = dim;
        _litLetters = lit;
        _letterAt = calloc(letters.count, sizeof(CGFloat));
        _letterLift = calloc(letters.count, sizeof(CGFloat));
        for (NSUInteger i = 0; i < letters.count; i++) {
            CGFloat next = i + 1 < xs.count ? xs[i + 1].doubleValue : size.width;
            _letterAt[i] = (xs[i].doubleValue + next) / 2 / MAX(size.width, 1);
        }
        _waveHeight = font.pointSize * kWaveShare;
    } else {
        [self addSubview:wordLabel(word.text, font, [UIColor colorWithWhite:1 alpha:kDimAlpha], self.bounds, rightToLeft)];
        _lit = wordLabel(word.text, font, UIColor.whiteColor, self.bounds, rightToLeft);
    }
    // Hidden until the line is sung: a masked layer is drawn offscreen every frame even when the
    // mask leaves nothing of it, and a song has hundreds of words waiting their turn.
    _lit.hidden = YES;
    [self addSubview:_lit];

    CGFloat width = self.bounds.size.width + 2 * kGlowReach + kFillEdge;
    _fill = [CAGradientLayer layer];
    _fill.colors = @[(id)UIColor.whiteColor.CGColor, (id)UIColor.whiteColor.CGColor, (id)UIColor.clearColor.CGColor];
    _fill.locations = @[@0, @((width - kFillEdge) / width), @1];
    _fill.startPoint = CGPointMake(rightToLeft ? 1 : 0, 0.5);
    _fill.endPoint = CGPointMake(rightToLeft ? 0 : 1, 0.5);
    _lit.layer.mask = _fill;
    _filled = NAN;
    [self fillTo:-CGFLOAT_MAX];
    return self;
}

- (void)dealloc {
    free(_letterAt);
    free(_letterLift);
}

// The cursor is in line units and the feathered edge is centered on it, so the edge runs on through
// the space into the next word instead of starting over at each one. Right to left, the mask is the
// same one turned around: white from the word's right edge, the feather `local` in from it. The white
// runs kGlowReach past the word on each side, and the edge follows the cursor that far past it, so a
// word's glow is cut only where the sweep has not reached yet.
- (void)fillTo:(CGFloat)cursor {
    CGFloat width = self.bounds.size.width, height = self.bounds.size.height;
    CGFloat local = MAX(-kFillEdge / 2, MIN(width + kGlowReach + kFillEdge / 2, cursor - _offset));
    if (local == _filled) return;
    _filled = local;
    CGFloat lit = width + 2 * kGlowReach;
    CGFloat left = _rightToLeft ? width - local - kFillEdge / 2 : local - kFillEdge / 2 - lit;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _fill.frame = CGRectMake(left, -kGlowReach, lit + kFillEdge, height + 2 * kGlowReach);
    [CATransaction commit];
}

// Rises like a critically damped spring let go as the word starts: no jolt, a long soft landing.
// x = 5 at the end of the word is 96 % of the way up.
- (void)floatAt:(double)ms {
    double x = MAX(0, ms - _riseStart + kFloatLeadMs) / MAX(_riseEnd - _riseStart, kFloatMinMs) * 5;
    CGFloat lift = kLift * (1 - (1 + x) * exp(-x));
    [self glowAt:ms];
    [self waveAt:ms];
    if (lift == _lift) return;
    _lift = lift;
    self.transform = CGAffineTransformMakeTranslation(0, -lift);
}

// How strongly a held word glows and waves: from a quarter for the shortest that does, to all of it.
static double heldStrength(double held) {
    return MIN(1, (held - kGlowFromMs) / (kGlowFullMs - kGlowFromMs) + 0.25);
}

// A held word glows, the more the longer it is held: white light around the lit part of it, since the
// sweep's mask cuts the shadow too, kGlowReach out from the lit part. Most words are too short to glow,
// and theirs is never drawn.
- (void)glowAt:(double)ms {
    double held = _word.end - _word.start;
    CGFloat glow = 0;
    if (held >= kGlowFromMs && !_whole && sgr_glowScale > 0) {
        double strength = heldStrength(held);
        double envelope = ms < _word.start ? 0
                        : ms <= _word.end ? (ms - _word.start) / held
                        : MAX(0, 1 - (ms - _word.end) / kGlowFadeMs);
        glow = round(strength * envelope * 50) / 50;   // steps of 2 %, so most frames change nothing
    }
    if (glow == _glow) return;
    _glow = glow;
    CALayer *layer = _lit.layer;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.shadowColor = UIColor.whiteColor.CGColor;
    layer.shadowOffset = CGSizeZero;
    layer.shadowRadius = kGlowRadius * (0.5 + glow / 2) * (0.75 + sgr_glowScale / 4);
    layer.shadowOpacity = MIN(1, kGlowOpacity * glow * sgr_glowScale);
    [CATransaction commit];
}

// Each letter comes up on a smoothstep as the sweep nears it and stays up while the word is held, so a
// crest runs through the word with the sweep; once it is sung they all come down as the glow fades.
- (void)waveAt:(double)ms {
    if (!_litLetters || _whole) return;
    double held = _word.end - _word.start, along = (ms - _word.start) / held;
    double fade = ms <= _word.end ? 1 : MAX(0, 1 - (ms - _word.end) / kGlowFadeMs);
    CGFloat height = _waveHeight * heldStrength(held) * fade * sgr_waveScale;
    for (NSUInteger i = 0; i < _litLetters.count; i++) {
        double p = MAX(0, MIN(1, (along - _letterAt[i] + kWaveLead) / kWaveSpan));
        CGFloat lift = round(height * p * p * (3 - 2 * p) * 4) / 4;   // quarter points, so most frames change nothing
        if (lift == _letterLift[i]) continue;
        _letterLift[i] = lift;
        CGAffineTransform up = CGAffineTransformMakeTranslation(0, -lift);
        _litLetters[i].transform = up;
        _dimLetters[i].transform = up;
    }
}

- (void)settle {
    [self land];
    [self unglow];
}

- (void)land {
    _lift = 0;
    self.transform = CGAffineTransformIdentity;
    for (NSUInteger i = 0; i < _litLetters.count; i++) {
        _letterLift[i] = 0;
        _litLetters[i].transform = CGAffineTransformIdentity;
        _dimLetters[i].transform = CGAffineTransformIdentity;
    }
}

- (void)unglow {
    _glow = 0;
    _lit.layer.shadowOpacity = 0;
}

@end

#pragma mark - how a line is set

// Which of a line's texts are shown and how big, from the Lyrics page's order of the three and the
// lyrics menu's switches: the first shown is set at the lyrics' own size, and the next two keep the
// sizes of their places whatever is hidden above them, so a translation stays the smallest with the
// pronunciation off. A song is laid out and measured by one of these, so a change of it is a new one.
@interface SGRKaraokeStyle : NSObject
@property (nonatomic, readonly) NSArray<NSNumber *> *order;   // SGRLyricsText, largest first, shown ones only
@property (nonatomic, readonly) UIFont *lyrics, *pronunciation, *translation;   // nil for a text not shown
@property (nonatomic, readonly) SGRKaraokeStyle *backing;   // the backing row's: smaller, its translation read with the line's
// The line again in Latin letters (Shared/Lyrics' romanized lyrics), at the pronunciation's place in the
// order, since it is one (the second place's while that is the first); nil while the Lyrics page has
// it off. A backing row has none.
@property (nonatomic, readonly) UIFont *romanised;
@property (nonatomic) BOOL japanese;   // the song has kana, so its kanji are read the Japanese way
- (instancetype)initWithSize:(CGFloat)size order:(NSArray<NSNumber *> *)order pronunciation:(BOOL)pronunciation translation:(BOOL)translation
                   romanised:(BOOL)romanised;
@end

// The second and third place's sizes, as shares of the first: Apple Music's 20 and 16 under its 30.
static const CGFloat kSecondShare = 0.67, kThirdShare = 0.54;

@implementation SGRKaraokeStyle

- (instancetype)initWithSize:(CGFloat)size order:(NSArray<NSNumber *> *)order pronunciation:(BOOL)pronunciation translation:(BOOL)translation
                   romanised:(BOOL)romanised {
    if (!(self = [super init])) return nil;
    CGFloat sizes[3] = {size, round(size * kSecondShare), round(size * kThirdShare)};
    NSUInteger spoken = [order indexOfObject:@(SGRLyricsTextPronunciation)];
    if (romanised) _romanised = [UIFont systemFontOfSize:spoken > 0 && spoken < 3 ? sizes[spoken] : sizes[1] weight:UIFontWeightSemibold];
    NSMutableArray<NSNumber *> *shown = [NSMutableArray array];
    for (NSUInteger place = 0; place < order.count && place < 3; place++) {
        SGRLyricsText text = order[place].integerValue;
        if ((text == SGRLyricsTextPronunciation && !pronunciation) || (text == SGRLyricsTextTranslation && !translation)) continue;
        CGFloat points = shown.count ? sizes[place] : size;
        UIFont *font = [UIFont systemFontOfSize:points weight:text == SGRLyricsTextTranslation ? UIFontWeightSemibold : UIFontWeightBold];
        if (text == SGRLyricsTextLyrics) _lyrics = font;
        else if (text == SGRLyricsTextPronunciation) _pronunciation = font;
        else _translation = font;
        [shown addObject:@(text)];
    }
    if (!_lyrics) {   // an order without the lyrics in it is not one to trust
        _lyrics = [UIFont systemFontOfSize:size weight:UIFontWeightBold];
        [shown insertObject:@(SGRLyricsTextLyrics) atIndex:0];
    }
    _order = shown;
    return self;
}

- (SGRKaraokeStyle *)backing {
    SGRKaraokeStyle *backing = [SGRKaraokeStyle new];
    backing->_lyrics = [UIFont systemFontOfSize:round(_lyrics.pointSize * kBackingScale) weight:UIFontWeightBold];
    if (_pronunciation) backing->_pronunciation = [UIFont systemFontOfSize:round(_pronunciation.pointSize * kBackingScale) weight:UIFontWeightBold];
    NSMutableArray<NSNumber *> *order = [_order mutableCopy];
    [order removeObject:@(SGRLyricsTextTranslation)];
    backing->_order = order;
    return backing;
}

@end

#pragma mark - where a line's words go

// Between a row of words and the row spelling them out under it, between one such pair and the next,
// and between two texts of a line set apart.
static const CGFloat kPairTighten = 2, kPairGap = 4, kPartGap = 6;

// Where everything of a line goes, from its text alone: each word's frame and its place along the
// sweep, the translation's frame and the backing's top. The page lays every line of a song out with
// it off the main thread to stack them, and a line view lays itself out by it when it is made, so the
// two can never disagree about a height.
@interface SGRKaraokeLayout : NSObject
@property (nonatomic) BOOL right;
@property (nonatomic) CGFloat height;
@property (nonatomic, copy) NSArray<NSValue *> *lyricFrames, *spokenFrames;
@property (nonatomic, copy) NSArray<NSNumber *> *lyricOffsets, *spokenOffsets;
@property (nonatomic) CGRect translation;   // CGRectNull without one
@property (nonatomic) CGRect romanised;     // likewise
@property (nonatomic, copy) NSString *romanisedText;
@property (nonatomic) CGFloat backingTop;   // 0 without a backing row
@end

@implementation SGRKaraokeLayout
@end

// A run of words set in rows as wide as the page: where each goes along its row, which row, and where
// it sits along the sweep, the rows laid end to end. A joined word follows the one before it flush:
// the scripts that do not space their words would otherwise read with a gap between every syllable.
typedef struct {
    CGFloat x, width, offset;
    NSUInteger row;
} SGRPlace;

static NSUInteger flow(NSArray<SGKaraokeWord *> *words, UIFont *font, CGFloat width, SGRPlace *places) {
    NSDictionary *attributes = @{NSFontAttributeName: font};
    CGFloat space = ceil([@" " sizeWithAttributes:attributes].width), x = 0, offset = 0;
    NSUInteger row = 0;
    for (NSUInteger i = 0; i < words.count; i++) {
        CGFloat wide = ceil([words[i].text sizeWithAttributes:attributes].width);
        CGFloat lead = x > 0 && !words[i].joined ? space : 0;
        if (x > 0 && x + lead + wide > width) {
            x = lead = 0;
            row++;
        }
        x += lead;
        offset += lead;
        places[i] = (SGRPlace){x, wide, offset, row};
        x += wide;
        offset += wide;
    }
    return words.count ? row + 1 : 0;
}

// Written right to left, rows are laid out left to right and turned around, so the first word is at
// the right edge and each row runs leftwards from it. Then each group of rows goes against the line's
// edge, a second voice's against the far one, as Apple Music sets the two sides of a duet apart; a
// group too wide to fit stays where its first word put it.
static void settle(CGRect *frames, NSUInteger *groups, NSUInteger count, NSUInteger groupCount, CGFloat width, BOOL rightToLeft, BOOL right) {
    if (rightToLeft) {
        for (NSUInteger i = 0; i < count; i++) frames[i].origin.x = width - CGRectGetMaxX(frames[i]);
    }
    for (NSUInteger g = 0; g < groupCount; g++) {
        CGRect extent = CGRectNull;
        for (NSUInteger i = 0; i < count; i++) {
            if (groups[i] == g) extent = CGRectUnion(extent, frames[i]);
        }
        if (CGRectIsNull(extent)) continue;
        CGFloat shift = right ? width - CGRectGetMaxX(extent) : -CGRectGetMinX(extent);
        if (right ? shift <= 0 : shift >= 0) continue;
        for (NSUInteger i = 0; i < count; i++) {
            if (groups[i] == g) frames[i].origin.x += shift;
        }
    }
}

static NSArray<NSValue *> *boxedFrames(CGRect *frames, NSUInteger count) {
    NSMutableArray<NSValue *> *boxed = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = 0; i < count; i++) [boxed addObject:[NSValue valueWithCGRect:frames[i]]];
    return boxed;
}

static NSArray<NSNumber *> *offsetsOf(SGRPlace *places, NSUInteger count) {
    NSMutableArray<NSNumber *> *offsets = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = 0; i < count; i++) [offsets addObject:@(places[i].offset)];
    return offsets;
}

// A text of words on its own, from `top`; returns where it ends.
static CGFloat layRun(NSArray<SGKaraokeWord *> *words, UIFont *font, CGFloat width, BOOL right, CGFloat top,
                      NSArray<NSValue *> **frames, NSArray<NSNumber *> **offsets) {
    NSUInteger count = words.count;
    SGRPlace *places = calloc(count + 1, sizeof(SGRPlace));
    CGRect *rects = calloc(count + 1, sizeof(CGRect));
    NSUInteger *groups = calloc(count + 1, sizeof(NSUInteger));
    NSUInteger rows = flow(words, font, width, places);
    CGFloat row = ceil(font.lineHeight) - kRowTighten, high = ceil(font.lineHeight);
    for (NSUInteger i = 0; i < count; i++) {
        rects[i] = CGRectMake(places[i].x, top + places[i].row * row, places[i].width, high);
        groups[i] = places[i].row;
    }
    NSMutableString *text = [NSMutableString string];
    for (SGKaraokeWord *word in words) [text appendString:word.text];
    settle(rects, groups, count, rows, width, readsRightToLeft(text), right);
    *frames = boxedFrames(rects, count);
    *offsets = offsetsOf(places, count);
    free(places);
    free(rects);
    free(groups);
    return top + (rows ? rows - 1 : 0) * row + high;
}

// Two texts of words where the second spells out the first, or the first the second: each row of the
// leading one with the other's words under it, each under the word it starts with, as Apple Music sets
// its pronunciation, so a syllable reads under the syllable it sounds. Returns where the pair ends.
static CGFloat layPair(NSArray<SGKaraokeWord *> *lead, UIFont *leadFont, NSArray<SGKaraokeWord *> *under, UIFont *underFont,
                       CGFloat width, BOOL right, CGFloat top, NSArray<NSValue *> **leadFrames, NSArray<NSNumber *> **leadOffsets,
                       NSArray<NSValue *> **underFrames, NSArray<NSNumber *> **underOffsets) {
    NSUInteger leads = lead.count, unders = under.count, count = leads + unders;
    SGRPlace *places = calloc(count + 1, sizeof(SGRPlace));
    CGRect *rects = calloc(count + 1, sizeof(CGRect));
    NSUInteger *groups = calloc(count + 1, sizeof(NSUInteger));
    NSUInteger rows = flow(lead, leadFont, width, places);
    flow(under, underFont, width, places + leads);   // for their places along their own sweep
    // The leading word each one goes under: the last to start by the time it does.
    NSUInteger *matched = calloc(unders + 1, sizeof(NSUInteger));
    for (NSUInteger j = 0, i = 0; j < unders; j++) {
        while (i + 1 < leads && lead[i + 1].start <= under[j].start) i++;
        matched[j] = i;
    }
    CGFloat leadRow = ceil(leadFont.lineHeight) - kRowTighten, leadHigh = ceil(leadFont.lineHeight);
    CGFloat underRow = ceil(underFont.lineHeight) - kRowTighten, underHigh = ceil(underFont.lineHeight);
    CGFloat space = ceil([@" " sizeWithAttributes:@{NSFontAttributeName: underFont}].width);
    CGFloat y = top, bottom = top;
    NSUInteger j = 0;
    for (NSUInteger r = 0; r < rows; r++) {
        for (NSUInteger i = 0; i < leads; i++) {
            if (places[i].row != r) continue;
            rects[i] = CGRectMake(places[i].x, y, places[i].width, leadHigh);
            groups[i] = r;
        }
        bottom = y + leadHigh;
        // Under the row, each word at the start of its own, pushed along past the one before it, and the
        // pieces of one word flush together, the way the row above has them. A row spelled out wider than
        // it is written, as Korean is, cannot keep to its words and still fit: it is set as plain words
        // from the edge instead, in as many rows as it takes.
        NSUInteger from = j, until = j;
        while (until < unders && places[matched[until]].row == r) until++;
        CGFloat underTop = y + leadHigh - kPairTighten, reached = 0;
        BOOL fits = YES;
        for (NSUInteger k = from; k < until && fits; k++) {
            BOOL flush = k > from && under[k].joined;
            CGFloat x = flush ? reached : MAX(places[matched[k]].x, reached + (reached > 0 ? space : 0));
            rects[leads + k] = CGRectMake(x, underTop, places[leads + k].width, underHigh);
            reached = x + places[leads + k].width;
            fits = reached <= width;
        }
        NSUInteger subRow = 0;
        if (!fits) {
            reached = 0;
            for (NSUInteger k = from; k < until; k++) {
                CGFloat wide = places[leads + k].width, lead = reached > 0 && !under[k].joined ? space : 0;
                if (reached > 0 && reached + lead + wide > width) {
                    subRow++;
                    reached = lead = 0;
                }
                rects[leads + k] = CGRectMake(reached + lead, underTop + subRow * underRow, wide, underHigh);
                reached += lead + wide;
            }
        }
        for (NSUInteger k = from; k < until; k++) groups[leads + k] = r;
        j = until;
        BOOL any = until > from;
        if (any) bottom = underTop + subRow * underRow + underHigh;
        y = any ? bottom + kPairGap : y + leadRow;
    }
    NSMutableString *text = [NSMutableString string];
    for (SGKaraokeWord *word in lead) [text appendString:word.text];
    settle(rects, groups, count, rows, width, readsRightToLeft(text), right);
    *leadFrames = boxedFrames(rects, leads);
    *underFrames = boxedFrames(rects + leads, unders);
    *leadOffsets = offsetsOf(places, leads);
    *underOffsets = offsetsOf(places + leads, unders);
    free(places);
    free(rects);
    free(groups);
    free(matched);
    return bottom;
}

// A text set as a block, wrapping as a label does, from `top`.
static CGRect blockFrame(NSString *text, UIFont *font, CGFloat width, CGFloat top) {
    CGRect bounds = [text boundingRectWithSize:CGSizeMake(width, CGFLOAT_MAX) options:NSStringDrawingUsesLineFragmentOrigin
                                    attributes:@{NSFontAttributeName: font} context:nil];
    return CGRectMake(0, top, width, ceil(bounds.size.height));
}

// The texts a line has, in the style's order, the lyrics and their pronunciation set as a pair where
// the order has them side by side, the line in Latin letters right under the lyrics where it is not
// already spelled out by the pronunciation, and the backing row after that. `right` is the side a backing
// row keeps to, its line's; -1 for a line of its own, which takes its side from its voice and script.
static SGRKaraokeLayout *layOut(SGKaraokeLine *line, CGFloat width, SGRKaraokeStyle *style, NSInteger right) {
    SGRKaraokeLayout *layout = [SGRKaraokeLayout new];
    layout.right = right >= 0 ? right : alignsRight(line);
    layout.translation = layout.romanised = CGRectNull;
    NSArray<SGKaraokeWord *> *spoken = style.pronunciation ? line.pronunciation.words : nil;
    NSString *translation = style.translation ? line.translation : nil;
    // A translator hands back a line already in the language as it was; the line says it once. It stays
    // translated, so it is not asked again.
    NSString *lineText = translation.length || style.romanised ? SGKaraokeLineText(line) : nil;
    if (translation.length && [SGLyricsBareText(translation) isEqualToString:SGLyricsBareText(lineText)]) translation = nil;
    // A source's own pronunciation, hidden, still reads better than the transform's.
    if (style.romanised && !spoken.count) {
        layout.romanisedText = line.pronunciation ? SGKaraokeLineText(line.pronunciation)
                                                  : SGLyricsRomanised(lineText, style.japanese);
    }
    NSMutableArray<NSNumber *> *parts = [NSMutableArray array];
    for (NSNumber *text in style.order) {
        if (text.integerValue == SGRLyricsTextPronunciation && !spoken.count) continue;
        if (text.integerValue == SGRLyricsTextTranslation && !translation.length) continue;
        [parts addObject:text];
    }
    NSArray<NSValue *> *frames;
    NSArray<NSNumber *> *offsets;
    CGFloat y = 0;
    for (NSUInteger p = 0; p < parts.count; p++) {
        SGRLyricsText text = parts[p].integerValue;
        if (p > 0) y += kPartGap;
        if (text == SGRLyricsTextTranslation) {
            layout.translation = blockFrame(translation, style.translation, width, y);
            y = CGRectGetMaxY(layout.translation);
            continue;
        }
        BOOL lyrics = text == SGRLyricsTextLyrics;
        BOOL paired = p + 1 < parts.count && parts[p + 1].integerValue != SGRLyricsTextTranslation;
        if (paired) {
            NSArray<NSValue *> *pairedFrames;
            NSArray<NSNumber *> *pairedOffsets;
            y = layPair(lyrics ? line.words : spoken, lyrics ? style.lyrics : style.pronunciation,
                        lyrics ? spoken : line.words, lyrics ? style.pronunciation : style.lyrics,
                        width, layout.right, y, &frames, &offsets, &pairedFrames, &pairedOffsets);
            layout.lyricFrames = lyrics ? frames : pairedFrames;
            layout.lyricOffsets = lyrics ? offsets : pairedOffsets;
            layout.spokenFrames = lyrics ? pairedFrames : frames;
            layout.spokenOffsets = lyrics ? pairedOffsets : offsets;
            p++;
            lyrics = YES;
        } else {
            y = layRun(lyrics ? line.words : spoken, lyrics ? style.lyrics : style.pronunciation, width, layout.right, y, &frames, &offsets);
            if (lyrics) {
                layout.lyricFrames = frames;
                layout.lyricOffsets = offsets;
            } else {
                layout.spokenFrames = frames;
                layout.spokenOffsets = offsets;
            }
        }
        if (lyrics && layout.romanisedText.length) {
            layout.romanised = blockFrame(layout.romanisedText, style.romanised, width, y + kPartGap);
            y = CGRectGetMaxY(layout.romanised);
        }
        if (lyrics && right < 0 && line.backing.words.count) {
            layout.backingTop = y + kBackingGap;
            y = layout.backingTop + layOut(line.backing, width, style.backing, layout.right).height;
        }
    }
    layout.height = y;
    return layout;
}

// Where each line starts in the stack, from the heights alone. Measuring text is safe off the main
// thread, and a song's worth of it is kept off it: the first card of a track lays out while the
// player is opening, and a frame that measured every line then was a frame the animation lost.
// Where each line starts in the stack, and one more: where the stack ends, which the credit follows.
static NSArray<NSNumber *> *topsOf(NSArray<SGKaraokeLine *> *lines, CGFloat width, SGRKaraokeStyle *style, CGFloat gap) {
    NSMutableArray<NSNumber *> *tops = [NSMutableArray arrayWithCapacity:lines.count + 1];
    CGFloat top = 0;
    for (SGKaraokeLine *line in lines) {
        [tops addObject:@(top)];
        top += layOut(line, width, style, -1).height + gap;
    }
    [tops addObject:@(top)];
    return tops;
}

#pragma mark - a sweep

typedef struct {
    double ms, x, slope;
} SGSweepKnot;

// One run of words lit by one sweep: a line's own, or its pronunciation's, each timed by its own words.
// A whole one lights every word of the run at once from `start`, for a run whose words are not timed.
@interface SGRKaraokeSweep : NSObject
@property (nonatomic, readonly) NSArray<SGRKaraokeWordView *> *words;
- (instancetype)initWithWords:(NSArray<SGRKaraokeWordView *> *)words wholeFrom:(double)start;
- (void)showTime:(double)ms;
@end

@implementation SGRKaraokeSweep {
    SGSweepKnot *_knots;
    NSUInteger _knotCount;
    BOOL _whole;
}

// start: NAN to sweep the words by their own times.
- (instancetype)initWithWords:(NSArray<SGRKaraokeWordView *> *)words wholeFrom:(double)start {
    if (!(self = [super init])) return nil;
    _words = words;
    _whole = !isnan(start);
    if (_whole) {
        for (SGRKaraokeWordView *word in words) {
            word.whole = YES;
            word.riseStart = start;
            word.riseEnd = start + kWholeRiseMs;
        }
        return self;
    }
    [self buildSweep];
    return self;
}

- (void)dealloc {
    free(_knots);
}

static double secant(SGSweepKnot *knots, NSUInteger i) {
    return (knots[i + 1].x - knots[i].x) / (knots[i + 1].ms - knots[i].ms);
}

// The fill cursor reaches each word's left edge as the word starts and clears the last word as it
// ends, on a monotone cubic through those points, so the pace changes between words without a kink.
- (void)buildSweep {
    _knots = calloc(_words.count + 1, sizeof(SGSweepKnot));
    if (!_words.count) return;
    for (NSUInteger i = 0; i <= _words.count; i++) {
        SGRKaraokeWordView *word = _words[MIN(i, _words.count - 1)];
        double ms = i < _words.count ? word.word.start : word.word.end;
        double x = i == 0 ? -kFillEdge / 2 : i < _words.count ? word.offset : word.offset + word.bounds.size.width + kFillEdge / 2;
        if (_knotCount && ms <= _knots[_knotCount - 1].ms) {
            _knots[_knotCount - 1].x = x;
            continue;
        }
        _knots[_knotCount++] = (SGSweepKnot){ms, x, 0};
    }
    // Fritsch-Carlson slopes: capped so the cursor never runs backwards or overshoots a word.
    for (NSUInteger k = 0; k < _knotCount; k++) {
        BOOL first = k == 0, last = k + 1 == _knotCount;
        if (first && last) break;
        if (first || last) {
            _knots[k].slope = secant(_knots, first ? 0 : k - 1);
            continue;
        }
        double before = secant(_knots, k - 1), after = secant(_knots, k);
        double h0 = _knots[k].ms - _knots[k - 1].ms, h1 = _knots[k + 1].ms - _knots[k].ms;
        _knots[k].slope = MIN(MIN(2 * before, 2 * after), (before * h1 + after * h0) / (h0 + h1));
    }
}

- (CGFloat)cursorAt:(double)ms {
    if (!_knotCount) return -CGFLOAT_MAX;
    if (ms <= _knots[0].ms) return _knots[0].x;
    if (_knotCount == 1 || ms >= _knots[_knotCount - 1].ms) return _knots[_knotCount - 1].x;
    NSUInteger k = 0;
    while (ms >= _knots[k + 1].ms) k++;
    SGSweepKnot a = _knots[k], b = _knots[k + 1];
    double h = b.ms - a.ms, u = (ms - a.ms) / h, u2 = u * u, u3 = u2 * u;
    return (2 * u3 - 3 * u2 + 1) * a.x + (u3 - 2 * u2 + u) * h * a.slope
         + (3 * u2 - 2 * u3) * b.x + (u3 - u2) * h * b.slope;
}

- (void)showTime:(double)ms {
    // A whole run is only ever shown while its line is sung, so it is lit throughout.
    CGFloat cursor = _whole ? CGFLOAT_MAX : [self cursorAt:ms];
    for (SGRKaraokeWordView *word in _words) {
        [word fillTo:cursor];
        [word floatAt:ms];
    }
}

@end

#pragma mark - a line

@interface SGRKaraokeLineView : UIView
@property (nonatomic, readonly) SGKaraokeLine *line;
// Laid against the right edge: a line written right to left, or a second voice's written left to
// right. A backing row keeps to the edge of the line it hangs under, whatever script each is in.
@property (nonatomic, readonly) BOOL right;
@property (nonatomic) BOOL active;
@property (nonatomic, copy) BOOL (^activate)(void);
@property (nonatomic) CGFloat blur;
// under: the line a backing row hangs under, nil for a line of its own. sweepsEstimates: the words of a
// line timed only by the line are swept on their estimated times, rather than lit whole.
- (instancetype)initWithLine:(SGKaraokeLine *)line width:(CGFloat)width style:(SGRKaraokeStyle *)style under:(SGRKaraokeLineView *)under
                     blurred:(BOOL)blurred sweepsEstimates:(BOOL)sweepsEstimates;
- (void)showTime:(double)ms;
// Every word lit and left so, for lyrics with no timing: nothing is sung, so nothing is dim.
- (void)showPlain;
- (void)markMeaning:(NSArray<SGLyricsMeaning *> *)meanings;
// Where the bubble can be tapped, in the line's own space; CGRectNull without one.
@property (nonatomic, readonly) CGRect bubbleTarget;
@end

// The translation and the romanized line of a line being sung, brighter than a line waiting but never
// as bright as the words.
static const CGFloat kTranslationLit = 0.6;

@implementation SGRKaraokeLineView {
    NSArray<SGRKaraokeSweep *> *_sweeps;   // the line's words, then their pronunciation's where shown
    NSArray<SGRKaraokeWordView *> *_words;   // every word of both
    NSArray<SGRKaraokeWordView *> *_lyricWords;
    UIImageView *_bubble;
    CAShapeLayer *_underline;
    UILabel *_translation, *_romanised;
    NSUInteger _generation;
    SGRKaraokeLineView *_backing;
}

// A sweep's word views, each put where the layout has it and told where it sits along the sweep.
// start: NAN for words timed one by one, else when the run lights up whole.
- (SGRKaraokeSweep *)sweepOf:(NSArray<SGKaraokeWord *> *)words font:(UIFont *)font frames:(NSArray<NSValue *> *)frames
                     offsets:(NSArray<NSNumber *> *)offsets wholeFrom:(double)start {
    if (!words.count || frames.count != words.count) return nil;
    BOOL rightToLeft = readsRightToLeft([[words valueForKey:@"text"] componentsJoinedByString:@""]);
    NSMutableArray<SGRKaraokeWordView *> *views = [NSMutableArray arrayWithCapacity:words.count];
    for (NSUInteger i = 0; i < words.count; i++) {
        SGRKaraokeWordView *view = [[SGRKaraokeWordView alloc] initWithWord:words[i] font:font rightToLeft:rightToLeft];
        CGRect frame = frames[i].CGRectValue;
        view.center = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
        view.offset = offsets[i].doubleValue;
        [self addSubview:view];
        [views addObject:view];
    }
    return [[SGRKaraokeSweep alloc] initWithWords:views wholeFrom:start];
}

// When a run of the line lights up whole, or NAN to sweep it: only words the source timed are swept,
// unless the estimate is asked for.
static double wholeFrom(SGKaraokeLine *run, BOOL sweepsEstimates) {
    if (run.timing == SGKaraokeTimingWords || (run.timing == SGKaraokeTimingLine && sweepsEstimates)) return NAN;
    return run.start;
}

- (instancetype)initWithLine:(SGKaraokeLine *)line width:(CGFloat)width style:(SGRKaraokeStyle *)style under:(SGRKaraokeLineView *)under
                     blurred:(BOOL)blurred sweepsEstimates:(BOOL)sweepsEstimates {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    _line = line;
    self.isAccessibilityElement = under == nil;
    self.accessibilityLabel = SGKaraokeLineText(line);
    self.accessibilityTraits = UIAccessibilityTraitButton;
    BOOL backing = under != nil;
    SGRKaraokeLayout *layout = layOut(line, width, style, backing ? under.right : -1);
    _right = layout.right;
    NSMutableArray<SGRKaraokeSweep *> *sweeps = [NSMutableArray array];
    SGRKaraokeSweep *sung = [self sweepOf:line.words font:style.lyrics frames:layout.lyricFrames offsets:layout.lyricOffsets
                                wholeFrom:wholeFrom(line, sweepsEstimates)];
    SGRKaraokeSweep *spoken = [self sweepOf:line.pronunciation.words font:style.pronunciation frames:layout.spokenFrames
                                    offsets:layout.spokenOffsets wholeFrom:wholeFrom(line.pronunciation, sweepsEstimates)];
    if (sung) [sweeps addObject:sung];
    if (spoken) [sweeps addObject:spoken];
    _sweeps = sweeps;
    _words = [sung.words ?: @[] arrayByAddingObjectsFromArray:spoken.words ?: @[]];
    _lyricWords = sung.words;

    if (!CGRectIsNull(layout.translation)) _translation = [self asideAt:layout.translation font:style.translation text:line.translation];
    if (!CGRectIsNull(layout.romanised)) _romanised = [self asideAt:layout.romanised font:style.romanised text:layout.romanisedText];
    if (layout.backingTop > 0) {
        _backing = [[SGRKaraokeLineView alloc] initWithLine:line.backing width:width style:style.backing under:self blurred:NO
                                            sweepsEstimates:sweepsEstimates];
        _backing.alpha = kBackingAlpha;
        _backing.frame = CGRectMake(0, layout.backingTop, width, _backing.bounds.size.height);
        [self addSubview:_backing];
    }
    NSMutableArray<NSString *> *asides = [NSMutableArray array];
    if (_translation.text.length) [asides addObject:_translation.text];
    if (_romanised.text.length) [asides addObject:_romanised.text];
    if (layout.spokenFrames.count && line.pronunciation) [asides addObject:SGKaraokeLineText(line.pronunciation) ?: @""];
    if (line.backing) [asides addObject:SGKaraokeLineText(line.backing) ?: @""];
    self.accessibilityValue = [asides componentsJoinedByString:@". "];
    for (UIView *child in self.subviews) child.accessibilityElementsHidden = YES;
    self.frame = CGRectMake(0, 0, width, layout.height);

    // Scales toward the edge its text is aligned to, and a backing row rides its line's blur.
    if (backing) return self;
    self.layer.anchorPoint = CGPointMake(_right ? 1 : 0, 0.5);
    if (!blurred) return self;
    CAFilter *blur = [NSClassFromString(@"CAFilter") filterWithType:@"gaussianBlur"];
    if (blur) self.layer.filters = @[blur];
    return self;
}

- (BOOL)accessibilityActivate {
    return self.activate ? self.activate() : NO;
}

// A text of the line set apart from its words, dim until the line is sung.
- (UILabel *)asideAt:(CGRect)frame font:(UIFont *)font text:(NSString *)text {
    UILabel *label = [[UILabel alloc] initWithFrame:frame];
    label.numberOfLines = 0;
    label.font = font;
    label.textColor = UIColor.whiteColor;
    label.alpha = kDimAlpha;
    label.textAlignment = _right ? NSTextAlignmentRight : NSTextAlignmentLeft;
    label.text = text;
    [self addSubview:label];
    return label;
}

// How many line views are made in one frame: the rest follow on the next, nearest the sung line first.
static const NSUInteger kLinesPerFrame = 4;

// Eases from wherever the blur is on screen, so a line coming into focus sharpens instead of snapping.
- (void)setBlur:(CGFloat)blur {
    if (blur == _blur) return;
    id shown = [self.layer.presentationLayer valueForKeyPath:kBlurPath];
    CGFloat from = [shown isKindOfClass:NSNumber.class] ? [shown doubleValue] : _blur;
    _blur = blur;
    if (!self.layer.filters) return;
    [self.layer setValue:@(blur) forKeyPath:kBlurPath];
    CABasicAnimation *ease = [CABasicAnimation animationWithKeyPath:kBlurPath];
    ease.fromValue = @(from);
    ease.toValue = @(blur);
    ease.duration = 0.6;
    ease.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [self.layer addAnimation:ease forKey:@"blur"];
}

- (void)setActive:(BOOL)active {
    if (active == _active) return;
    _active = active;
    self.accessibilityTraits = (self.accessibilityTraits & ~UIAccessibilityTraitSelected) | (active ? UIAccessibilityTraitSelected : 0);
    _backing.active = active;
    NSUInteger generation = ++_generation;
    if (_translation || _romanised) {
        [UIView animateWithDuration:active ? 0.3 : 0.5 delay:0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
            self->_translation.alpha = self->_romanised.alpha = active ? kTranslationLit : kDimAlpha;
        } completion:nil];
    }
    if (active) {
        NSMutableArray<SGRKaraokeWordView *> *whole = [NSMutableArray array];
        for (SGRKaraokeWordView *word in _words) {
            [word.layer removeAllAnimations];
            [word.lit.layer removeAllAnimations];
            word.lit.alpha = 1;
            word.lit.hidden = NO;
            [word fillTo:word.whole ? CGFLOAT_MAX : -CGFLOAT_MAX];
            [word settle];
            if (word.whole) [whole addObject:word];
        }
        // A line lit whole comes up to white together rather than popping on, as Apple Music's do.
        if (!whole.count) return;
        for (SGRKaraokeWordView *word in whole) word.lit.alpha = 0;
        [UIView animateWithDuration:kWholeFade delay:0 options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionAllowUserInteraction
                         animations:^{ for (SGRKaraokeWordView *word in whole) word.lit.alpha = 1; } completion:nil];
        return;
    }
    // A sung line fades back to dim rather than dropping its fill at once, and its words sink back
    // on a spring slow enough to still be seen doing it. A held word's glow is left on: the spring would
    // drop it in the first frame, and the lit word fading out takes it out with it.
    [UIView animateWithDuration:0.9 delay:0 usingSpringWithDamping:1 initialSpringVelocity:0
                        options:UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        for (SGRKaraokeWordView *word in self->_words) [word land];
    } completion:nil];
    [UIView animateWithDuration:0.5 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        for (SGRKaraokeWordView *word in self->_words) word.lit.alpha = 0;
    } completion:^(BOOL finished) {
        if (generation != self->_generation) return;
        for (SGRKaraokeWordView *word in self->_words) {
            [word fillTo:-CGFLOAT_MAX];
            [word unglow];
            word.lit.hidden = YES;
            word.lit.alpha = 1;
        }
    }];
}

- (void)showTime:(double)ms {
    for (SGRKaraokeSweep *sweep in _sweeps) [sweep showTime:ms];
    [_backing showTime:ms];   // timed on its own, so it lags the line as it is sung
}

- (void)showPlain {
    self.accessibilityTraits = UIAccessibilityTraitStaticText;
    for (SGRKaraokeWordView *word in _words) {
        word.lit.hidden = NO;
        word.lit.alpha = 1;
        [word fillTo:CGFLOAT_MAX];
    }
    _translation.alpha = _romanised.alpha = kTranslationLit;
    [_backing showPlain];
}

- (CGRect)bubbleTarget {
    return _bubble ? CGRectInset(_bubble.frame, -kBubbleReach, -kBubbleReach) : CGRectNull;
}

- (void)markMeaning:(NSArray<SGLyricsMeaning *> *)meanings {
    NSString *text = SGKaraokeLineText(self.line);
    self.accessibilityCustomActions = meanings.count ? @[[[UIAccessibilityCustomAction alloc]
        initWithName:@"Show Meaning" actionHandler:^BOOL(UIAccessibilityCustomAction *action) {
            SGRShowMeanings(text, meanings);
            return YES;
        }]] : nil;
    [_bubble removeFromSuperview];
    _bubble = nil;
    [_underline removeFromSuperlayer];
    _underline = nil;
    if (!meanings.count || !_lyricWords.count) return;
    if (meanings.firstObject.author == SGLyricsMeaningByArtist) {
        // Beside the line's last row, on the side that faces into the page: after it for a line against the left
        // edge, before it, the quote mirrored, for one against the right (a second voice, or right to left), whose
        // far end is the screen's edge.
        SGRKaraokeWordView *last = _lyricWords.lastObject;
        CGFloat rowLeft = CGFLOAT_MAX, rowRight = -CGFLOAT_MAX;
        for (SGRKaraokeWordView *word in _lyricWords) {
            if (fabs(word.center.y - last.center.y) > 1) continue;
            rowLeft = MIN(rowLeft, word.center.x - word.bounds.size.width / 2);
            rowRight = MAX(rowRight, word.center.x + word.bounds.size.width / 2);
        }
        BOOL before = alignsRight(_line);
        CGFloat x = before ? rowLeft - kBubbleGap - kBubbleSide : rowRight + kBubbleGap;
        UIImage *glyph = [UIImage systemImageNamed:@"quote.opening" withConfiguration:
                          [UIImageSymbolConfiguration configurationWithPointSize:kBubbleGlyph weight:UIImageSymbolWeightBold]];
        if (before) glyph = glyph.imageWithHorizontallyFlippedOrientation;
        _bubble = [[UIImageView alloc] initWithImage:glyph];
        _bubble.contentMode = UIViewContentModeCenter;
        _bubble.tintColor = UIColor.blackColor;
        _bubble.backgroundColor = UIColor.whiteColor;
        _bubble.layer.cornerRadius = kBubbleSide / 2;
        _bubble.alpha = kBubbleAlpha;
        _bubble.frame = CGRectMake(x, last.center.y - kBubbleSide / 2, kBubbleSide, kBubbleSide);
        _bubble.isAccessibilityElement = YES;
        _bubble.accessibilityLabel = @"Meaning from the artist";
        [self addSubview:_bubble];
        return;
    }
    // One dotted stroke under each row the line's words wrap onto.
    UIBezierPath *path = [UIBezierPath bezierPath];
    CGFloat rowY = NAN, from = 0, to = 0;
    for (SGRKaraokeWordView *word in _lyricWords) {
        CGFloat bottom = word.center.y + word.bounds.size.height / 2 + kUnderlineDrop;
        CGFloat left = word.center.x - word.bounds.size.width / 2, right = left + word.bounds.size.width;
        if (bottom != rowY) {
            if (!isnan(rowY)) {
                [path moveToPoint:CGPointMake(from, rowY)];
                [path addLineToPoint:CGPointMake(to, rowY)];
            }
            rowY = bottom;
            from = left;
            to = right;
            continue;
        }
        from = MIN(from, left);
        to = MAX(to, right);
    }
    [path moveToPoint:CGPointMake(from, rowY)];
    [path addLineToPoint:CGPointMake(to, rowY)];
    _underline = [CAShapeLayer layer];
    _underline.path = path.CGPath;
    _underline.strokeColor = [UIColor colorWithWhite:1 alpha:kUnderlineAlpha].CGColor;
    _underline.lineWidth = kUnderlineWidth;
    _underline.lineCap = kCALineCapRound;
    _underline.lineDashPattern = @[@0, @5];
    [self.layer insertSublayer:_underline atIndex:0];
}

@end

#pragma mark - a break

// Three dots in place of the lines through an instrumental break, the way Apple Music keeps a long
// pause from reading as lyrics gone missing: they come in as the break begins, breathe while it
// lasts, fill one after another over its length and swell and go as the next line comes up.
//
// All of it is one Core Animation timeline the length of the break, on a layer whose clock is laid
// against the song's: set once as the break opens and again only when the song jumps, stops or
// starts, so the frames in between cost the page nothing. The view itself is moved by the page like
// a line, so the clock is a layer inside it, where a stopped clock cannot stop that move too.
@interface SGRKaraokeBreakView : UIView
@property (nonatomic) BOOL right;         // against the right edge, where the line after it is
@property (nonatomic) BOOL rightToLeft;   // filling from the right, the way the line after it reads
- (instancetype)initWithFont:(UIFont *)font;
- (void)playFrom:(NSInteger)start to:(NSInteger)end;
- (void)showTime:(double)ms running:(BOOL)running at:(CFTimeInterval)shown;
@end

// Local time on the dots' clock is this far into the break plus this, so no animation begins at 0,
// which Core Animation reads as "now".
static const CFTimeInterval kBreakEpoch = 1;

// The rate the page's display link asks for, asked for here too: an animation that settles for less
// could hold the player's own 120 Hz animations down, as a link asking for 60 once did.
static void atFullRate(CAAnimation *animation) {
    animation.preferredFrameRateRange = CAFrameRateRangeMake(80, 120, 120);
}

static double easeOutExpo(double p) {
    return p <= 0 ? 0 : p >= 1 ? 1 : 1 - pow(2, -10 * p);
}

static double smoothstep(double p) {
    p = MAX(0, MIN(1, p));
    return p * p * (3 - 2 * p);
}

@implementation SGRKaraokeBreakView {
    CALayer *_clock, *_group;
    NSArray<CALayer *> *_dots;
    NSInteger _start;
    CGFloat _side, _gap;
}

- (instancetype)initWithFont:(UIFont *)font {
    self = [super initWithFrame:CGRectMake(0, 0, 0, ceil(font.lineHeight))];
    if (!self) return nil;
    self.userInteractionEnabled = NO;
    _side = round(font.pointSize * kDotShare);
    _gap = round(font.pointSize * kDotGapShare);
    _clock = [CALayer layer];
    _group = [CALayer layer];
    _group.bounds = CGRectMake(0, 0, 3 * _side + 2 * _gap, _side);
    NSMutableArray<CALayer *> *dots = [NSMutableArray array];
    for (NSUInteger i = 0; i < 3; i++) {
        CALayer *dot = [CALayer layer];
        dot.frame = CGRectMake(i * (_side + _gap), 0, _side, _side);
        dot.cornerRadius = _side / 2;
        dot.backgroundColor = UIColor.whiteColor.CGColor;
        dot.opacity = kDimAlpha;
        [_group addSublayer:dot];
        [dots addObject:dot];
    }
    _dots = dots;
    _group.opacity = 0;
    [_clock addSublayer:_group];
    [self.layer addSublayer:_clock];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    CGSize size = self.bounds.size, group = _group.bounds.size;
    _clock.frame = self.bounds;
    _group.position = CGPointMake(_right ? size.width - group.width / 2 : group.width / 2, size.height / 2);
    [CATransaction commit];
}

- (void)setRight:(BOOL)right {
    if (right == _right) return;
    _right = right;
    [self setNeedsLayout];
}

// The break's whole run, sampled the way the numbers above describe it: densely where the dots come
// and go, every fifth of a second through the slow breath between.
- (void)playFrom:(NSInteger)start to:(NSInteger)end {
    _start = start;
    [_group removeAllAnimations];
    for (CALayer *dot in _dots) [dot removeAllAnimations];
    double length = (end - start) / 1000.0;
    double exitAt = MAX(kBreakWait + kBreakIn, length - kBreakCollapse - kBreakOut), over = exitAt + kBreakOut;
    BOOL still = SGRReduceMotion();   // no breath and no swell, only the fades and the fill
    NSMutableArray<NSNumber *> *times = [NSMutableArray array], *scales = [NSMutableArray array], *alphas = [NSMutableArray array];
    void (^sample)(double) = ^(double t) {
        double cycle = 2 * kBreathHalf, phase = fmod(t + kBreathHalf - fmod(exitAt, cycle) + cycle, cycle);
        double low = (1 - cos(M_PI * phase / kBreathHalf)) / 2;
        double scale = (kBreathHigh + (kBreathLow - kBreathHigh) * low) * easeOutExpo((t - kBreakWait) / kBreakIn);
        double alpha = MAX(0, MIN(1, (t - kBreakWait) / kBreakFadeIn));
        if (t >= exitAt) {
            double p = (t - exitAt) / kBreakOut;
            BOOL swelling = p <= kBreakSwellShare;
            double eased = smoothstep(swelling ? p / kBreakSwellShare : (p - kBreakSwellShare) / (1 - kBreakSwellShare));
            scale = swelling ? kBreathLow + (kBreakSwell - kBreathLow) * eased : kBreakSwell * (1 - eased);
            alpha = swelling ? 1 : 1 - eased;
        }
        [times addObject:@(t / over)];
        [scales addObject:@(still ? 1 : MAX(scale, 0.001))];
        [alphas addObject:@(alpha)];
    };
    for (double t = 0; t < kBreakWait + kBreakIn; t += 0.025) sample(t);
    for (double t = kBreakWait + kBreakIn; t < exitAt; t += 0.2) sample(t);
    for (double t = exitAt; t < over; t += 0.02) sample(t);
    sample(over);

    CAKeyframeAnimation *scale = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale"];
    CAKeyframeAnimation *alpha = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
    scale.values = scales;
    alpha.values = alphas;
    for (CAKeyframeAnimation *run in @[scale, alpha]) {
        run.keyTimes = times;
        run.duration = over;
        run.beginTime = kBreakEpoch;
        run.fillMode = kCAFillModeBoth;
        run.removedOnCompletion = NO;
        atFullRate(run);
        [_group addAnimation:run forKey:run.keyPath];
    }
    // Each dot fills over its third of the time before they go, in the order the next line reads.
    for (NSUInteger i = 0; i < _dots.count; i++) {
        CABasicAnimation *fill = [CABasicAnimation animationWithKeyPath:@"opacity"];
        fill.fromValue = @(kDimAlpha);
        fill.toValue = @1;
        fill.beginTime = kBreakEpoch + (_rightToLeft ? _dots.count - 1 - i : i) * exitAt / 3;
        fill.duration = exitAt / 3;
        fill.fillMode = kCAFillModeBoth;
        fill.removedOnCompletion = NO;
        atFullRate(fill);
        [_dots[i] addAnimation:fill forKey:@"fill"];
    }
}

- (void)showTime:(double)ms running:(BOOL)running at:(CFTimeInterval)shown {
    double local = kBreakEpoch + (ms - _start) / 1000.0;
    CFTimeInterval parent = [self.layer convertTime:shown fromLayer:nil];
    BOOL stopped = _clock.speed == 0;
    double now = stopped ? _clock.timeOffset : (parent - _clock.beginTime) * _clock.speed + _clock.timeOffset;
    if (stopped != running && fabs(now - local) < kBreakSlack) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (running) {
        _clock.speed = 1;
        _clock.timeOffset = 0;
        _clock.beginTime = parent - local;
    } else {
        _clock.speed = 0;
        _clock.beginTime = 0;
        _clock.timeOffset = local;
    }
    [CATransaction commit];
}

@end

#pragma mark - the page

// When each line is sung, kept apart from the lines so the page can ask on every frame.
typedef struct {
    NSInteger start, end;   // its start, and when it is sung out (SGKaraokeSungEnd)
} SGRKaraokeSpan;

// A pause long enough for the dots, and the line after it.
typedef struct {
    NSInteger start, end, line;
} SGRKaraokeBreak;

@interface SGRCreditLabel : UILabel
@property (nonatomic, copy) BOOL (^activate)(void);
@end
@implementation SGRCreditLabel
- (BOOL)accessibilityActivate { return self.activate ? self.activate() : NO; }
@end

@interface SGRKaraokeView () <UIScrollViewDelegate, SGPlayerStateObserver>
@end

@implementation SGRKaraokeView {
    UIScrollView *_scroll;
    BOOL _browsing;
    // The anchor and the open break as they were when the page was taken by hand, which the stack keeps to
    // until it follows the song again (topOfLine:).
    CGFloat _browseAnchor;
    NSInteger _browseBreak;
    CADisplayLink *_link;
    NSTimer *_poll;              // looking a few times a second while the link is paused, nothing on the page moving
    CFTimeInterval _stirredAt;   // when something last set the page moving
    NSString *_track;
    NSArray<SGKaraokeLine *> *_lines;
    // The song is placed from its lines' heights alone; views exist for the lines in and near sight.
    NSArray<NSNumber *> *_tops;   // where each line starts in the stack
    CGFloat _stackEnd;            // where the last line's gap ends: the credit's place
    NSMutableDictionary<NSNumber *, SGRKaraokeLineView *> *_shown;   // the views there are, by line
    CGFloat _focusTop;            // the top of the line the stack is arranged around
    CGFloat _sightOffset, _sightFocus;   // what the views in sight were last chosen for
    NSUInteger _sightArrangement;
    NSUInteger _build;   // counts the songs and widths measured, so a measurement that is late is dropped
    UIFont *_font;
    // What is sung now. Most of the time one line, the one at the anchor; where voices overlap, every
    // line being sung, the stack arranged around the one that began first; through a break, none,
    // and the dots at the anchor with the line after them just below.
    SGRKaraokeSpan *_spans;
    SGRKaraokeBreak *_breaks;
    NSUInteger _breakCount;
    NSInteger _sung[kMostSung];
    NSUInteger _sungCount;
    NSInteger _focus;       // the line the stack is arranged around, -1 before the first
    NSInteger _openBreak;   // the line the open break comes before, -1 while no break is open
    NSUInteger _arrangement;   // counts the changes to the three above, for the views in sight
    SGRKaraokeBreakView *_dots;
    NSInteger _dotsLine;   // the line the break the dots are timed for comes before
    CFTimeInterval _stillSince;   // when the position stopped moving, 0 while it moves
    SGRKaraokeStyle *_style;   // how the lines were laid out
    BOOL _hasSpoken, _hasTranslation;   // whether the song has any line with either
    BOOL _untranslated;   // whether a line with words has no translation, which a translator can fill in
    SGTranslationSource *_saved;   // who made the song's saved translation and when, nil with none saved
    NSString *_savedLanguage;      // the language of that saved file: the setting can change while the lyrics are open
    BOOL _foreign;        // whether the song is in a language other than the one translations are asked in
    NSArray<SGKaraokeLine *> *_passedOver;   // lines kept for the song that changed nothing here, not looked at again
    UIView *_extrasBox;   // the Kit's glass and _extras over it, which holds none, so its alpha can fade
    UIButton *_extras;
    NSArray<SGKaraokeLine *> *_translating;   // the lines a translator is translating, nil while it is not
    SGRSingButton *_sing;   // across from _extras
    CGFloat _builtWidth, _placedHeight;
    BOOL _showing;
    CAGradientLayer *_fade;
    SGRCreditLabel *_credit;
    NSString *_creditSource;   // the source the credit was settled on, nil until the lyrics name one
    NSArray<SGLyricsLink *> *_creditLinks;
    CGFloat _fontSize, _margin, _lineGap, _blurPerLine, _maxBlur;
    BOOL _crediting;   // Show source, read once: the page asks for the source on every frame until it has one
    double _clock;
    NSInteger _reported;
    CFTimeInterval _clockTime;
    NSInteger _seekTo;      // the line a tap seeked to, held by the clock until the player reports it
    CFTimeInterval _seekAt;   // when, 0 while no seek is waiting
    BOOL _sweepsEstimates;   // the Lyrics page's "Simulate word-by-word timing", read once like the credit
    BOOL _plain;             // the song has no timing at all: every line lit, nothing follows the clock
    NSArray<SGKaraokeLine *> *_sample;   // the preview's lines, nil for the player's
    NSInteger _sampleLength;
    CFTimeInterval _sampleEpoch;
    NSDictionary<NSNumber *, NSArray<SGLyricsMeaning *> *> *_meanings;   // Genius's, by line
    NSUInteger _meaningsAsked;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.hidden = YES;
    _focus = _openBreak = -1;
    _margin = kMargin;
    [self takeLook];
    _shown = [NSMutableDictionary dictionary];
    _sightArrangement = NSUIntegerMax;
    SGAddPlayerStateObserver(self);
    _fade = [CAGradientLayer layer];
    _fade.colors = @[(id)UIColor.clearColor.CGColor, (id)UIColor.whiteColor.CGColor,
                     (id)UIColor.whiteColor.CGColor, (id)UIColor.clearColor.CGColor, (id)UIColor.clearColor.CGColor];
    _fade.locations = @[@0, @(kEdgeFade), @(1 - kEdgeFade), @1, @1];
    _scroll = [[UIScrollView alloc] initWithFrame:self.bounds];
    _scroll.layer.mask = _fade;
    _scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _scroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    _scroll.showsVerticalScrollIndicator = NO;
    _scroll.alwaysBounceVertical = YES;
    _scroll.scrollsToTop = NO;
    _scroll.delegate = self;
    [self addSubview:_scroll];
    _credit = [[SGRCreditLabel alloc] initWithFrame:CGRectZero];
    [self refreshCreditStyle];
    _credit.adjustsFontForContentSizeCategory = YES;
    _credit.hidden = YES;
    _credit.numberOfLines = 2;
    _crediting = SGFlag(SGKeyLyricsCredit, NO);
    _sweepsEstimates = SGFlag(SGKeyLyricsSimulateWords, NO);
    [_scroll addSubview:_credit];
    __weak SGRKaraokeView *weakSelf = self;
    _credit.activate = ^BOOL {
        SGRKaraokeView *page = weakSelf;
        if (!page || !page->_creditLinks.count) return NO;
        SGLyricsOpenCreditLinks(page->_creditLinks, page->_credit);
        return YES;
    };
    for (NSNotificationName name in @[UIContentSizeCategoryDidChangeNotification, UIAccessibilityDarkerSystemColorsStatusDidChangeNotification])
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(creditStyleChanged) name:name object:nil];
    _sing = [SGRSingButton new];
    _sing.hidden = !SGEnabled(SGKeySingButton);
    [self addSubview:_sing];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(singButtonChanged) name:SGSingButtonDidChangeNotification object:nil];
    [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped:)]];
    [self addGestureRecognizer:[[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(held:)]];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(playerTransitionChanged:) name:SGPlayerTransitionNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(playerTransitionChanged:) name:SGPlayerTransitionEndedNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(restyle) name:SGRLyricsTextDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(restyle) name:SGLyricsRomanisedDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(translationsChanged) name:SGLyricsTranslationsDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(sourceChosen:) name:SGLyricsSourceChosenNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(lookChanged) name:SGRLyricsLookDidChangeNotification object:nil];
    // A locked phone leaves the card in its window, so the link has to be put down by the app going
    // away rather than by the view going: see scheduleLink.
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(scheduleLink) name:UIApplicationDidBecomeActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(scheduleLink) name:UIApplicationWillResignActiveNotification object:nil];
    return self;
}

// Karaoke's settings switched the mic off or on: hidden at once, Karaoke itself as it was.
- (void)singButtonChanged {
    _sing.hidden = !SGEnabled(SGKeySingButton);
}

- (void)refreshCreditStyle {
    _credit.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption1]
        scaledFontForFont:[UIFont systemFontOfSize:kCreditSize weight:UIFontWeightSemibold] maximumPointSize:17];
    _credit.textColor = SGRSecondary();
}

- (void)creditStyleChanged {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self refreshCreditStyle];
        [self setNeedsLayout];
    });
}

- (instancetype)initWithSampleLines:(NSArray<SGKaraokeLine *> *)lines length:(NSInteger)length {
    if (!(self = [self initWithFrame:CGRectZero])) return nil;
    _sample = lines;
    _sampleLength = MAX(length, 1);
    _sampleEpoch = CACurrentMediaTime();
    _crediting = NO;
    [_sing removeFromSuperview];
    _sing = nil;
    self.userInteractionEnabled = NO;
    self.accessibilityElementsHidden = YES;   // a picture of the setting, with nothing to read or do
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    free(_spans);
    free(_breaks);
}

// The Lyrics page's look: the size and the room are the lines' layout, the blur their placing, the glow
// and the wave every held word's, so a change is the song measured again in it and crossfaded over.
- (void)takeLook {
    SGRLyricsLook look = SGRLyricsLookNow();
    _fontSize = look.size;
    _lineGap = look.spacing;
    _blurPerLine = kBlurPerLine * look.blur;
    _maxBlur = kMaxBlur * look.blur;
    sgr_glowScale = look.glow;
    sgr_waveScale = look.wave;
}

- (void)lookChanged {
    [self takeLook];
    _font = [UIFont systemFontOfSize:_fontSize weight:UIFontWeightBold];
    [_dots removeFromSuperview];   // made again in the new font, at the next frame with a break open
    _dots = nil;
    [self restyle];
}

// The preview's lines on its own clock, round and round; everything else the player's, less the
// Lyrics page's Delay (below 0 for the first moments of a song with one).
- (NSInteger)positionMs {
    if (!_sample) {
        NSInteger ms = SGKaraokePositionMs();
        return ms < 0 ? ms : ms - SGKaraokeDelayMs();
    }
    return (NSInteger)fmod((CACurrentMediaTime() - _sampleEpoch) * 1000, _sampleLength);
}

- (NSArray<SGKaraokeLine *> *)linesFor:(NSString *)track {
    return _sample ?: SGKaraokeLinesForTrack(track);
}

- (void)tapped:(UITapGestureRecognizer *)tap {
    [self stir];
    if (_extrasBox && !_extrasBox.hidden && CGRectContainsPoint(_extrasBox.frame, [tap locationInView:self])) return;
    if (_sing.userInteractionEnabled && [_sing pointInside:[tap locationInView:_sing] withEvent:nil]) return;
    if (_creditLinks.count && !_credit.hidden
        && CGRectContainsPoint(CGRectInset(_credit.frame, -kCreditSlop, -MAX(kCreditSlop, (44 - _credit.frame.size.height) / 2)),
                               [tap locationInView:_scroll])) {
        SGLyricsOpenCreditLinks(_creditLinks, _credit);
        return;
    }
    CGPoint point = [tap locationInView:_scroll];
    for (SGRKaraokeLineView *view in _shown.allValues) {
        CGRect target = view.bubbleTarget;
        if (CGRectIsNull(target) || !CGRectContainsPoint(target, [_scroll convertPoint:point toView:view])) continue;
        [self explainLine:view];
        return;
    }
    if (_plain) return;   // a line with no time has nowhere to seek to
    for (SGRKaraokeLineView *view in _shown.allValues) {
        if (!CGRectContainsPoint(CGRectInset(view.frame, -_margin, -_lineGap / 2), point)) continue;
        [self seekToLine:view.line];
        return;
    }
}

// A tap on a line, or VoiceOver activating it.
- (void)seekToLine:(SGKaraokeLine *)line {
    // The line shows Delay later than the song, so its sound is that much past its start.
    NSInteger delay = SGKaraokeDelayMs();
    SGLog(@"lyrics: tapped the line at %ld-%ld ms, the clock at %.0f ms, %ld ms of delay", (long)line.start, (long)line.end, _clock, (long)delay);
    SGKaraokeSeek(line.start + delay);
    SGPlayFeedback(SGFeedbackSkip);
    [self glideTo:line.start];
}

- (void)held:(UILongPressGestureRecognizer *)hold {
    [self stir];
    if (hold.state != UIGestureRecognizerStateBegan || !_meanings.count) return;
    if (_sing.userInteractionEnabled && [_sing pointInside:[hold locationInView:_sing] withEvent:nil]) return;
    CGPoint point = [hold locationInView:_scroll];
    for (SGRKaraokeLineView *view in _shown.allValues) {
        if (!CGRectContainsPoint(CGRectInset(view.frame, -_margin, -_lineGap / 2), point)) continue;
        [self explainLine:view];
        return;
    }
}

- (void)explainLine:(SGRKaraokeLineView *)view {
    NSNumber *index = [_shown allKeysForObject:view].firstObject;
    NSArray<SGLyricsMeaning *> *meanings = index ? _meanings[index] : nil;
    if (!meanings.count) return;
    SGPlayFeedback(SGFeedbackSkip);
    SGRShowMeanings(SGKaraokeLineText(view.line), meanings);
}

// Genius is asked once the song's lines are in; lines that change under it are matched again.
- (void)askMeanings {
    _meanings = nil;
    if (_sample) return;
    NSUInteger asked = ++_meaningsAsked;
    NSArray<SGKaraokeLine *> *lines = _lines;
    __weak SGRKaraokeView *weakSelf = self;
    SGLyricsMeaningsFor(_track, lines, ^(NSDictionary<NSNumber *, NSArray<SGLyricsMeaning *> *> *byLine) {
        SGRKaraokeView *page = weakSelf;
        if (!page || asked != page->_meaningsAsked || lines != page->_lines) return;
        page->_meanings = byLine;
        for (NSNumber *key in page->_shown) [page->_shown[key] markMeaning:byLine[key]];
    });
}

#pragma mark - scrolling by hand

// Lines are placed for a content offset of 0, so following the song means scrolling back to 0.
// While the user browses, placement stands still and every line is sharp.
- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    [self stir];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(followSong) object:nil];
    if (!_browsing) {
        _browseAnchor = self.bounds.size.height * kAnchor;
        _browseBreak = _openBreak;
    }
    _browsing = YES;
    if (self.browsingBegan) self.browsingBegan();
    for (SGRKaraokeLineView *view in _shown.allValues) view.blur = 0;
}

// In the caller's animation: the glass dematerializes by its effect and the glyph fades by its alpha, the
// one view of the two with no glass in it.
- (void)setExtrasHidden:(BOOL)hidden {
    [self stir];
    _extrasHidden = hidden;
    if (_extrasBox) {
        SGRShowGlass(SGRGlassInside(_extrasBox, &kExtrasGlassKey, kExtrasSide), !hidden);
        _extras.alpha = hidden ? 0 : 1;
        _extrasBox.userInteractionEnabled = !hidden;
    }
    _sing.tucked = hidden && !_keepsSing;
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    [self showLinesInSight];
}

// Plain text has no song to follow back to: it stays where it was scrolled to, as a page of text does.
- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    if (!decelerate && !_plain) [self performSelector:@selector(followSong) withObject:nil afterDelay:kBrowseHold];
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    if (!_plain) [self performSelector:@selector(followSong) withObject:nil afterDelay:kBrowseHold];
}

- (void)followSong {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(followSong) object:nil];
    if (!_browsing) return;
    _browsing = NO;
    [UIView animateWithDuration:0.7 delay:0 usingSpringWithDamping:0.9 initialSpringVelocity:0
                        options:UIViewAnimationOptionAllowUserInteraction
                     animations:^{ self->_scroll.contentOffset = CGPointZero; } completion:nil];
    [self placeLinesAnimated:YES];
}

// A tapped line glides to the anchor at once, and the stack with it: the clock is held at the line until
// the player reports the seek, which takes a few frames. Read before then, the position still on the line
// being sung put the stack back on it, and the seek's arrival then jumped it over to the tapped one.
- (void)glideTo:(NSInteger)ms {
    [self stir];
    _seekTo = ms;
    _seekAt = CACurrentMediaTime();
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(followSong) object:nil];
    if (_browsing) {
        _browsing = NO;
        [UIView animateWithDuration:0.7 delay:0 usingSpringWithDamping:0.9 initialSpringVelocity:0
                            options:UIViewAnimationOptionAllowUserInteraction
                         animations:^{ self->_scroll.contentOffset = CGPointZero; } completion:nil];
    }
    if (!_tops) return;
    NSUInteger arrangement = _arrangement;
    [self arrangeAt:[self clockMs] glide:YES];
    // The line sung tapped again, off a page scrolled by hand: nothing moved on, so the stack is put back.
    if (_arrangement == arrangement) [self placeLinesAnimated:YES];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) {
        // The scroll goes back with the browsing: lines are placed for an offset of 0, and one left from a page
        // scrolled and closed before followSong drew every line off the anchor, none of them lit.
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(followSong) object:nil];
        _browsing = NO;
        _scroll.contentOffset = CGPointZero;
    }
    [self scheduleLink];
}

// The player opens and closes in animations that run at 120 Hz, and while a display link asked
// for 30 to 60, the range Apple's ProMotion guide says Core Animation gives priority to, those
// animations ran rough; the player and the lyrics themselves were smooth throughout. The card's
// link now asks for 60 but takes 120, and is put down for as long as the player animates, which
// NowPlayingBar.x announces as each animation starts and again as it ends. The timer is for an end
// that is never announced.
//
// The link is also put down whenever the app is not in front. Spotify keeps playing there, and a
// phone locked on the player kept the card ticking at 120 Hz against a screen that was off: 117 of
// the 137 wake ups a second the mod cost over stock Spotify were this one link, measured with
// scripts/battery-probe.sh. Nothing of the card is seen from the background, so nothing is drawn.
- (void)scheduleLink {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(startLink) object:nil];
    [_poll invalidate];
    _poll = nil;
    [_link invalidate];
    _link = nil;
    if (!self.window) return;
    NSTimeInterval wait = SGPlayerTransitionEnds() - CACurrentMediaTime();
    if (wait <= 0) [self startLink];
    else [self performSelector:@selector(startLink) withObject:nil afterDelay:wait + kTransitionSlack inModes:@[NSRunLoopCommonModes]];
}

- (void)startLink {
    if (!self.window || _link) return;
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick)];
    _link.preferredFrameRateRange = CAFrameRateRangeMake(80, 120, 120);
    _stirredAt = CACurrentMediaTime();
    [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

// The frame being drawn, or now while the link is paused.
- (CFTimeInterval)frameTime {
    return _link && !_link.paused ? _link.targetTimestamp : CACurrentMediaTime();
}

// Nothing on the page moves: the link is paused rather than slowed, because a link asking for a low rate,
// even uncapped, holds the player's 120 Hz animations back (see scheduleLink). A timer, which asks the display
// for nothing, still watches the track, its lines and the clock a few times a second.
- (void)calmDown {
    _link.paused = YES;
    __weak typeof(self) weakSelf = self;
    _poll = [NSTimer timerWithTimeInterval:0.2 repeats:YES block:^(NSTimer *timer) { [weakSelf tick]; }];
    [NSRunLoop.mainRunLoop addTimer:_poll forMode:NSRunLoopCommonModes];
}

// Something is about to move: the link back at the display's rate before its next frame.
- (void)stir {
    _stirredAt = CACurrentMediaTime();
    if (!_link.paused) return;
    [_poll invalidate];
    _poll = nil;
    _link.paused = NO;
}

// Play, pause, a new track: the clock is about to move, or the page to change.
- (void)playerStateDidChange:(SPTPlayerState *)state {
    [self stir];
}

// A seek while paused, from Spotify's own scrubber: a report that moves the position. A report that
// leaves it where it was lets the link stay calm.
- (void)playerStateDidReport:(SPTPlayerState *)state {
    if (_plain) return;
    // The player's position less the Delay, as positionMs reads it, from the state reported.
    NSInteger ms = _sample ? [self positionMs]
                           : (NSInteger)((state.isPaused ? state.positionAsOfTimestamp : state.position) * 1000) - SGKaraokeDelayMs();
    if (ms != _reported) [self stir];
}

- (void)playerTransitionChanged:(NSNotification *)note {
    [self scheduleLink];
}

// The mask sits in the scroll view's own coordinates, which move with the content as it scrolls, so
// it is put back over the visible part on every frame, where the presentation layer says the
// content is: that holds through a drag and through the animated scroll home alike. Left where
// layout put it, it covered the first screenful of lines only, and a scroll past them showed nothing.
- (void)alignFade {
    CALayer *shown = (CALayer *)_scroll.layer.presentationLayer ?: _scroll.layer;
    CGRect frame = CGRectMake(0, shown.bounds.origin.y, self.bounds.size.width, self.bounds.size.height);
    if (CGRectEqualToRect(frame, _fade.frame)) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _fade.frame = frame;
    [CATransaction commit];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self alignFade];
    _scroll.contentSize = self.bounds.size;
    // A long, skinny capsule on the trailing margin, with the same room under it as the extras button across from it.
    _sing.frame = CGRectMake(self.bounds.size.width - _margin - kSingWidth, self.bounds.size.height - kSingHeight - kExtrasBottom, kSingWidth, kSingHeight);
    if (_extrasBox && !_extrasBox.hidden) {
        _extrasBox.frame = CGRectMake(_margin, self.bounds.size.height - kExtrasSide - kExtrasBottom, kExtrasSide, kExtrasSide);
        SGRShowGlass(SGRGlassInside(_extrasBox, &kExtrasGlassKey, kExtrasSide), !_extrasHidden);
    }
    [self clearBottomRow];
    if (_lines && self.bounds.size.width != _builtWidth) {
        [self rebuild];
    } else if (_tops && self.bounds.size.height != _placedHeight) {
        // A new height moves the anchor (the player's lines going alone and back): the stack is placed for it
        // here, inside whatever animation resized the page, so the sung line rides along with it rather than
        // springing to the new anchor at the next line, and the band the height opens is filled in.
        _sightOffset = -CGFLOAT_MAX;
        [self placeLinesAnimated:NO];
    }
    _placedHeight = self.bounds.size.height;
}

// The lines fade out above the bottom row (the mic and the extras button) and stay clear under
// it, so none is read through the credit; with nothing there they fade out at the bottom edge.
- (void)clearBottomRow {
    CGFloat height = self.bounds.size.height;
    if (height <= 0) return;
    CGFloat floor = height;
    for (UIView *view in @[_sing ?: NSNull.null, _extrasBox ?: NSNull.null]) {
        if ([view isKindOfClass:UIView.class] && !view.hidden && view.superview) floor = MIN(floor, CGRectGetMinY(view.frame) - 8);
    }
    CGFloat clear = MAX(0, MIN(1, (height - floor) / height));
    NSArray *locations = @[@0, @(kEdgeFade), @(MAX(kEdgeFade, 1 - clear - kEdgeFade)), @(1 - clear), @1];
    if ([_fade.locations isEqualToArray:locations]) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _fade.locations = locations;
    [CATransaction commit];
}

- (void)dropLineViews {
    for (UIView *view in _shown.allValues) [view removeFromSuperview];
    [_shown removeAllObjects];
    _tops = nil;
    _sightArrangement = NSUIntegerMax;
    _build++;
    [self forgetSung];
}

// Nothing sung, no break open: the state a song starts from, before the clock places it. The dots
// are made again for the next, in case it is laid out in another font.
- (void)forgetSung {
    _sungCount = 0;
    _focus = _openBreak = -1;
    _arrangement++;
    [_dots removeFromSuperview];
    _dots = nil;
}

static BOOL hasTranslations(NSArray<SGKaraokeLine *> *lines) {
    for (SGKaraokeLine *line in lines) {
        if (line.translation.length) return YES;
    }
    return NO;
}

// A line with words to translate: not an empty one, nor a ♪ holding a break.
static BOOL hasWords(SGKaraokeLine *line) {
    for (SGKaraokeWord *word in line.words) {
        if ([word.text rangeOfCharacterFromSet:NSCharacterSet.letterCharacterSet].location != NSNotFound) return YES;
    }
    return NO;
}

// A way to translate a song: the lines, the track and the language in, one translation per line out, or a
// message to show. Main queue.
typedef void (^SGRTranslated)(NSArray<NSString *> *translations, NSString *error);
// `progress` may be called with the lines so far before `done`.
typedef void (^SGRTranslator)(NSArray<SGKaraokeLine *> *lines, NSString *track, NSString *language, SGRTranslated progress, SGRTranslated done);

// The lines' text for a translator, "" for a line with no words or a translation already.
static NSArray<NSString *> *textsOf(NSArray<SGKaraokeLine *> *lines) {
    NSMutableArray<NSString *> *texts = [NSMutableArray arrayWithCapacity:lines.count];
    for (SGKaraokeLine *line in lines) [texts addObject:hasWords(line) && !line.translation.length ? SGKaraokeLineText(line) ?: @"" : @""];
    return texts;
}

// Letters outside the target's script, read from the characters: past Latin for a Latin-script language, Latin for
// any other. A short Korean line or one mixed with English, which the recognizer is not sure of, still counts.
static NSUInteger otherScriptLetters(NSString *text, BOOL latinTarget) {
    __block NSUInteger count = 0;
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length) options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(NSString *character, NSRange range, NSRange enclosing, BOOL *stop) {
        UTF32Char c = 0;
        if (![character getBytes:&c maxLength:sizeof(c) usedLength:NULL encoding:NSUTF32LittleEndianStringEncoding options:0
                           range:NSMakeRange(0, character.length) remainingRange:NULL]) return;
        if (![NSCharacterSet.letterCharacterSet longCharacterIsMember:c]) return;
        BOOL latin = c < 0x250 || (c >= 0x1E00 && c < 0x1F00);
        if (latin != latinTarget) count++;
    }];
    return count;
}

// Words spelled the way Korean is in Latin letters, with "eo" or "eu" (neol, geureon, eotteoke). Spicy Lyrics'
// community syncs give some K-pop this way. Of twenty English songs checked, no line had two such words.
static NSUInteger romanizedKoreanWords(NSString *text) {
    NSUInteger count = 0;
    for (NSString *word in [text componentsSeparatedByCharactersInSet:NSCharacterSet.letterCharacterSet.invertedSet]) {
        if ([word containsString:@"eo"] || [word containsString:@"eu"]) count++;
    }
    return count;
}

// Whether a song is in a language other than `language`, line by line: one distinct line in five that the recognizer
// is at least 80% sure is another language, or two lines in another script (Hangul, kana, Han among English, for
// K-pop with only a verse in Korean). A line with two letters of another script counts however unsure the
// recognizer is: NewJeans' "New Jeans" has six such lines, all short or mixed with English. So does a line of Korean
// in Latin letters (romanizedKoreanWords). A chorus sung eight
// times weighs as one line. The whole song's guess is not asked: short lines sway it (it reads Havana, all "ooh
// na-na", as Dutch), and an unsure line counts neither way. A song with no line it is sure of counts as foreign,
// too little to tell.
static BOOL inAnotherLanguage(NSArray<SGKaraokeLine *> *lines, NSString *language) {
    NSString *(^code)(NSString *) = ^NSString *(NSString *tag) {
        return [tag componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"-_"]].firstObject.lowercaseString;
    };
    NSString *target = code(language);
    NSString *targetScript = [NSOrthography defaultOrthographyForLanguage:language].dominantScript;
    NSUInteger distinct = 0, sure = 0, foreign = 0, otherScript = 0;
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NLLanguageRecognizer *recognizer = [NLLanguageRecognizer new];
    for (SGKaraokeLine *line in lines) {
        NSString *text = hasWords(line) ? SGKaraokeLineText(line).lowercaseString : nil;
        if (!text.length || [seen containsObject:text]) continue;
        [seen addObject:text];
        distinct++;
        BOOL lettersOther = otherScriptLetters(text, [targetScript isEqualToString:@"Latn"]) >= 2;
        if (lettersOther) otherScript++;
        [recognizer reset];
        [recognizer processString:text];
        NSDictionary<NLLanguage, NSNumber *> *guess = [recognizer languageHypothesesWithMaximum:1];
        NLLanguage found = guess.allKeys.firstObject;
        BOOL confident = found && guess[found].doubleValue >= 0.8, inTarget = confident && [code(found) isEqualToString:target];
        // A line sure to be in the target language does not count as romanized Korean, so French "peu" and "heure" stay.
        if (!lettersOther && !inTarget && romanizedKoreanWords(text) >= 2) otherScript++;
        if (!confident) continue;
        sure++;
        if (inTarget) continue;
        foreign++;
        if (!lettersOther && ![[NSOrthography defaultOrthographyForLanguage:found].dominantScript isEqualToString:targetScript]) otherScript++;
    }
    return !sure || foreign * 5 >= MAX(distinct, 5) || otherScript >= 2;
}

// Whether a line with words is still without a translation.
static BOOL anyUntranslated(NSArray<SGKaraokeLine *> *lines) {
    for (SGKaraokeLine *line in lines) if (!line.translation.length && hasWords(line)) return YES;
    return NO;
}

// When each line is sung and where the breaks are, worked out once per song for the frames to read.
- (void)timeLines {
    free(_spans);
    free(_breaks);
    NSUInteger count = _lines.count;
    _spans = calloc(count + 1, sizeof(SGRKaraokeSpan));
    _breaks = calloc(count + 1, sizeof(SGRKaraokeBreak));
    _breakCount = 0;
    _hasSpoken = _hasTranslation = _untranslated = NO;
    _plain = SGKaraokeLinesTiming(_lines) == SGKaraokeTimingNone;
    _savedLanguage = SGLyricsTranslationTarget();
    _saved = _sample ? nil : SGLyricsSyncSavedTranslation(_track, _savedLanguage, _lines);
    _foreign = inAnotherLanguage(_lines, _savedLanguage);
    NSInteger sungTo = 0;   // the top of the song counts as where the singing before the first line ends
    for (NSUInteger i = 0; i < count; i++) {
        SGKaraokeLine *line = _lines[i];
        _spans[i] = (SGRKaraokeSpan){line.start, SGKaraokeSungEnd(line)};
        if (!_plain && line.start - sungTo >= kBreakMinMs) _breaks[_breakCount++] = (SGRKaraokeBreak){sungTo, line.start, (NSInteger)i};
        sungTo = MAX(sungTo, _spans[i].end);
        _hasSpoken = _hasSpoken || line.pronunciation || line.backing.pronunciation;
        _hasTranslation = _hasTranslation || line.translation.length;
        _untranslated = _untranslated || (!line.translation.length && hasWords(line));
    }
    [self offerExtras];
    [self askMeanings];
}

// Measures the song for the width and, once that is in, places it; Spotify's own lines stay in view
// until then, since the page shows nothing of its own before it has lines to show.
- (void)rebuild {
    [self dropLineViews];
    _browsing = NO;
    _scroll.contentOffset = CGPointZero;
    _builtWidth = self.bounds.size.width;
    CGFloat width = _builtWidth - 2 * _margin;
    if (width <= 0) return;
    _font = [UIFont systemFontOfSize:_fontSize weight:UIFontWeightBold];
    SGRKaraokeStyle *style = _style = [self styleNow];
    NSArray<SGKaraokeLine *> *lines = _lines;
    CGFloat gap = _lineGap;
    NSUInteger build = _build;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        NSArray<NSNumber *> *tops = topsOf(lines, width, style, gap);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (build != self->_build) return;   // the song or the width moved on meanwhile
            [self takeTops:tops];
            [self placeLinesAnimated:NO];
        });
    });
}

#pragma mark - the pronunciation and the translation

// What a line shows besides its words: what the song has, of what the lyrics menu has switched on.
- (SGRKaraokeStyle *)styleNow {
    BOOL romanised = SGFlag(SGKeyLyricsRomanised, NO);
    SGRKaraokeStyle *style = [[SGRKaraokeStyle alloc] initWithSize:_fontSize order:SGRLyricsTextOrder()
                                                     pronunciation:_hasSpoken && SGFlag(SGRKeyLyricsPronunciation, NO)
                                                       translation:_hasTranslation && SGFlag(SGRKeyLyricsTranslation, NO)
                                                         romanised:romanised];
    style.japanese = romanised && SGLyricsLooksJapanese(_lines);
    return style;
}

// A switch of the menu or the Lyrics page's order: the song is measured again in the new style off
// the main thread, as for a new width, but the lines on the page stay until it is in, and then the
// new ones crossfade over them where they were, so nothing blinks and nothing is lost of the place.
- (void)restyle {
    [self offerExtras];
    if (!_lines || !_tops || _builtWidth <= 0) return;   // the next build picks the style up
    SGRKaraokeStyle *style = [self styleNow];
    NSArray<SGKaraokeLine *> *lines = _lines;
    CGFloat width = _builtWidth - 2 * _margin, gap = _lineGap;
    NSUInteger build = ++_build;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        NSArray<NSNumber *> *tops = topsOf(lines, width, style, gap);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (build != self->_build) return;
            [self showStyle:style tops:tops];
        });
    });
}

// topsOf's answer: the lines' tops, and the stack's end apart from them.
- (void)takeTops:(NSArray<NSNumber *> *)tops {
    _stackEnd = tops.lastObject.doubleValue;
    _tops = tops.count ? [tops subarrayWithRange:NSMakeRange(0, tops.count - 1)] : tops;
}

- (void)showStyle:(SGRKaraokeStyle *)style tops:(NSArray<NSNumber *> *)tops {
    CATransition *fade = [CATransition animation];
    fade.type = kCATransitionFade;
    fade.duration = kRestyleFade;
    [_scroll.layer addAnimation:fade forKey:@"restyle"];
    for (UIView *view in _shown.allValues) [view removeFromSuperview];
    [_shown removeAllObjects];
    _style = style;
    [self takeTops:tops];
    _sightArrangement = NSUIntegerMax;
    [self placeLinesAnimated:NO];
    [self showLinesInSight];   // placing stands still while the page is scrolled by hand; the views do not
    // The new views come in as the old ones were: the lines being sung lit, and every blur where it
    // was rather than easing in from sharp, which a view made out of sight does unseen.
    for (NSUInteger i = 0; i < _sungCount; i++) [self viewForLine:_sung[i]].active = YES;
    for (SGRKaraokeLineView *view in _shown.allValues) [view.layer removeAnimationForKey:@"blur"];
}

// The button shows only for a song with a pronunciation or a translation to show, and its menu only
// what the song has: a switch for each, reading what tapping it will do.
- (void)offerExtras {
    NSString *language = SGLyricsTranslationTarget();
    // A translator is offered only for a song in another language than the one it would translate into,
    // and the translators are asked after (an AI translator's key is a Keychain read).
    BOOL wanted = _lines && !_sample && (_foreign || SGHidden(SGKeyLyricsTranslateEverySong)) && _untranslated;
    BOOL onDevice = wanted && SGFlag(SGKeyLyricsTranslateOnDevice, YES) && SGOnDeviceTranslation.translationAvailable;
    BOOL intelligence = wanted && SGFlag(SGKeyLyricsAppleIntelligence, YES) && [SGOnDeviceTranslation appleIntelligenceAvailable:language];
    BOOL ai = wanted && SGAITranslatorReady();
    BOOL translatable = ai || onDevice || intelligence;
    BOOL offered = _lines && !_sample && (_hasSpoken || _hasTranslation || translatable);
    if (!offered) {
        _extrasBox.hidden = YES;
        [self setNeedsLayout];
        return;
    }
    if (!_extras) {
        // The Kit's glass, as the mic across from it has (setExtrasHidden:), which turns solid under Reduce
        // Transparency, with a plain button over it.
        _extrasBox = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kExtrasSide, kExtrasSide)];
        _extrasBox.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        UIButtonConfiguration *config = [UIButtonConfiguration plainButtonConfiguration];
        config.image = [UIImage systemImageNamed:@"translate"];
        config.preferredSymbolConfigurationForImage = [UIImageSymbolConfiguration configurationWithPointSize:kExtrasGlyph weight:UIImageSymbolWeightSemibold];
        config.baseForegroundColor = UIColor.whiteColor;
        _extras = [UIButton buttonWithConfiguration:config primaryAction:nil];
        _extras.frame = _extrasBox.bounds;
        _extras.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _extras.showsMenuAsPrimaryAction = YES;
        _extras.preferredMenuElementOrder = UIContextMenuConfigurationElementOrderFixed;
        _extras.accessibilityLabel = @"Pronunciation and translation";
        [_extrasBox addSubview:_extras];
        [self addSubview:_extrasBox];
        self.extrasHidden = _extrasHidden;
    }
    // While a translation is worked out the glyph turns into a spinner, and the menu has nothing to ask a second time.
    BOOL translating = _translating && _translating == _lines;
    UIButtonConfiguration *config = _extras.configuration;
    if (config.showsActivityIndicator != translating) {
        config.showsActivityIndicator = translating;
        _extras.configuration = config;
        _extras.accessibilityValue = translating ? @"Translating" : nil;
    }
    NSMutableArray<UIMenuElement *> *items = [NSMutableArray array];
    if (_hasSpoken) {
        BOOL on = SGFlag(SGRKeyLyricsPronunciation, NO);
        [items addObject:[UIAction actionWithTitle:on ? @"Hide Pronunciation" : @"Show Pronunciation"
                                             image:[UIImage systemImageNamed:@"character.phonetic"] identifier:nil
                                           handler:^(UIAction *action) { SGRSetLyricsTextShown(SGRLyricsTextPronunciation, !on); }]];
    }
    if (_hasTranslation) {
        BOOL on = SGFlag(SGRKeyLyricsTranslation, NO);
        [items addObject:[UIAction actionWithTitle:on ? @"Hide Translation" : @"Show Translation"
                                             image:[UIImage systemImageNamed:@"character.bubble"] identifier:nil
                                           handler:^(UIAction *action) { SGRSetLyricsTextShown(SGRLyricsTextTranslation, !on); }]];
    }
    // Who made the saved translation and when, and for one an AI made (or no one known) a way to have it asked again.
    if (_saved && _hasTranslation) {
        UIAction *source = [UIAction actionWithTitle:_saved.name image:[UIImage systemImageNamed:@"info.circle"] identifier:nil handler:^(UIAction *action) {}];
        source.subtitle = _saved.made ? [NSDateFormatter localizedStringFromDate:_saved.made dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterShortStyle]
                                      : @"Date unknown";
        source.attributes = UIMenuElementAttributesDisabled;
        NSMutableArray<UIMenuElement *> *about = [NSMutableArray arrayWithObject:source];
        // Not while a translator works: its next batch would save the file again.
        if (_saved.deletable && !translating) {
            NSString *track = _track, *language = _savedLanguage;
            UIAction *delete = [UIAction actionWithTitle:@"Delete This Translation" image:[UIImage systemImageNamed:@"trash"] identifier:nil
                                                 handler:^(UIAction *action) { SGLyricsDeleteSavedTranslation(track, language); }];
            delete.attributes = UIMenuElementAttributesDestructive;
            [about addObject:delete];
        }
        [items addObject:[UIMenu menuWithTitle:@"Translated by" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:about]];
    }
    // Also for a song a source translated in part, as Musixmatch's community often has: the rest is filled in.
    // Said in each item: whether the song's words stay on the phone.
    if (translatable && !translating) {
        __weak SGRKaraokeView *weakSelf = self;
        void (^offer)(NSString *, NSString *, NSString *, SGTranslationSource *(^)(void), SGRTranslator) =
            ^(NSString *title, NSString *glyph, NSString *subtitle, SGTranslationSource *(^source)(void), SGRTranslator translator) {
            UIAction *action = [UIAction actionWithTitle:title image:[UIImage systemImageNamed:glyph] identifier:nil
                                                 handler:^(UIAction *action) { [weakSelf translateWith:translator source:source()]; }];
            action.subtitle = subtitle;
            [items addObject:action];
        };
        if (onDevice) {
            offer(@"Translate on iPhone", @"translate", @"Apple's Translate, on this iPhone",
                  ^{ return [SGTranslationSource by:SGTranslatedOnDevice model:nil made:nil]; },
                  ^(NSArray<SGKaraokeLine *> *lines, NSString *track, NSString *to, SGRTranslated progress, SGRTranslated done) {
                [SGOnDeviceTranslation translate:textsOf(lines) to:to done:done];
            });
        }
        if (intelligence) {
            offer(@"Translate with Apple Intelligence", @"apple.intelligence", @"On this iPhone",
                  ^{ return [SGTranslationSource by:SGTranslatedByAppleIntelligence model:nil made:nil]; },
                  ^(NSArray<SGKaraokeLine *> *lines, NSString *track, NSString *to, SGRTranslated progress, SGRTranslated done) {
                [SGOnDeviceTranslation translateWithAppleIntelligence:textsOf(lines) to:to song:SGLyricsSongName(track) progress:^(NSArray<NSString *> *soFar) { progress(soFar, nil); } done:done];
            });
        }
        // The provider and model are read as the item is tapped, which is when the request is made.
        if (ai) offer([@"Translate with " stringByAppendingString:SGAITranslatorName()], @"sparkles",
                      [@"Sends the lyrics to " stringByAppendingString:SGAITranslatorRecipient()], ^{ return SGAITranslatorSource(); },
                      ^(NSArray<SGKaraokeLine *> *lines, NSString *track, NSString *to, SGRTranslated progress, SGRTranslated done) {
            SGLyricsTranslateWithAI(track, lines, to, done);
        });
    }
    _extras.menu = [UIMenu menuWithChildren:items];
    _extrasBox.hidden = NO;
    [self setNeedsLayout];
}

// The song's lines into the Lyrics page's language, or the phone's: each line without a translation takes
// the translator's, and translations are switched on so the answer shows. The whole song goes, for the sense.
- (void)translateWith:(SGRTranslator)translator source:(SGTranslationSource *)source {
    NSArray<SGKaraokeLine *> *lines = _lines;
    NSString *track = _track;
    if (!lines.count || _translating == lines) return;
    _translating = lines;
    [self offerExtras];
    NSString *language = SGLyricsTranslationTarget();
    // Kept a batch at a time too, so a translation cut off by Spotify closing keeps what was done.
    translator(lines, track, language, ^(NSArray<NSString *> *soFar, NSString *error) {
        [self takeTranslations:soFar into:lines];
        [self saved:SGLyricsSaveTranslation(track, language, lines, source) for:lines in:language];
    }, ^(NSArray<NSString *> *translations, NSString *error) {
        if (self->_translating == lines) self->_translating = nil;
        // Translations can come with a note, which names the lines left out. Those lines stay untranslated, and
        // asking again sends only them.
        if (translations) {
            [self takeTranslations:translations into:lines];
            [self saved:SGLyricsSaveTranslation(track, language, lines, source) for:lines in:language];
            if (lines == self->_lines) self->_untranslated = anyUntranslated(lines);
        }
        [self offerExtras];
        if (error) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:translations ? @"Partly translated" : @"No translation"
                                                                           message:error preferredStyle:UIAlertControllerStyleAlert];
            // Over the player, which is dark whatever the system's appearance.
            alert.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
            [SGTopController() presentViewController:alert animated:YES completion:nil];
        }
    });
}

// A source picked from the player's ⋯ replaces the lines of the song playing, which the page otherwise keeps
// through any later answer: they are dropped as on a change of track, and the next tick takes the new ones.
- (void)sourceChosen:(NSNotification *)note {
    if (_sample || ![note.object isEqual:_track]) return;
    [self dropLines];
}

- (void)dropLines {
    _lines = nil;
    _passedOver = nil;
    _builtWidth = 0;
    [self creditTo:nil];
    [self dropLineViews];
    [self offerExtras];
}

// The menu names who made the song's translation as soon as it is saved, if the song is still the one shown.
- (void)saved:(SGTranslationSource *)source for:(NSArray<SGKaraokeLine *> *)lines in:(NSString *)language {
    if (!source || lines != _lines) return;
    _saved = source;
    _savedLanguage = language;
    [self offerExtras];
}

// The saved translations deleted, or Translate any song switched: the song is synced again and redrawn.
- (void)translationsChanged {
    if (!_lines) return;
    [self timeLines];
    [self restyle];
}

// Each line still without a translation takes the one given for it, and translations are switched on so
// they show. The lines may be another song's by now: they keep the translation, the page is left alone.
- (void)takeTranslations:(NSArray<NSString *> *)translations into:(NSArray<SGKaraokeLine *> *)lines {
    __block BOOL took = NO;
    [lines enumerateObjectsUsingBlock:^(SGKaraokeLine *line, NSUInteger i, BOOL *stop) {
        if (i < translations.count && translations[i].length && !line.translation.length) {
            line.translation = translations[i];
            line.translationMade = YES;
            took = YES;
        }
    }];
    if (!took || lines != _lines) return;
    _hasTranslation = YES;
    [self offerExtras];
    if (SGFlag(SGRKeyLyricsTranslation, NO)) [self restyle];
    else SGRSetLyricsTextShown(SGRLyricsTextTranslation, YES);
}

// Where a line starts on the page, for the stack as it is arranged now: an open break holds the room
// of one row at the anchor, and the lines from the one after it on are moved down by it.
//
// While the page is scrolled by hand the stack stands still, and so does what places it: the room can
// change meanwhile (the player's controls go as a scroll starts, and the anchor moves with the height)
// and a break can open or close, and a line made for the view then went by the new anchor while the
// lines beside it kept the old one, the two running into each other.
- (CGFloat)topOfLine:(NSInteger)index {
    CGFloat anchor = _browsing ? _browseAnchor : self.bounds.size.height * kAnchor;
    NSInteger openBreak = _browsing ? _browseBreak : _openBreak;
    CGFloat top = anchor + _tops[index].doubleValue - _focusTop;
    return openBreak >= 0 && index >= openBreak ? top + [self breakRoom] : top;
}

- (CGFloat)breakRoom {
    return ceil(_font.lineHeight) + _lineGap;
}

- (BOOL)isSung:(NSInteger)index {
    for (NSUInteger i = 0; i < _sungCount; i++) {
        if (_sung[i] == index) return YES;
    }
    return NO;
}

// How many lines away from what is sung a line is, which is what dims, shrinks and blurs it: from the
// nearest line being sung, from an open break as if it were a line of its own, and before the first
// line from the line before it, as ever.
- (NSInteger)distanceOf:(NSInteger)index {
    if (_plain) return 0;   // nothing is sung, so every line reads as clearly as the rest
    if (_openBreak >= 0) return index >= _openBreak ? index - _openBreak + 1 : _openBreak - index;
    if (!_sungCount) return labs(index - _focus);
    NSInteger nearest = NSIntegerMax;
    for (NSUInteger i = 0; i < _sungCount; i++) nearest = MIN(nearest, labs(index - _sung[i]));
    return nearest;
}

// The view of a line, made the first time it is asked for and placed where the stack has it.
- (SGRKaraokeLineView *)viewForLine:(NSInteger)index {
    __block SGRKaraokeLineView *view = _shown[@(index)];
    if (view || !_tops || index < 0 || index >= (NSInteger)_tops.count) return view;
    // Made where it belongs even inside an animation of the page's (a new height), not flown in from the corner.
    [UIView performWithoutAnimation:^{
        view = [[SGRKaraokeLineView alloc] initWithLine:self->_lines[index] width:self->_builtWidth - 2 * self->_margin style:self->_style under:nil
                                                blurred:self->_maxBlur > 0 && !self->_plain sweepsEstimates:self->_sweepsEstimates];
        __weak SGRKaraokeView *page = self;
        SGKaraokeLine *line = view.line;
        view.activate = ^BOOL {
            SGRKaraokeView *owner = page;
            if (!owner || owner->_plain || ![owner->_lines containsObject:line]) return NO;
            [owner seekToLine:line];
            return YES;
        };
        if (self->_plain) [view showPlain];
        [view markMeaning:self->_meanings[@(index)]];
        [self->_scroll addSubview:view];
        self->_shown[@(index)] = view;
        [self placeLine:view at:index animated:NO];
    }];
    return view;
}

// Views for the lines just outside the visible part as well as in it, wherever that is: around the
// sung line while following the song, around wherever the page has been scrolled to while browsing.
// The ones further off are let go, so a long song costs a couple of dozen line views rather than
// one for every line, and the lines in sight are the only ones the compositor has to draw.
- (void)showLinesInSight {
    if (!_tops.count) return;
    CGFloat offset = ((CALayer *)_scroll.layer.presentationLayer ?: _scroll.layer).bounds.origin.y;
    if (offset == _sightOffset && _focusTop == _sightFocus && _arrangement == _sightArrangement) return;
    _sightOffset = offset;
    _sightFocus = _focusTop;
    _sightArrangement = _arrangement;
    CGFloat height = self.bounds.size.height;
    CGFloat from = offset - kSightBehind * height, to = offset + (1 + kSightAhead) * height, slack = kSightSlack * height;
    NSMutableArray<NSNumber *> *gone = [NSMutableArray array];
    id focusedElement = UIAccessibilityIsVoiceOverRunning() ? UIAccessibilityFocusedElement(UIAccessibilityNotificationVoiceOverIdentifier) : nil;
    for (NSNumber *key in _shown) {
        NSInteger index = key.integerValue;
        CGFloat top = [self topOfLine:index], bottom = top + _shown[key].bounds.size.height;
        // Keep the element VoiceOver is reading even when playback moves it out of sight.
        BOOL focused = focusedElement == _shown[key];
        if (!focused && ![self isSung:index] && (bottom < from - slack || top > to + slack)) [gone addObject:key];
    }
    for (NSNumber *key in gone) {
        [_shown[key] removeFromSuperview];
        [_shown removeObjectForKey:key];
    }
    NSInteger count = (NSInteger)_tops.count;
    NSMutableArray<NSNumber *> *wanted = [NSMutableArray array];
    for (NSInteger index = 0; index < count; index++) {
        if (_shown[@(index)]) continue;
        CGFloat top = [self topOfLine:index];
        CGFloat bottom = index + 1 < count ? [self topOfLine:index + 1] - _lineGap : top + height;
        if (bottom < from || top > to) continue;
        [wanted addObject:@(index)];
    }
    // A few a frame, the nearest the middle of the visible part first, so a page scrolled by hand
    // fills in what is in view before what is not; the next frame picks up where this one left off.
    CGFloat middle = offset + height / 2;
    [wanted sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        CGFloat da = fabs([self topOfLine:a.integerValue] - middle), db = fabs([self topOfLine:b.integerValue] - middle);
        return da < db ? NSOrderedAscending : da > db ? NSOrderedDescending : NSOrderedSame;
    }];
    NSUInteger made = 0;
    for (NSNumber *index in wanted) {
        if (made++ == kLinesPerFrame) {
            _sightOffset = -CGFLOAT_MAX;
            break;
        }
        [self viewForLine:index.integerValue];
    }
}

// One line's place in the stack: the anchor sits on the edge its text is aligned to, so it scales
// toward its own text, and it dims and blurs with its distance from what is sung.
- (void)placeLine:(SGRKaraokeLineView *)view at:(NSInteger)index animated:(BOOL)animated {
    CGFloat height = self.bounds.size.height;
    NSInteger distance = [self distanceOf:index], below = index - _focus;
    CGRect frame = CGRectMake(_margin, [self topOfLine:index], view.bounds.size.width, view.bounds.size.height);
    CGPoint center = CGPointMake(view.right ? CGRectGetMaxX(frame) : _margin, CGRectGetMidY(frame));
    CGFloat scale = distance == 0 ? 1 : kDimScale;
    CGAffineTransform transform = CGAffineTransformMakeScale(scale, scale);
    view.blur = distance == 0 || _browsing ? 0 : MIN(_maxBlur, distance * _blurPerLine);
    BOOL near = CGRectIntersectsRect(CGRectInset(self.bounds, 0, -height / 2), frame)
             || CGRectIntersectsRect(CGRectInset(self.bounds, 0, -height / 2), view.frame);
    if (!animated || !near) {
        view.center = center;
        view.transform = transform;
        return;
    }
    NSTimeInterval delay = below > 0 ? MIN(0.3, below * 0.04) : 0;
    [UIView animateWithDuration:0.7 delay:delay usingSpringWithDamping:0.86 initialSpringVelocity:0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        view.center = center;
        view.transform = transform;
    } completion:nil];
}

// The sung line rests at the anchor and the rest stack around it; lines below it follow a beat
// later, the further down the later, as Apple Music's do. A line sung over it stays where it is
// below, lit; the stack moves on to it once the line at the anchor is sung out.
- (void)placeLinesAnimated:(BOOL)animated {
    [self stir];
    if (_browsing || !_tops.count) return;
    _focusTop = _tops[(NSUInteger)MAX(_focus, 0)].doubleValue;
    [self showLinesInSight];
    for (NSNumber *key in _shown) [self placeLine:_shown[key] at:key.integerValue animated:animated];
    [self placeBreak];
    [self placeCreditAnimated:animated];
    // Room to scroll until the first line or the last one reaches the anchor.
    CGFloat lastTop = _tops.lastObject.doubleValue + (_openBreak >= 0 ? [self breakRoom] : 0);
    _scroll.contentInset = UIEdgeInsetsMake(_focusTop, 0, MAX(0, lastTop - _focusTop), 0);
}

// The credit, under the last line as Spotify's and Apple Music's are: it moves with the stack, so it is seen at the
// song's end or scrolled to, rather than over every line.
- (void)placeCreditAnimated:(BOOL)animated {
    if (!_tops.count || !_credit.text.length) return;
    CGFloat anchor = _browsing ? _browseAnchor : self.bounds.size.height * kAnchor;
    NSInteger openBreak = _browsing ? _browseBreak : _openBreak;
    CGFloat width = MAX(self.bounds.size.width - 2 * _margin, 0);
    CGSize size = [_credit sizeThatFits:CGSizeMake(width, CGFLOAT_MAX)];
    CGFloat top = anchor + _stackEnd - _focusTop + (openBreak >= 0 ? [self breakRoom] : 0) + kCreditGap;
    CGRect frame = CGRectMake(_margin, top, MIN(ceil(size.width), width), ceil(size.height));
    if (CGRectEqualToRect(_credit.frame, frame)) return;
    if (!animated || _credit.hidden) {
        _credit.frame = frame;
        return;
    }
    [UIView animateWithDuration:0.7 delay:0.3 usingSpringWithDamping:0.86 initialSpringVelocity:0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{ self->_credit.frame = frame; } completion:nil];
}

// The dots, at the anchor for as long as a break is open, against the edge the line after it is on.
// They are only ever where they belong: they come and go by their own timeline, not by moving.
- (void)placeBreak {
    if (_openBreak < 0) {
        [_dots removeFromSuperview];
        return;
    }
    if (!_dots) {
        _dots = [[SGRKaraokeBreakView alloc] initWithFont:_font];
        _dotsLine = -1;
    }
    if (_dotsLine != _openBreak) {
        _dots.rightToLeft = readsRightToLeft(SGKaraokeLineText(_lines[(NSUInteger)_openBreak]));
        for (NSUInteger i = 0; i < _breakCount; i++) {
            if (_breaks[i].line == _openBreak) [_dots playFrom:_breaks[i].start to:_breaks[i].end];
        }
        _dotsLine = _openBreak;
    }
    if (_dots.superview != _scroll) [_scroll addSubview:_dots];
    _dots.right = alignsRight(_lines[(NSUInteger)_openBreak]);
    CGFloat top = [self topOfLine:_openBreak] - [self breakRoom];
    _dots.frame = CGRectMake(_margin, top, _builtWidth - 2 * _margin, _dots.bounds.size.height);
}

// A credit the source's terms require shows whatever Show source says (Shared/LyricsSources/SpicyLyrics.m).
- (void)creditTo:(NSString *)source {
    _creditSource = source;
    BOOL shown = source.length && (_crediting || SGLyricsCreditRequired(source));
    NSString *text = shown ? [NSString stringWithFormat:@"Lyrics from %@", source] : nil;
    _creditLinks = shown ? SGLyricsCreditLinks(source) : nil;
    _credit.accessibilityTraits = _creditLinks.count ? UIAccessibilityTraitLink : UIAccessibilityTraitStaticText;
    if (text == _credit.text || [text isEqualToString:_credit.text]) return;
    _credit.text = text;
    _credit.hidden = !_showing || !text.length;
    [self placeCreditAnimated:NO];
}

- (NSArray *)accessibilityElements {
    NSMutableArray *elements = [NSMutableArray array];
    for (NSNumber *key in [[_shown allKeys] sortedArrayUsingSelector:@selector(compare:)]) [elements addObject:_shown[key]];
    if (_extrasBox && !_extrasBox.hidden) [elements addObject:_extrasBox];
    if (!_credit.hidden) [elements addObject:_credit];
    if (_sing && !_sing.hidden) [elements addObject:_sing];
    return elements;
}

- (void)syncSiblings {
    for (UIView *sibling in self.superview.subviews) {
        if (sibling != self && _showing) sibling.alpha = 0;
    }
}

- (void)setShowing:(BOOL)showing {
    if (showing == _showing) return;
    _showing = showing;
    self.hidden = !showing;
    if (showing && !_browsing) _scroll.contentOffset = CGPointZero;
    _credit.hidden = !showing || !_credit.text.length;
    for (UIView *sibling in self.superview.subviews) {
        if (sibling != self) sibling.alpha = showing ? 0 : 1;
    }
}

// The player's position run on by the frame times the display will show and eased toward each new
// reading, so the sweep follows neither the callback's jitter nor the small jumps of the core's
// corrections. A seek or a new track is too far off to ease and is taken at once.
- (double)clockMs {
    NSInteger raw = [self positionMs];
    CFTimeInterval shown = [self frameTime];
    if (_seekAt) {
        // A paused player never moves, so the hold ends by the position or the time, not by motion.
        BOOL reported = raw >= 0 && labs(raw - _seekTo) <= kSeekNearMs;
        if (!reported && CACurrentMediaTime() - _seekAt < kSeekWait) {
            _clock = _seekTo;
            _reported = raw;
            _clockTime = shown;
            return _clock;
        }
        _seekAt = 0;
    }
    BOOL running = raw != _reported;   // a paused player reports the same position every frame
    if (running) {
        _stillSince = 0;
        [self stir];
    }
    else if (!_stillSince) _stillSince = shown;
    double reported = raw + (running ? (shown - CACurrentMediaTime()) * 1000 : 0);
    double predicted = _clock + (running ? (shown - _clockTime) * 1000 : 0);
    double error = reported - predicted;
    _clock = raw < 0 || fabs(error) > kClockSnapMs ? reported : predicted + error * kClockPull;
    _reported = raw;
    _clockTime = shown;
    return _clock;
}

- (void)tick {
    // A paused clock and a page at rest draw nothing new: once what was last set moving has finished, a few
    // frames a second still watch the track, its lines and the clock, and whatever moves stirs it back.
    if (_seekAt || _scroll.isTracking || _scroll.isDecelerating) [self stir];
    else if (_link && !_link.paused && [self frameTime] - _stirredAt > kCalmAfter) [self calmDown];
    NSString *track = _sample ? @"sample" : SGKaraokePlayingTrack();
    if (!(track == _track || [track isEqualToString:_track])) {
        SGLog(@"karaoke: page shows track %@, lyrics %@", track, [self linesFor:track] ? @"captured" : @"not captured yet");
        _track = track;
        [self dropLines];
    }
    NSArray<SGKaraokeLine *> *kept = _lines && track ? [self linesFor:track] : nil;
    if (kept && kept != _lines && kept != _passedOver) {
        if (!_hasTranslation && kept.count == _lines.count && SGKaraokeLinesTiming(kept) == SGKaraokeLinesTiming(_lines)
            && hasTranslations(kept)) {
            // Musixmatch's translations come in a moment after the lines, as copies of them: the song is
            // restyled with them where it stands.
            SGLog(@"karaoke: translations of %@ came in", track);
            if (_tops) {
                _lines = kept;
                [self timeLines];
                [self restyle];
            } else {
                // Nothing placed yet, and a measure may be in flight in the old style: it is dropped, and
                // the translated lines are built below as new ones.
                _lines = nil;
                _builtWidth = 0;
                [self dropLineViews];
            }
        } else if (_plain) {
            // Plain text is shown while Spotify is asked whether it has the song timed; its answer replaces it.
            SGLog(@"karaoke: timed lines of %@ came in over the plain text", track);
            _lines = nil;
            _builtWidth = 0;
            [self creditTo:nil];
            [self dropLineViews];
        } else {
            _passedOver = kept;
        }
    }
    if (!_lines && track && (_lines = [self linesFor:track])) {
        SGLog(@"karaoke: showing %lu lines of %@", (unsigned long)_lines.count, track);
        [self timeLines];
        [self setNeedsLayout];
    }
    [self setShowing:_tops != nil];
    // The source is settled a moment after the lines are, so it is asked for until it answers.
    if (!_sample && _lines && !_creditSource) [self creditTo:SGLyricsCreditFor(track)];
    if (!_tops) return;
    [self alignFade];
    if (_plain) {
        [self showLinesInSight];   // it moves only when scrolled by hand
        return;
    }

    double now = [self clockMs];
    [self arrangeAt:now glide:_sample != nil];   // the preview coming round glides back to its first line
    for (NSUInteger i = 0; i < _sungCount; i++) [_shown[@(_sung[i])] showTime:now];
    CFTimeInterval frame = [self frameTime];
    if (_dots.superview) [_dots showTime:now running:!_stillSince || frame - _stillSince < kStillFor at:frame];
}

// What is sung at `now` lit and the stack arranged around it; a jump of more than a couple of lines is
// placed at once, unless it is a tapped line gliding over.
- (void)arrangeAt:(double)now glide:(BOOL)glide {
    NSInteger sung[kMostSung], focus, openBreak;
    NSUInteger count = [self sungAt:now into:sung focus:&focus openBreak:&openBreak];
    if (focus != _focus || openBreak != _openBreak || count != _sungCount || memcmp(sung, _sung, count * sizeof(NSInteger))) {
        // Lines sung out go back to dim, lines coming in light up, the ones sung throughout carry on.
        for (NSUInteger i = 0; i < _sungCount; i++) {
            BOOL still = NO;
            for (NSUInteger j = 0; j < count; j++) still = still || sung[j] == _sung[i];
            if (!still) _shown[@(_sung[i])].active = NO;
        }
        for (NSUInteger j = 0; j < count; j++) {
            if (![self isSung:sung[j]]) [self viewForLine:sung[j]].active = YES;
        }
        BOOL jump = labs(focus - _focus) > 2;   // a seek, not the song moving on
        memcpy(_sung, sung, count * sizeof(NSInteger));
        _sungCount = count;
        _focus = focus;
        _openBreak = openBreak;
        _arrangement++;
        if (openBreak < 0) [_dots removeFromSuperview];
        [self placeLinesAnimated:glide || !jump];
    } else {
        [self showLinesInSight];   // the page may be scrolling by hand, or springing back
    }
}

// What is sung at `now`: each line from its start until it is sung out, so two voices over each
// other are both lit, and the last line begun on through the pause after it, as Apple Music keeps a
// line lit until the next one comes. A pause that is a break is the dots' instead, until the moment
// before its end when the line after it moves up to the anchor, sharp but not yet lit.
- (NSUInteger)sungAt:(double)now into:(NSInteger *)sung focus:(NSInteger *)focus openBreak:(NSInteger *)openBreak {
    NSInteger count = (NSInteger)_lines.count, last = -1;
    while (last + 1 < count && _spans[last + 1].start <= now) last++;
    *openBreak = -1;
    NSInteger breakLine = -1;
    for (NSUInteger i = 0; i < _breakCount; i++) {
        SGRKaraokeBreak pause = _breaks[i];
        if (now < pause.start || now >= pause.end) continue;
        breakLine = pause.line;
        if (now < pause.end - kBreakCollapse * 1000) *openBreak = pause.line;
    }
    NSUInteger found = 0;
    for (NSInteger i = 0; i <= last && found < kMostSung; i++) {
        if (_spans[i].end > now || (i == last && breakLine < 0)) sung[found++] = i;
    }
    *focus = breakLine >= 0 ? breakLine : found ? sung[0] : last;
    return found;
}

@end
