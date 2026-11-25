// Player redesign: the ⋯ opens the system menu (Redesigned/ContextMenu): Share, Add to playlist and Add to
// queue in a row at its top, then the player's own items here, then More with the rest of Spotify's rows. The
// player's items take over what Speed and pitch's block is on Spotify's sheet:
//
//     Speed, Pitch & Reverb   opens the sliders in a popover from the ⋯ (SGPlayerShowSpeedPitchPanel): speed,
//                             pitch, reverb and Pitch follows speed, as on Spotify's sheet (issue #14)
//     Show Fluid Artwork, Show Animated Artwork, Show Visualizer
//                             a button for each of the two the background is not, while it is one of the
//                             three, named for what it switches to
//     Lyrics Source           a song's lyrics from another source than the one the order chose (issue #67), in a
//                             popover from the ⋯ that asks every source and lists each as it answers
//
// The item says under its name what is not as Spotify plays it, so the menu reads as a settings summary.
#import "Core/SGCore.h"
#import "Redesigned/ContextMenu/ContextMenu.h"
#import "Shared/Player/PlayerState.h"
#import "Shared/Player/SpeedPitch.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/LyricsSources/LyricsSources.h"
#import "Settings/SGPageStyle.h"
#import "Shared/AnimatedArtwork/SGCustomArtwork.h"
#import "Player.h"

static __weak UIView *sg_moreButton;   // the ⋯ the panels come from

static UIImage *symbol(NSString *name) {
    return [UIImage systemImageNamed:name];
}

static NSString *speedText(double speed) {
    NSString *text = [NSString stringWithFormat:@"%.2f", speed];
    while ([text hasSuffix:@"0"]) text = [text substringToIndex:text.length - 1];
    if ([text hasSuffix:@"."]) text = [text substringToIndex:text.length - 1];
    return [text stringByAppendingString:@"×"];
}

static NSString *semitonesText(float semitones) {
    if (semitones == 0) return @"Original";
    return [NSString stringWithFormat:@"%@%.0f %@", semitones > 0 ? @"+" : @"−", fabsf(semitones), fabsf(semitones) == 1 ? @"Semitone" : @"Semitones"];
}

// While pitch follows a speed that is not normal, the speed sets the pitch and the semitones are not played
// (SGTimePitch.h), so they stand aside, as on the sheet.
static BOOL pitchFollowing(void) {
    return SGPlayerSpeedAllowed() && SGPlayerPitchFollowsSpeed() && SGPlayerSpeed() != 1;
}

// One item for the three, which says what is not as Spotify plays it, or Normal.
static UIAction *soundMenu(void) {
    NSMutableArray<NSString *> *changed = [NSMutableArray array];
    if (SGPlayerSpeedAllowed() && fabs(SGPlayerSpeed() - 1) >= 0.01) [changed addObject:speedText(SGPlayerSpeed())];
    if (SGPlayerPitchAvailable() && !pitchFollowing() && SGPlayerPitch() != 0) [changed addObject:semitonesText(SGPlayerPitch())];
    if (SGPlayerReverb() > 0) [changed addObject:[NSString stringWithFormat:@"Reverb %.0f%%", SGPlayerReverb()]];
    UIAction *open = [UIAction actionWithTitle:@"Speed, Pitch & Reverb" image:symbol(@"slider.horizontal.3") identifier:nil
                                       handler:^(UIAction *action) { SGPlayerShowSpeedPitchPanel(sg_moreButton); }];
    open.subtitle = changed.count ? [changed componentsJoinedByString:@", "] : @"Normal";
    return open;
}

static NSString *sheetKind(void);

static NSString *timingText(NSArray<SGKaraokeLine *> *lines) {
    switch (SGKaraokeLinesTiming(lines)) {
        case SGKaraokeTimingWords: return @"Word by word";
        case SGKaraokeTimingLine: return @"Line by line";
        default: return @"Not synced";
    }
}

// A row of the panel: a source to pick (nil key: Automatic), or one still asked, or the note that none has lines.
@interface SGRSourceRow : NSObject
@property (nonatomic, copy) NSString *key, *title, *subtitle;
@property (nonatomic) BOOL picked, asking, note;
@end

@implementation SGRSourceRow
@end

// The Lyrics Source panel, a popover from the ⋯ like Speed, Pitch & Reverb's: a menu's submenu ran its rows
// under its own title when scrolled, and could not take a source that answered after it opened. Here the title
// scrolls with the rows, and each answer fills its row in while the panel is open.
@interface SGRLyricsSourcePanel : UITableViewController
@property (nonatomic, copy) NSString *track;
@end

@implementation SGRLyricsSourcePanel {
    NSArray<SGRSourceRow *> *_rows;
}

static const CGFloat kSourcePanelWidth = 300, kSourcePanelMaxHeight = 440;

- (instancetype)init {
    return [super initWithStyle:UITableViewStylePlain];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.backgroundColor = UIColor.clearColor;
    UILabel *title = [UILabel new];
    title.text = @"Lyrics Source";
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    title.textColor = UIColor.labelColor;
    title.accessibilityTraits = UIAccessibilityTraitHeader;
    title.frame = CGRectMake(20, 16, kSourcePanelWidth - 40, ceil(title.font.lineHeight));
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kSourcePanelWidth, CGRectGetMaxY(title.frame) + 6)];
    [header addSubview:title];
    self.tableView.tableHeaderView = header;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(offersChanged:) name:SGLyricsOffersDidChangeNotification object:nil];
    SGLyricsAskOffers(_track);
    [self rebuild];
}

- (void)offersChanged:(NSNotification *)note {
    if ([note.object isEqual:_track]) [self rebuild];
}

// Automatic, checked while nothing is picked and naming what the order chose, then the sources in the order:
// those with lines for the track, the one picked checked, and those still asked with a spinner.
- (void)rebuild {
    NSArray<NSString *> *asking = nil;
    NSDictionary<NSString *, SGLyricsResult *> *offers = SGLyricsOffersSoFar(_track, &asking);
    NSString *current = SGLyricsChosenSource(_track);
    SGRSourceRow *automatic = [SGRSourceRow new];
    automatic.title = @"Automatic";
    automatic.subtitle = current ? @"As the order chooses" : SGLyricsCreditFor(_track);
    automatic.picked = !current;
    NSMutableArray<SGRSourceRow *> *rows = [NSMutableArray arrayWithObject:automatic];
    for (NSString *key in SGLyricsOrder()) {
        SGLyricsResult *offer = offers[key];
        BOOL out = [asking containsObject:key];
        if (!offer && !out) continue;
        SGRSourceRow *row = [SGRSourceRow new];
        row.key = key;
        row.title = SGLyricsProviderFor(key).name;
        row.subtitle = offer ? timingText(offer.karaokeLines) : @"Asking…";
        row.asking = !offer;
        row.picked = offer && [key isEqualToString:current];
        [rows addObject:row];
    }
    if (rows.count == 1) {
        SGRSourceRow *none = [SGRSourceRow new];
        none.title = @"No Source Has Lyrics";
        none.note = YES;
        [rows addObject:none];
    }
    _rows = rows;
    [self.tableView reloadData];
    [self.tableView layoutIfNeeded];
    self.preferredContentSize = CGSizeMake(kSourcePanelWidth, MIN(self.tableView.contentSize.height, kSourcePanelMaxHeight));
}

- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    return _rows.count;
}

- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    SGRSourceRow *row = _rows[path.row];
    UITableViewCell *cell = [table dequeueReusableCellWithIdentifier:@"source"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"source"];
    UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
    content.text = row.title;
    content.secondaryText = row.subtitle;
    BOOL dim = row.asking || row.note;
    content.textProperties.color = dim ? UIColor.secondaryLabelColor : UIColor.labelColor;
    content.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    cell.contentConfiguration = content;
    cell.backgroundColor = UIColor.clearColor;
    cell.tintColor = UIColor.labelColor;
    cell.selectionStyle = dim ? UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleDefault;
    cell.accessoryType = row.picked ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    UIActivityIndicatorView *spinner = nil;
    if (row.asking) {
        spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        [spinner startAnimating];
    }
    cell.accessoryView = spinner;
    cell.accessibilityTraits = dim ? UIAccessibilityTraitNotEnabled : UIAccessibilityTraitButton | (row.picked ? UIAccessibilityTraitSelected : 0);
    return cell;
}

- (NSIndexPath *)tableView:(UITableView *)table willSelectRowAtIndexPath:(NSIndexPath *)path {
    SGRSourceRow *row = _rows[path.row];
    return row.asking || row.note ? nil : path;
}

- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    SGRSourceRow *row = _rows[path.row];
    if (row.key) SGLyricsChooseSource(_track, row.key);
    else SGLyricsChooseAutomatic(_track);
    [self dismissViewControllerAnimated:YES completion:nil];
}
@end

static UIAction *lyricsSourceItem(void) {
    NSString *track = SGKaraokePlayingTrack();
    if (!SGLyricsEnabled() || !track.length || [sheetKind() isEqualToString:@"episode"]) return nil;
    UIAction *open = [UIAction actionWithTitle:@"Lyrics Source" image:symbol(@"quote.bubble") identifier:nil handler:^(UIAction *action) {
        SGRLyricsSourcePanel *panel = [SGRLyricsSourcePanel new];
        panel.track = track;
        panel.preferredContentSize = CGSizeMake(kSourcePanelWidth, 200);
        SGPresentPopover(panel, sg_moreButton);
    }];
    open.subtitle = SGLyricsCreditFor(track);
    return open;
}

static NSArray<UIMenuElement *> *playerItems(void) {
    NSMutableArray<UIMenuElement *> *items = [NSMutableArray arrayWithObject:soundMenu()];
    if (SGPlayerMenuOffersAnimatedArtwork()) {
        // Buttons named for what they do, not checkmarks: the HIG's changeable label for a toggled item.
        NSArray<NSArray *> *backgrounds = @[
            @[@(SGRPlayerBackgroundFluid), @"Show Fluid Artwork", @"drop"],
            @[@(SGRPlayerBackgroundAnimated), @"Show Animated Artwork", @"play.rectangle.on.rectangle"],
            @[@(SGRPlayerBackgroundVisualiser), @"Show Visualizer", @"waveform"],
        ];
        SGRPlayerBackgroundKind current = SGRPlayerBackground();
        for (NSArray *background in backgrounds) {
            SGRPlayerBackgroundKind kind = [background[0] integerValue];
            if (kind == current) continue;
            [items addObject:[UIAction actionWithTitle:background[1] image:symbol(background[2]) identifier:nil
                                               handler:^(UIAction *action) { SGRPlayerMenuSetBackground(kind); }]];
        }
    }
    // The person's own video as this song's artwork, looped without a seam (Shared/AnimatedArtwork/SGCustomArtwork.h). It
    // shows under the Animated background, which choosing one switches to.
    NSString *uri = SGURIString(SGPlayerState().track.URI);
    if (SGPlayerMenuOffersAnimatedArtwork() && uri && [sheetKind() isEqualToString:@"track"]) {
        BOOL has = SGCustomArtworkFor(uri) != nil;
        UIAction *choose = [UIAction actionWithTitle:has ? @"Change Your Artwork" : @"Add Your Own Artwork" image:symbol(@"photo.badge.plus") identifier:nil
                                             handler:^(UIAction *action) {
            // After the menu has gone, or the picker has nothing to present over.
            dispatch_async(dispatch_get_main_queue(), ^{
                SGCustomArtworkChoose(uri, ^(BOOL working) {
                    if (!working && SGCustomArtworkFor(uri)) SGRPlayerMenuSetBackground(SGRPlayerBackgroundAnimated);
                });
            });
        }];
        choose.subtitle = @"A video that loops without a seam";
        [items addObject:choose];
        if (has) {
            UIAction *remove = [UIAction actionWithTitle:@"Remove Your Artwork" image:symbol(@"trash") identifier:nil
                                                 handler:^(UIAction *action) { SGCustomArtworkRemove(uri); }];
            remove.attributes = UIMenuElementAttributesDestructive;
            [items addObject:remove];
        }
    }
    UIAction *lyrics = lyricsSourceItem();
    if (lyrics) [items addObject:lyrics];
    return items;
}

// What the player is playing, from its URI (spotify:track:…, spotify:episode:…, spotify:local:…): a podcast's
// sheet has other rows than a song's.
static NSString *sheetKind(void) {
    NSArray<NSString *> *parts = [SGURIString(SGPlayerState().track.URI) componentsSeparatedByString:@":"];
    return parts.count > 2 ? parts[1] : @"";
}

void SGRPlayerMenuWatch(UIView *button) {
    sg_moreButton = button;
    SGRSystemMenuWatch(button, ^NSArray<UIMenuElement *> *{ return playerItems(); }, ^NSString *{ return sheetKind(); });
}
