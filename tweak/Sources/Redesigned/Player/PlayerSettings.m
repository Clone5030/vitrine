// The redesign's Player page in Mod Settings (App/Pages.m opens it in place of the native look's).
//
// It leads with a card of the player as the now playing track shows on it: the background chosen on the
// page edge to edge, and over its foot the cover, the title and the artist (gliding when too long) and how
// far the track has played. The progress is where the track was when the page appeared. With no track, the
// card shows the last one played (Shared/Player/SGLastTrack.h), its cover fetched and its Canvas looked up
// as the playing one's would be, and with none ever played, Not Playing over a gradient of the accent.
//
// The background is the player's own: a field of the same kind (Still, Colors, Fluid), for Animated
// the clip the player is playing (SGRPlayerMotionPreview) in place of the field, or, while the player has
// none, the playing track's clip looked up for the card while it is on screen, Fluid until it comes in and
// for a track with none, as in the player; the clip crosses over the field as it arrives, its poster first
// while its video decodes. And for Visualizer the hills over Fluid held still (SGRPlayerVisualiserPreview),
// moving with the song. It moves under the field's own conditions (in a window, Spotify in front, Reduce
// Motion and Low Power Mode off). Under the card a segmented control picks the background, all five of
// them: the names are one word each, each segment as wide as its name, so they fit side by side at an iPhone's
// width, and every choice stays one tap away with the card showing it at once. A note under the control says what the
// choice does; it is given the room of the longest note, so the rows under it hold still as it changes.
//
// Under the header: the rows that follow the choice (Animated's sources and its Low Data Mode switch; Fluid's
// five sliders and their Reset, which the card and the player follow as they move, SGRFluid.h), the Mini
// player section (Redesigned/NowPlayingBar/NowPlayingBarSettings.m), then the sections either look shares.
//
// Threading: main thread only.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Redesigned/Kit/SGRFluid.h"
#import "Redesigned/NowPlayingBar/NowPlayingBar.h"
#import "Shared/AnimatedArtwork/AnimatedArtwork.h"
#import "Shared/Player/SGLastTrack.h"
#import "Player.h"

// The card's height as a share of its width, kept between the two bounds.
static const CGFloat kCardAspect = 0.5, kCardMinHeight = 168, kCardMaxHeight = 220;
static const CGFloat kCardRadius = 26;   // continuous, the radius of the page's own cards and then some
static const CGFloat kCardPadding = 16, kCoverSide = 64;

// What each background does, in SGRPlayerBackgroundKind's order.
static NSArray<NSString *> *backgroundNotes(void) {
    return @[
        @"The cover, blurred and held still.",
        @"The cover's colors, drifting slowly.",
        @"The cover itself, blurred and slowly turning. It rests while a song is paused.",
        @"The song's Canvas or the album's moving cover, else Fluid. The player's ⋯ menu switches between this, Fluid and Visualizer.",
        @"The song's sound as gentle hills in the cover's colors, over Fluid held still. They settle while a song is paused.",
    ];
}

@interface SGRPlayerShowcase : UIView <SGPlayerStateObserver>
- (void)reloadTrack;
- (void)reloadBackgroundAnimated:(BOOL)animated;
@end

@implementation SGRPlayerShowcase {
    SGRArtworkField *_field;
    UIView *_motion, *_visualiser;
    UIImageView *_cover;
    SGMarqueeLabel *_title, *_artist;
    UIView *_progress, *_progressFill;
    CGFloat _position;
    NSString *_artworkOf;   // the last track whose cover the card asked for
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.clipsToBounds = YES;
    self.layer.cornerRadius = kCardRadius;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.backgroundColor = SGRNeutralField();
    self.userInteractionEnabled = NO;
    self.isAccessibilityElement = YES;
    self.accessibilityTraits = UIAccessibilityTraitImage;
    self.accessibilityLabel = @"Player preview";

    _field = [[SGRArtworkField alloc] initWithFrame:frame];
    _field.showsBackdrop = YES;
    [self addSubview:_field];

    _cover = [UIImageView new];
    _cover.contentMode = UIViewContentModeScaleAspectFill;
    _cover.clipsToBounds = YES;
    _cover.layer.cornerRadius = 8;
    _cover.layer.cornerCurve = kCACornerCurveContinuous;
    _cover.tintColor = SGRTertiary();
    _cover.backgroundColor = SGRSolidGlassFill();
    _cover.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightRegular];
    [self addSubview:_cover];

    // The card reads as one image; the words glide as the player's own do.
    _title = [SGMarqueeLabel new];
    _title.textColor = SGRPrimary();
    _title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    _title.isAccessibilityElement = NO;
    [self addSubview:_title];
    _artist = [SGMarqueeLabel new];
    _artist.textColor = SGRSecondary();
    _artist.font = [UIFont systemFontOfSize:15];
    _artist.isAccessibilityElement = NO;
    [self addSubview:_artist];

    // The player's slider as it is drawn at rest: a track, and in it a fill up to where the song is.
    _progress = [UIView new];
    _progress.backgroundColor = [UIColor colorWithWhite:1 alpha:0.2];
    _progress.clipsToBounds = YES;
    _progressFill = [UIView new];
    _progressFill.backgroundColor = SGRPrimary();
    [_progress addSubview:_progressFill];
    [self addSubview:_progress];

    SGAddPlayerStateObserver(self);
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(artworkChanged) name:SGRNowPlayingArtworkDidChangeNotification object:nil];
    [self reloadTrack];
    [self reloadBackgroundAnimated:NO];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)playerStateDidChange:(SPTPlayerState *)state {
    [self reloadTrack];
}

- (void)artworkChanged {
    NSString *identity = nil;
    UIImage *image = SGRNowPlayingArtwork(NULL, &identity);
    if (image) [self showArtwork:image identity:identity];
}

// The cover and the field from `image`, or from the placeholder for nil.
- (void)showArtwork:(UIImage *)image identity:(NSString *)identity {
    static UIImage *placeholder;
    static UIColor *tint;
    if (!image && (!placeholder || ![tint isEqual:SGGreen()])) {
        tint = SGGreen();
        placeholder = SGPlaceholderArtwork(tint);
    }
    _cover.image = image ?: placeholder;
    _cover.contentMode = UIViewContentModeScaleAspectFill;
    [_field setArtwork:_cover.image identity:image ? identity : @"placeholder" animated:self.window != nil];
}

// The track, where it is and whether it plays, read again.
- (void)reloadTrack {
    SPTPlayerState *state = SGPlayerState();
    SGShownTrack *shown = SGShownTrackNow();
    _title.text = shown.title ?: @"Not Playing";
    _artist.text = shown.artist ?: @"";
    _position = shown.current && state.duration > 0 ? MIN(1, MAX(0, state.position / state.duration)) : 0;
    // The clip covers the field, and the hills move over it, which then holds still, as in the player.
    _field.motionHeld = state.isPaused || _motion != nil || _visualiser != nil;
    if (shown.current && SGRNowPlayingArtwork(NULL, NULL)) {
        [self artworkChanged];
    } else if (!shown.current && shown.artworkURL) {
        // The last track's cover, the placeholder until it comes.
        NSString *uri = shown.uri;
        if (![_artworkOf isEqualToString:uri]) [self showArtwork:nil identity:nil];
        _artworkOf = uri;
        __weak SGRPlayerShowcase *weakSelf = self;
        SGShownTrackArtwork(shown, ^(UIImage *image) {
            SGRPlayerShowcase *showcase = weakSelf;
            SGShownTrack *now = SGShownTrackNow();
            if (image && !now.current && [now.uri isEqualToString:uri]) [showcase showArtwork:image identity:[@"last:" stringByAppendingString:uri]];
        });
    } else {
        // Nothing ever played, or the playing track's cover still coming.
        _artworkOf = nil;
        [self showArtwork:nil identity:nil];
    }
    [self setNeedsLayout];
}

// The card on screen with Animated and no clip in it: one is looked up, and shown once it is in.
- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window && !_motion && SGRPlayerBackground() == SGRPlayerBackgroundAnimated) [self reloadBackgroundAnimated:NO];
}

// The background chosen, read again; a new one crosses over when animated. The clip is the one playing, or
// looked up, when this is called: a track changed while the page shows keeps the last one until the page
// appears again. A clip is looked up only while the card is in a window.
- (void)reloadBackgroundAnimated:(BOOL)animated {
    SGRPlayerBackgroundKind kind = SGRPlayerBackground();
    __weak SGRPlayerShowcase *weakSelf = self;
    void (^arrived)(void) = !self.window ? nil : ^{
        SGRPlayerShowcase *showcase = weakSelf;
        if (showcase.window && !showcase->_motion && SGRPlayerBackground() == SGRPlayerBackgroundAnimated) [showcase reloadBackgroundAnimated:YES];
    };
    void (^apply)(void) = ^{
        self->_field.flows = kind == SGRPlayerBackgroundColours;
        self->_field.fluid = kind >= SGRPlayerBackgroundFluid;
        [self->_motion removeFromSuperview];
        self->_motion = kind == SGRPlayerBackgroundAnimated ? SGRPlayerMotionPreview(arrived) : nil;
        if (self->_motion) [self insertSubview:self->_motion aboveSubview:self->_field];
        [self->_visualiser removeFromSuperview];
        self->_visualiser = kind == SGRPlayerBackgroundVisualiser ? SGRPlayerVisualiserPreview() : nil;
        if (self->_visualiser) [self insertSubview:self->_visualiser aboveSubview:self->_field];
        self->_field.motionHeld = SGPlayerState().isPaused || self->_motion != nil || self->_visualiser != nil;
    };
    self.accessibilityValue = [SGRPlayerBackgroundNames()[(NSUInteger)kind] stringByAppendingString:@" background"];
    if (animated && self.window) {
        // A crossfade, which Reduce Motion keeps: nothing moves.
        [UIView transitionWithView:self duration:SGRCrossfade options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowAnimatedContent
                        animations:apply completion:nil];
    } else {
        apply();
    }
    [self setNeedsLayout];
}

// The clip runs from the card's top at its width, as in the player, and its blur comes in from the
// seam under the controls, which on a card this short is over its foot, under the words.
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    CGFloat w = bounds.size.width, h = bounds.size.height;
    _field.frame = bounds;
    _field.backdropHeight = h;
    _motion.frame = bounds;
    _visualiser.frame = bounds;

    _cover.frame = CGRectMake(kCardPadding, h - kCardPadding - kCoverSide, kCoverSide, kCoverSide);
    CGFloat x = CGRectGetMaxX(_cover.frame) + 12, width = w - kCardPadding - x;
    CGFloat line = 4, titleHeight = ceil(_title.font.lineHeight), artistHeight = ceil(_artist.font.lineHeight);
    CGFloat bottom = CGRectGetMaxY(_cover.frame);
    _progress.frame = CGRectMake(x, bottom - line - 2, width, line);
    _progress.layer.cornerRadius = line / 2;
    _progressFill.frame = CGRectMake(0, 0, round(width * _position), line);
    CGFloat textBottom = CGRectGetMinY(_progress.frame) - 10;
    _artist.frame = CGRectMake(x, textBottom - artistHeight, width, artistHeight);
    _title.frame = CGRectMake(x, CGRectGetMinY(_artist.frame) - titleHeight, width, titleHeight);
}

@end

#pragma mark - the page

@interface SGRPlayerPage : SGModPage
@property (nonatomic, strong) SGRPlayerShowcase *showcase;
@property (nonatomic, strong) UISegmentedControl *backgrounds;
@end

@implementation SGRPlayerPage {
    UIView *_header;
    UILabel *_note;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _header = [UIView new];
    [_header addSubview:self.showcase];
    [_header addSubview:self.backgrounds];
    _note = [UILabel new];
    _note.font = SGSubtitleFont();
    _note.textColor = SGGrey();
    _note.numberOfLines = 0;
    [_header addSubview:_note];
    [self showNote];
    self.tableView.tableHeaderView = _header;
}

- (void)showNote {
    _note.text = backgroundNotes()[(NSUInteger)SGRPlayerBackground()];
    [self.view setNeedsLayout];
}

// The header keeps the height it is given, so it is sized here and given back to the table only when that
// changes (a table header set on every pass lays the table out again forever). The note's room is that of
// the longest note at this width, so picking a background never moves the rows.
- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    UITableView *table = self.tableView;
    _note.font = SGSubtitleFont();
    CGFloat width = table.bounds.size.width, inset = table.layoutMargins.left;
    CGFloat cardWidth = width - 2 * inset;
    CGFloat cardHeight = round(MIN(kCardMaxHeight, MAX(kCardMinHeight, cardWidth * kCardAspect)));
    self.showcase.frame = CGRectMake(inset, 16, cardWidth, cardHeight);
    CGFloat controlHeight = MAX(32, ceil([self.backgrounds sizeThatFits:CGSizeMake(cardWidth, CGFLOAT_MAX)].height));
    self.backgrounds.frame = CGRectMake(inset, CGRectGetMaxY(self.showcase.frame) + 12, cardWidth, controlHeight);

    CGFloat noteWidth = cardWidth - 2 * 4, room = 0;
    UILabel *measure = [UILabel new];
    measure.font = _note.font;
    measure.numberOfLines = 0;
    for (NSString *text in backgroundNotes()) {
        measure.text = text;
        room = MAX(room, ceil([measure sizeThatFits:CGSizeMake(noteWidth, CGFLOAT_MAX)].height));
    }
    CGFloat noteHeight = ceil([_note sizeThatFits:CGSizeMake(noteWidth, CGFLOAT_MAX)].height);
    CGFloat noteTop = CGRectGetMaxY(self.backgrounds.frame) + 8;
    _note.frame = CGRectMake(inset + 4, noteTop, noteWidth, noteHeight);
    CGSize size = CGSizeMake(width, noteTop + room);
    if (CGSizeEqualToSize(_header.bounds.size, size)) return;
    _header.frame = (CGRect){CGPointZero, size};
    table.tableHeaderView = _header;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // The player's ⋯ menu can switch Animated and Fluid while the page is away.
    self.backgrounds.selectedSegmentIndex = SGRPlayerBackground();
    [self showNote];
    [self.showcase reloadTrack];
    [self.showcase reloadBackgroundAnimated:NO];
}

- (void)backgroundPicked {
    SGSetInt(SGRKeyPlayerBackground, self.backgrounds.selectedSegmentIndex);
    [self.showcase reloadBackgroundAnimated:YES];
    [self showNote];
    [self refreshVisibility];
}

@end

// One of Fluid's settings on a slider, written out with `unit` after the number.
static SGModRow *fluidSlider(NSString *title, SGRFluidSetting setting, NSString *unit) {
    SGRFluidLimits l = SGRFluidLimitsOf(setting);
    return SGSliderRow(title, nil, l.least, l.most, l.step, ^double { return SGRFluidValue(setting); },
                       ^(double value) { SGRSetFluidValue(setting, lround(value)); },
                       ^NSString *(double value) { return [NSString stringWithFormat:@"%.0f%@", value, unit]; });
}

UIViewController *SGRPlayerSettingsPage(NSArray *more) {
    SGRPlayerShowcase *showcase = [[SGRPlayerShowcase alloc] initWithFrame:CGRectMake(0, 0, 320, kCardMinHeight)];
    UISegmentedControl *backgrounds = [[UISegmentedControl alloc] initWithItems:SGRPlayerBackgroundNames()];
    backgrounds.selectedSegmentIndex = SGRPlayerBackground();
    backgrounds.accessibilityLabel = @"Background";
    backgrounds.apportionsSegmentWidthsByContent = YES;

    SGModRow *lowData = SGOptionRow(@"Download in Low Data Mode", @"Up to about 7 MB a song", SGKeyMotionLowData);
    lowData.visible = ^BOOL { return SGRPlayerBackground() == SGRPlayerBackgroundAnimated; };
    SGModRow *sources = SGMotionSourcesRow();
    sources.visible = lowData.visible;

    __block __weak UITableViewController *weakPage;
    SGModRow *reset = SGActionRow(@"Reset", nil, ^{
        SGRResetFluidSettings();
        [weakPage.tableView reloadData];   // the sliders at once, rather than at the page's next tick
    });
    reset.color = SGRed();
    NSArray<SGModRow *> *fluid = @[
        fluidSlider(@"Speed", SGRFluidSpeed, @"%"), fluidSlider(@"Warp", SGRFluidWarp, @"%"), fluidSlider(@"Blur", SGRFluidBlur, @""),
        fluidSlider(@"Saturation", SGRFluidSaturation, @"%"), fluidSlider(@"Brightness", SGRFluidBrightness, @"%"), reset,
    ];
    for (SGModRow *row in fluid) row.visible = ^BOOL { return SGRPlayerBackground() == SGRPlayerBackgroundFluid; };

    NSMutableArray<SGModSection *> *sections = [NSMutableArray arrayWithObjects:
        SGNotedSection(nil, @[SGOptionRow(@"Full-screen cover", nil, SGKeyMotionFullCover),
                              SGOptionRow(@"Full-brightness covers", nil, SGRKeyPlayerFullBrightness)],
                       @"A song with no animated cover shows its cover over the whole player with Animated, and over the whole lock "
                       @"screen's artwork where that shows artwork (not with lyrics). Full-brightness covers take the dark layer off animated "
                       @"artwork and the full-screen cover, so they show as they are; the lyrics keep theirs. Restart Spotify after switching them."),
        SGSection(nil, @[sources, lowData]),
        SGNotedSection(nil, fluid, @"Brightness above 100% can make white text harder to read. A paused song holds the "
                                   @"background still. Animated and Visualizer use these where they show Fluid."),
        SGNotedSection(@"Controls", @[SGSwitchRow(@"Volume", nil, SGRKeyPlayerVolume),
                                      SGOptionRow(@"Follow the cover", nil, SGRKeyPlayerFollowsCover)],
                       @"Volume puts a slider under the controls for this iPhone, or the speaker's while Spotify plays on another device. "
                       @"Follow the cover paints the like, shuffle and repeat in the color of the song playing."),
        SGNotedSection(@"Mini player", SGRNowPlayingBarRows(),
                       @"Apple Music style moves the now playing bar in between two tabs as you scroll down."), nil];
    [sections addObjectsFromArray:more];
    // Fluid, Animated and Visualizer share the field (PlayerMotion.x reads the choice on every track, PlayerVisualiser.m
    // on the field's layout); Still and Colors are a field of another kind, made once a launch (PlayerField.x).
    NSString *footer = @"Fluid, Animated and Visualizer change with the next song. Still, Colors and Hide on the player apply after you restart Spotify.";
    SGRPlayerPage *page = [[SGRPlayerPage alloc] initWithTitle:@"Player" intro:nil sections:sections footer:footer];
    weakPage = page;
    page.showcase = showcase;
    page.backgrounds = backgrounds;
    [backgrounds addTarget:page action:@selector(backgroundPicked) forControlEvents:UIControlEventValueChanged];
    return page;
}
