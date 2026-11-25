#import <CoreText/SFNTLayoutTypes.h>
#import "SGModPage.h"
#import "SGPageStyle.h"
#import "SGGlowSwitch.h"
#import "Core/SGCore.h"

NSString *const SGRestartNote = @"Changes apply after you restart Spotify.";

@implementation SGModRow
@end

@implementation SGModSection
@end

SGModRow *SGSwitchRow(NSString *title, NSString *subtitle, NSString *key) {
    SGModRow *row = [SGModRow new];
    row.title = title;
    row.subtitle = subtitle;
    row.key = key;
    row.defaultOn = YES;
    return row;
}

SGModRow *SGHideRow(NSString *title, NSString *subtitle, NSString *key) {
    SGModRow *row = SGSwitchRow(title, subtitle, key);
    row.defaultOn = NO;
    return row;
}

SGModRow *SGShownRow(NSString *title, NSString *subtitle, NSString *hideKey) {
    SGModRow *row = SGHideRow(title, subtitle, hideKey);
    row.inverted = YES;
    return row;
}

// A switch for something the mod adds rather than takes away: off until it is asked for.
SGModRow *SGOptionRow(NSString *title, NSString *subtitle, NSString *key) {
    SGModRow *row = SGSwitchRow(title, subtitle, key);
    row.defaultOn = NO;
    return row;
}

// A switch whose work is not finished: turning it on says so first, and offers the repo to anyone
// who would rather fix it than live with it.
SGModRow *SGUnstableRow(NSString *title, NSString *subtitle, NSString *key, NSString *warning) {
    SGModRow *row = SGSwitchRow(title, subtitle, key);
    row.warning = warning;
    return row;
}

SGModRow *SGFlagRow(NSString *title, NSString *key) {
    SGModRow *row = SGHideRow(title, nil, key);
    row.flag = YES;
    return row;
}

// A flag Spotify ships on: the switch forces it off.
SGModRow *SGKillRow(NSString *title, NSString *key) {
    SGModRow *row = SGFlagRow(title, key);
    row.forceOff = YES;
    return row;
}

SGModRow *SGStatRow(NSString *title, NSString *(^value)(void)) {
    SGModRow *row = [SGModRow new];
    row.title = title;
    row.value = value;
    return row;
}

SGModRow *SGActionRow(NSString *title, NSString *subtitle, void (^action)(void)) {
    SGModRow *row = [SGModRow new];
    row.title = title;
    row.subtitle = subtitle;
    row.action = action;
    return row;
}

// Red, with a warning symbol. SGFillCell tints the title and the symbol; the cell below takes the
// color down to the subtitle too, so the whole row reads as the warning it is.
SGModRow *SGWarningRow(NSString *title, NSString *subtitle, void (^action)(void)) {
    SGModRow *row = SGActionRow(title, subtitle, action);
    row.color = SGRed();
    row.symbol = @"exclamationmark.triangle.fill";
    return row;
}

// No subtitle: a list of pages reads as a list, not as a wall of explanations.
SGModRow *SGPageRow(NSString *title, UIViewController *(^page)(void)) {
    SGModRow *row = [SGModRow new];
    row.title = title;
    row.page = page;
    return row;
}

// The list a choice row opens: the names it was given, each over its note where it has one, a green
// checkmark against the one set. Picking one writes the index, tells the row, and goes back, where the row
// it came from reads the new name out and the page it sits on rebuilds around it.
@interface SGChoicePage : SGPage
- (instancetype)initWithTitle:(NSString *)title key:(NSString *)key choices:(NSArray<NSString *> *)choices notes:(NSArray<NSString *> *)notes
                       footer:(NSString *)footer fallback:(NSInteger)fallback chosen:(void (^)(NSInteger index))chosen;
@end

@implementation SGChoicePage {
    NSString *_key;
    NSArray<NSString *> *_choices, *_notes;
    NSInteger _fallback;
    void (^_chosen)(NSInteger index);
    UIView *_footer;
}

- (instancetype)initWithTitle:(NSString *)title key:(NSString *)key choices:(NSArray<NSString *> *)choices notes:(NSArray<NSString *> *)notes
                       footer:(NSString *)footer fallback:(NSInteger)fallback chosen:(void (^)(NSInteger index))chosen {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    self.title = title;
    _key = key;
    _choices = choices;
    _notes = notes;
    _fallback = fallback;
    _chosen = chosen;
    _footer = footer ? SGNote(footer) : nil;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.tableFooterView = _footer;
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    if (_footer) SGFitNote(self.tableView, _footer, 16, 24);
}


- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    SGInsetForBars(self.tableView);
}

- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)_choices.count;
}

- (CGFloat)tableView:(UITableView *)table heightForHeaderInSection:(NSInteger)section {
    return CGFLOAT_MIN;
}

- (CGFloat)tableView:(UITableView *)table heightForFooterInSection:(NSInteger)section {
    return CGFLOAT_MIN;
}

- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = SGDequeueCell(table, @"choice");
    NSUInteger index = (NSUInteger)path.row;
    SGFillCell(cell, _choices[index], index < _notes.count ? _notes[index] : nil, nil, nil);
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    if (path.row == SGInt(_key, _fallback)) {
        UIImageView *tick = SGSymbolView(@"checkmark", 13, UIImageSymbolWeightSemibold, 16);
        tick.tintColor = SGGreen();
        cell.accessoryView = tick;
    }
    return cell;
}

- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:NO];
    SGSetInt(_key, path.row);
    if (_chosen) _chosen(path.row);
    [table reloadData];
    [self.navigationController popViewControllerAnimated:YES];
}

@end

// No key on the row: the key lives in the blocks, so the page draws the row as the link it is
// rather than as a switch. The notes and the callback are read off the row when its list opens, so they
// can be set after this returns.
SGModRow *SGChoiceRow(NSString *title, NSString *subtitle, NSString *key, NSArray<NSString *> *choices, NSInteger fallback) {
    SGModRow *row = [SGModRow new];
    row.title = title;
    row.subtitle = subtitle;
    row.value = ^NSString *{
        NSInteger index = SGInt(key, fallback);
        return index >= 0 && index < (NSInteger)choices.count ? choices[(NSUInteger)index] : choices.firstObject;
    };
    __weak SGModRow *weakRow = row;
    row.page = ^UIViewController *{
        return [[SGChoicePage alloc] initWithTitle:title key:key choices:choices notes:weakRow.choiceNotes footer:weakRow.choiceFooter fallback:fallback chosen:weakRow.chosen];
    };
    return row;
}

SGModRow *SGSliderRow(NSString *title, NSString *subtitle, double minimum, double maximum, double step,
                      double (^get)(void), void (^set)(double value), NSString *(^format)(double value)) {
    SGModRow *row = [SGModRow new];
    row.title = title;
    row.subtitle = subtitle;
    row.minimum = minimum;
    row.maximum = maximum;
    row.step = step;
    row.number = get;
    row.setNumber = set;
    row.format = format;
    return row;
}

// The page builds the button and its menu (-menuButtonFor:), since it is the page that reads the rows again.
SGModRow *SGMenuRow(NSString *title, NSArray<NSString *> *choices, NSString *(^value)(void), void (^chosen)(NSInteger index)) {
    SGModRow *row = SGStatRow(title, value);
    row.menu = choices;
    row.chosen = chosen;
    return row;
}

#pragma mark - the color sheet

// Holds the picker's callback for as long as the sheet is up: the checkmark is the one way a color is stored.
@interface SGColorSheet : NSObject
@property (nonatomic, weak) UIColorPickerViewController *picker;
@property (nonatomic, copy) void (^picked)(NSInteger rgb);
@end

@implementation SGColorSheet

- (void)confirm {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    [self.picker.selectedColor getRed:&r green:&g blue:&b alpha:&a];
    NSInteger rgb = (lround(MIN(1, MAX(0, r)) * 255) << 16) | (lround(MIN(1, MAX(0, g)) * 255) << 8) | lround(MIN(1, MAX(0, b)) * 255);
    void (^picked)(NSInteger rgb) = self.picked;
    [self.picker.navigationController dismissViewControllerAnimated:YES completion:nil];
    if (picked) picked(rgb);
}

- (void)cancel {
    [self.picker.navigationController dismissViewControllerAnimated:YES completion:nil];
}

@end

// Made from a CGColor: either look's accent hooks swap Spotify's green as UIColor makes it from components, and
// this color has to stay the one asked for, Spotify's green included, to show what a preset is.
UIColor *SGColorRGB(NSInteger rgb) {
    CGColorRef cg = CGColorCreateSRGB(((rgb >> 16) & 0xFF) / 255.0, ((rgb >> 8) & 0xFF) / 255.0, (rgb & 0xFF) / 255.0, 1);
    UIColor *color = [UIColor colorWithCGColor:cg];
    CGColorRelease(cg);
    return color;
}

void SGPickColor(NSString *title, NSInteger initial, void (^picked)(NSInteger rgb)) {
    UIColorPickerViewController *picker = [UIColorPickerViewController new];
    picker.navigationItem.title = title;
    picker.supportsAlpha = NO;
    picker.selectedColor = SGColorRGB(initial);
    SGColorSheet *sheet = [SGColorSheet new];
    sheet.picker = picker;
    sheet.picked = picked;
    UIBarButtonItem *done = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"checkmark"] style:UIBarButtonItemStyleDone target:sheet action:@selector(confirm)];
    done.accessibilityLabel = @"Done";
    picker.navigationItem.rightBarButtonItem = done;
    // Inside a navigation controller the picker drops its own close button, so the bar carries one.
    picker.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:sheet action:@selector(cancel)];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:picker];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    SGPresentDark(nav);
    objc_setAssociatedObject(nav, @selector(confirm), sheet, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [SGTopController() presentViewController:nav animated:YES completion:nil];
}

SGModRow *SGLinkRow(NSString *title, NSString *subtitle, NSString *url) {
    return SGActionRow(title, subtitle, ^{ SGOpenURL(url); });
}

// A value on the right and a tap: the Updates row reads its status out of About/Update.m every tick,
// and a tap asks the site again instead of waiting for the six hour cache to lapse.
SGModRow *SGStatActionRow(NSString *title, NSString *subtitle, NSString *(^value)(void), void (^action)(void)) {
    SGModRow *row = [SGModRow new];
    row.title = title;
    row.subtitle = subtitle;
    row.value = value;
    row.action = action;
    return row;
}

SGModSection *SGSection(NSString *title, NSArray<SGModRow *> *rows) {
    SGModSection *s = [SGModSection new];
    s.title = title;
    s.rows = rows;
    return s;
}

SGModSection *SGNotedSection(NSString *title, NSArray<SGModRow *> *rows, NSString *footer) {
    SGModSection *s = SGSection(title, rows);
    s.footer = footer;
    return s;
}

SGModRow *SGWithSymbol(SGModRow *row, NSString *symbol) {
    row.symbol = symbol;
    return row;
}

SGModRow *SGWithTile(SGModRow *row, NSString *symbol, UIColor *color) {
    row.tint = color;
    return SGWithSymbol(row, symbol);
}

// What a page row carrying a value shows on the right: the value, then the chevron, the same
// distance apart as Spotify's own rows keep them.
// A value never takes more than this much of the row, so a long one ends in "…" and leaves the title its room.
static const CGFloat kValueMaxWidth = 170;

// At the accessibility sizes a row's value goes under its title (stackedValue), and the accessories that
// would carry it beside the title show none.
static NSString *stackedValue(SGModRow *row) {
    NSString *value = row.value() ?: @"";
    return row.subtitle.length ? [NSString stringWithFormat:@"%@\n%@", row.subtitle, value] : value;
}

static UIView *valueAndChevron(NSString *text) {
    UILabel *label = [UILabel new];
    label.font = SGTitleFont();
    label.textColor = SGGrey();
    label.text = text;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    [label sizeToFit];
    if (label.bounds.size.width > kValueMaxWidth) label.bounds = CGRectMake(0, 0, kValueMaxWidth, label.bounds.size.height);
    UIImageView *chevron = SGChevronView();
    CGFloat height = MAX(label.bounds.size.height, chevron.bounds.size.height);
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, label.bounds.size.width + 6 + chevron.bounds.size.width, height)];
    label.center = CGPointMake(label.bounds.size.width / 2, height / 2);
    chevron.center = CGPointMake(box.bounds.size.width - chevron.bounds.size.width / 2, height / 2);
    [box addSubview:label];
    [box addSubview:chevron];
    return box;
}

// What a row with a value and no page shows on the right: the value, after a swatch of the row's color
// when it has one, rounded like the cards and edged with a hairline so a dark color still shows on them.
// The swatch is drawn into an image, past the accent hooks on layer backgrounds (see SGColorRGB).
static UIView *valueView(SGModRow *row) {
    UILabel *label = [UILabel new];
    label.font = SGTitleFont();
    label.textColor = SGGrey();
    label.text = row.value();
    [label sizeToFit];
    if (!row.swatch) return label;
    CGFloat side = 16, height = MAX(side, label.bounds.size.height);
    UIColor *fill = row.swatch();
    UIImage *image = [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side)] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [fill setFill];
        [context fillRect:CGRectMake(0, 0, side, side)];
    }];
    UIImageView *swatch = [[UIImageView alloc] initWithImage:image];
    swatch.frame = CGRectMake(0, (height - side) / 2, side, side);
    swatch.clipsToBounds = YES;
    swatch.layer.cornerRadius = 4;
    swatch.layer.cornerCurve = kCACornerCurveContinuous;
    swatch.layer.borderWidth = 1 / UIScreen.mainScreen.scale;
    swatch.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.3].CGColor;
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, side + 8 + label.bounds.size.width, height)];
    label.center = CGPointMake(side + 8 + label.bounds.size.width / 2, height / 2);
    [box addSubview:swatch];
    [box addSubview:label];
    return box;
}

// On means the row's own override is in place; anything else, including the opposite override
// somebody set from the All flags page, reads as off.
static BOOL flagRowOn(SGModRow *row) {
    id value = SGFlagOverride(row.key);
    return value && [value boolValue] != row.forceOff;
}

// A flag something of the mod's forces (Core/SGFlagForce.h: the redesign, the ad blocking): its row
// shows what is forced and takes no touch, so the flag has one place to change.
static BOOL flagRowLocked(SGModRow *row) {
    return row.flag && SGLockedFlagValue(row.key, NULL) != nil;
}

// What a locked row shows: the forced value, read the row's way, so a Disable Canvas row reads on
// while Canvas is forced off.
static BOOL lockedRowOn(SGModRow *row) {
    id value = SGLockedFlagValue(row.key, NULL);
    return value ? [value boolValue] != row.forceOff : YES;
}

#pragma mark - the slider row

// On the row's step, counted from its minimum, without the float noise of getting there.
static double snapped(SGModRow *row, double value) {
    if (row.step > 0) value = row.minimum + round(round((value - row.minimum) / row.step) * row.step * 1e6) / 1e6;
    return MAX(row.minimum, MIN(row.maximum, value));
}

// Figures that do not shift sideways as they change, in whatever face the titles are in.
static UIFont *tabular(UIFont *font) {
    UIFontDescriptor *descriptor = [font.fontDescriptor fontDescriptorByAddingAttributes:@{
        UIFontDescriptorFeatureSettingsAttribute: @[@{UIFontFeatureTypeIdentifierKey: @(kNumberSpacingType),
                                                     UIFontFeatureSelectorIdentifierKey: @(kMonospacedNumbersSelector)}],
    }];
    return [UIFont fontWithDescriptor:descriptor size:font.pointSize];
}

// A step at a time for VoiceOver, or a twentieth of the range where the steps are too fine to swipe through.
@interface SGModSlider : UISlider
@property (nonatomic) float spokenStep;
@end

@implementation SGModSlider

- (void)accessibilityIncrement {
    self.value += self.spokenStep;
    [self sendActionsForControlEvents:UIControlEventValueChanged];
}

- (void)accessibilityDecrement {
    self.value -= self.spokenStep;
    [self sendActionsForControlEvents:UIControlEventValueChanged];
}

@end

// The Audio effects page's slider row (Shared/AudioEffects/AudioEffectsPage.m), for any page: the title and the
// value over a slider in the accent color, a subtitle between them when there is one, each step stored
// as the thumb reaches it.
@interface SGModSliderCell : UITableViewCell
+ (CGFloat)heightFor:(SGModRow *)row width:(CGFloat)width;
- (void)showRow:(SGModRow *)row;
// The number again, after something else on the page changed it (a Reset row); never under a finger.
- (void)readNumber;
@end

@implementation SGModSliderCell {
    SGModRow *_row;
    UILabel *_title, *_subtitle, *_value;
    SGModSlider *_slider;
    double _shown;
    BOOL _detents;   // few enough steps that the thumb jumps between them as it is dragged
}

static const CGFloat kSliderTop = 12, kSliderGap = 6, kSliderHeight = 28, kSliderBottom = 10;

// The text is as tall as Dynamic Type makes it at the cell's width, less its 16pt sides.
+ (CGFloat)heightFor:(SGModRow *)row width:(CGFloat)width {
    return kSliderTop + SGSliderTextHeight(row.title, row.subtitle, width - 32) + kSliderGap + kSliderHeight + kSliderBottom;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier {
    if (!(self = [super initWithStyle:style reuseIdentifier:identifier])) return nil;
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    _title = [UILabel new];
    _title.textColor = UIColor.whiteColor;
    _title.isAccessibilityElement = NO;
    _subtitle = [UILabel new];
    _subtitle.textColor = SGGrey();
    _subtitle.isAccessibilityElement = NO;
    _value = [UILabel new];
    _value.textColor = SGGrey();
    _value.textAlignment = NSTextAlignmentRight;
    _value.isAccessibilityElement = NO;
    _slider = [SGModSlider new];
    _slider.maximumTrackTintColor = [UIColor colorWithWhite:1 alpha:0.16];
    [_slider addTarget:self action:@selector(moved) forControlEvents:UIControlEventValueChanged];
    [_slider addTarget:self action:@selector(released) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    for (UIView *view in @[_title, _subtitle, _value, _slider]) [self.contentView addSubview:view];
    return self;
}

- (void)showRow:(SGModRow *)row {
    _row = row;
    _slider.enabled = YES;   // a row waiting on a switch turns it off again (showWaiting)
    _slider.userInteractionEnabled = YES;
    NSInteger count = row.step > 0 ? (NSInteger)lround((row.maximum - row.minimum) / row.step) : 0;
    _detents = count > 0 && count <= 24;
    _title.font = SGTitleFont();
    _subtitle.font = SGSubtitleFont();
    _value.font = tabular(SGTitleFont());
    _title.text = row.title;
    _subtitle.text = row.subtitle;
    _subtitle.hidden = !row.subtitle;
    _slider.minimumTrackTintColor = SGGreen();
    _slider.minimumValue = (float)row.minimum;
    _slider.maximumValue = (float)row.maximum;
    _slider.spokenStep = (float)(count > 0 && count <= 40 ? row.step : snapped(row, row.minimum + (row.maximum - row.minimum) / 20) - row.minimum);
    _shown = snapped(row, row.number());
    _slider.value = (float)_shown;
    _slider.accessibilityLabel = row.title;
    _slider.accessibilityHint = row.subtitle;
    [self showValue];
}

- (void)showValue {
    _value.text = _row.format ? _row.format(_shown) : [NSString stringWithFormat:@"%g", _shown];
    _slider.accessibilityValue = _value.text;
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.contentView.bounds.size.width, side = 16;
    CGFloat y = SGLayOutSliderText(_title, _value, _subtitle, side, kSliderTop, width - 2 * side);
    _slider.frame = CGRectMake(side, y + kSliderGap, width - 2 * side, kSliderHeight);
}

- (void)moved {
    double value = snapped(_row, _slider.value);
    if (_detents) _slider.value = (float)value;
    if (value == _shown) return;
    _shown = value;
    if (_row.setNumber) _row.setNumber(value);
    [self showValue];
}

- (void)released {
    [_slider setValue:(float)_shown animated:YES];
}

- (void)readNumber {
    if (!_row.number || _slider.isTracking) return;
    double value = snapped(_row, _row.number());
    if (value == _shown) return;
    _shown = value;
    [_slider setValue:(float)value animated:YES];
    [self showValue];
}

@end

#pragma mark - rows waiting on a switch

// What a disabled control fades to, about the strength of the system's tertiary label.
static const CGFloat kWaitingAlpha = 0.4;

static NSArray<UIView *> *controlsIn(UITableViewCell *cell) {
    NSMutableArray<UIView *> *views = [NSMutableArray arrayWithArray:cell.contentView.subviews];
    if (cell.accessoryView) {
        [views addObject:cell.accessoryView];
        [views addObjectsFromArray:cell.accessoryView.subviews];
    }
    return [views filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(UIView *view, NSDictionary *bindings) {
        return [view isKindOfClass:UIControl.class];
    }]];
}

// A row waiting on a switch reads dimmed, the way a control that is off does, and its own switch, slider or
// button takes no touch, so a tap lands on the row and nudges the switch it waits on instead (-nudgeAt:).
static void showWaiting(UITableViewCell *cell, BOOL waiting, NSString *switchTitle) {
    cell.contentView.alpha = waiting ? kWaitingAlpha : 1;
    cell.accessoryView.alpha = waiting ? kWaitingAlpha : 1;
    cell.accessibilityHint = waiting ? [NSString stringWithFormat:@"Turn on %@ first.", switchTitle] : nil;
    if (!waiting) return;
    for (UIControl *control in controlsIn(cell)) {
        control.enabled = NO;
        control.userInteractionEnabled = NO;
    }
}

#pragma mark - the page

@implementation SGModPage {
    NSArray<SGModSection *> *_sections;
    NSArray<NSArray<SGModRow *> *> *_shown;   // each section's rows that show now (SGModRow.visible)
    UIView *_intro;
    UIView *_footer;
    NSTimer *_ticker;
    BOOL _live;
    NSIndexPath *_nudgeAfterScroll;   // the switch a waiting row's tap is scrolling to
}

- (instancetype)initWithTitle:(NSString *)title intro:(NSString *)intro sections:(NSArray<SGModSection *> *)sections footer:(NSString *)footer {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    self.title = title;
    _sections = sections;
    _shown = [self rowsToShow];
    _intro = intro ? SGNote(intro) : nil;
    _footer = footer ? SGNote(footer) : nil;
    // Any row with a value, a test of when it shows, a number or a menu keeps a ticker running: a page row's
    // value can move while the page shows (a download's percentage beside the chevron), a row can come or go
    // by itself (a download that finished brings its Remove row), and a Reset row can move a slider.
    for (SGModSection *s in sections) for (SGModRow *row in s.rows) _live |= row.value || row.visible || row.number;
    return self;
}

- (NSArray<NSArray<SGModRow *> *> *)rowsToShow {
    NSMutableArray<NSArray<SGModRow *> *> *shown = [NSMutableArray arrayWithCapacity:_sections.count];
    for (SGModSection *s in _sections) {
        NSMutableArray<SGModRow *> *rows = [NSMutableArray arrayWithCapacity:s.rows.count];
        for (SGModRow *row in s.rows) if (!row.visible || row.visible()) [rows addObject:row];
        [shown addObject:rows];
    }
    return shown;
}

// The rows that are to show now fade in where they sit and the others fade out, and whatever came in is
// scrolled toward, by half a screen at most: it opens under the switch that brought it, which may be the page's
// last row, and a long run of rows does not carry the page far from that switch. A section whose rows all go takes its heading and note with it, and
// they come back with its first row, so the whole section is faded rather than its rows. Answers whether
// anything moved; `done` runs once it has, and only then.
- (BOOL)showRowsThen:(void (^)(void))done {
    return [self showRows:YES then:done];
}

// The same, scrolling only when `scroll`: rows that come by themselves do not move the page under the eye.
- (BOOL)showRows:(BOOL)scroll then:(void (^)(void))done {
    NSArray<NSArray<SGModRow *> *> *next = [self rowsToShow];
    if ([next isEqualToArray:_shown]) return NO;
    NSMutableArray<NSIndexPath *> *gone = [NSMutableArray array], *coming = [NSMutableArray array];
    NSMutableIndexSet *flipped = [NSMutableIndexSet indexSet];
    [_sections enumerateObjectsUsingBlock:^(SGModSection *s, NSUInteger section, BOOL *stop) {
        NSArray<SGModRow *> *before = self->_shown[section], *after = next[section];
        if ((before.count == 0) != (after.count == 0)) {
            [flipped addIndex:section];
            for (NSUInteger i = 0; i < after.count; i++) [coming addObject:[NSIndexPath indexPathForRow:(NSInteger)i inSection:(NSInteger)section]];
            return;
        }
        [before enumerateObjectsUsingBlock:^(SGModRow *row, NSUInteger i, BOOL *stop) {
            if (![after containsObject:row]) [gone addObject:[NSIndexPath indexPathForRow:(NSInteger)i inSection:(NSInteger)section]];
        }];
        [after enumerateObjectsUsingBlock:^(SGModRow *row, NSUInteger i, BOOL *stop) {
            if (![before containsObject:row]) [coming addObject:[NSIndexPath indexPathForRow:(NSInteger)i inSection:(NSInteger)section]];
        }];
    }];
    NSPredicate *notFlipped = [NSPredicate predicateWithBlock:^BOOL(NSIndexPath *path, NSDictionary *bindings) {
        return ![flipped containsIndex:(NSUInteger)path.section];
    }];
    UITableView *table = self.tableView;
    [table performBatchUpdates:^{
        self->_shown = next;
        // A section is reloaded whole, or its rows moved, never both in one batch.
        [table reloadSections:flipped withRowAnimation:UITableViewRowAnimationFade];
        [table deleteRowsAtIndexPaths:[gone filteredArrayUsingPredicate:notFlipped] withRowAnimation:UITableViewRowAnimationFade];
        [table insertRowsAtIndexPaths:[coming filteredArrayUsingPredicate:notFlipped] withRowAnimation:UITableViewRowAnimationFade];
    } completion:^(BOOL finished) {
        if (scroll && coming.count) {
            CGRect rows = CGRectNull;
            for (NSIndexPath *path in coming) rows = CGRectUnion(rows, [table rectForRowAtIndexPath:path]);
            [self scrollToward:rows];
        }
        if (done) done();
    }];
    return YES;
}

// By as much as brings `rows` into view, but half the room at most either way, and never past the content.
- (void)scrollToward:(CGRect)rows {
    UITableView *table = self.tableView;
    UIEdgeInsets inset = table.adjustedContentInset;
    CGFloat room = table.bounds.size.height - inset.top - inset.bottom;
    CGFloat top = table.contentOffset.y + inset.top, bottom = top + room, move = 0;
    if (CGRectGetMaxY(rows) > bottom) move = MIN(CGRectGetMaxY(rows) - bottom, CGRectGetMinY(rows) - top);
    else if (CGRectGetMinY(rows) < top) move = CGRectGetMinY(rows) - top;
    move = MAX(-room / 2, MIN(move, room / 2));
    CGFloat most = MAX(-inset.top, table.contentSize.height + inset.bottom - table.bounds.size.height);
    CGFloat y = MAX(-inset.top, MIN(table.contentOffset.y + move, most));
    if (fabs(y - table.contentOffset.y) >= 1) [table setContentOffset:CGPointMake(table.contentOffset.x, y) animated:YES];
}

- (void)refreshVisibility {
    [self showRowsThen:nil];
}

// The switch row a row waits on, among this page's rows.
- (SGModRow *)switchFor:(SGModRow *)row {
    if (!row.waitsOn) return nil;
    for (SGModSection *s in _sections) for (SGModRow *other in s.rows) {
        if (other != row && [other.key isEqualToString:row.waitsOn]) return other;
    }
    return nil;
}

- (BOOL)isWaiting:(SGModRow *)row {
    return row.waitsOn && !SGFlag(row.waitsOn, [self switchFor:row].defaultOn);
}

- (NSIndexPath *)pathOfRow:(SGModRow *)row {
    for (NSUInteger section = 0; section < _shown.count; section++) {
        NSUInteger index = [_shown[section] indexOfObjectIdenticalTo:row];
        if (index != NSNotFound) return [NSIndexPath indexPathForRow:(NSInteger)index inSection:(NSInteger)section];
    }
    return nil;
}

// A tap on a row waiting on a switch: the switch is brought into view if it is not, then nudged.
- (void)nudgeSwitchFor:(SGModRow *)row {
    NSIndexPath *path = [self pathOfRow:[self switchFor:row]];
    if (!path) return;
    UITableView *table = self.tableView;
    CGRect shown = UIEdgeInsetsInsetRect(table.bounds, table.adjustedContentInset);
    if (CGRectContainsRect(shown, [table rectForRowAtIndexPath:path])) {
        [self nudgeAt:path];
        return;
    }
    _nudgeAfterScroll = path;
    [table scrollToRowAtIndexPath:path atScrollPosition:UITableViewScrollPositionNone animated:YES];
}

- (void)scrollViewDidEndScrollingAnimation:(UIScrollView *)scrollView {
    NSIndexPath *path = _nudgeAfterScroll;
    _nudgeAfterScroll = nil;
    if (path) [self nudgeAt:path];
}

// The switch leans 6pt toward on and springs back, with a light tap, so the eye and the finger find what to
// turn on first. Each nudge starts from wherever the last one has the switch, so taps in a row never jump it.
// With Reduce Motion nothing moves: the switch's row lights up for a moment instead.
- (void)nudgeAt:(NSIndexPath *)path {
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:path];
    UIView *toggle = controlsIn(cell).lastObject;
    if (!toggle) return;
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, toggle);
    if (UIAccessibilityIsReduceMotionEnabled()) {
        UIColor *card = cell.backgroundColor;
        cell.backgroundColor = UIColor.systemGray4Color;
        [UIView animateWithDuration:0.4 delay:0.1 options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionAllowUserInteraction animations:^{
            cell.backgroundColor = card;
        } completion:nil];
        return;
    }
    BOOL rtl = [UIView userInterfaceLayoutDirectionForSemanticContentAttribute:toggle.semanticContentAttribute] == UIUserInterfaceLayoutDirectionRightToLeft;
    UIViewPropertyAnimator *lean = [[UIViewPropertyAnimator alloc] initWithDuration:0.12 controlPoint1:CGPointMake(0.23, 1) controlPoint2:CGPointMake(0.32, 1) animations:^{
        toggle.transform = CGAffineTransformMakeTranslation(rtl ? -6 : 6, 0);
    }];
    [lean addCompletion:^(UIViewAnimatingPosition position) {
        UIViewPropertyAnimator *back = [[UIViewPropertyAnimator alloc] initWithDuration:0.4 dampingRatio:0.35 animations:^{
            toggle.transform = CGAffineTransformIdentity;
        }];
        [back startAnimation];
    }];
    [lean startAnimation];
}

// The row a switch or an ⓘ belongs to, by the cell it sits in: rows coming and going move the rows under
// them, so a position remembered when the cell was made may be stale.
- (NSIndexPath *)pathOf:(UIView *)control {
    UIView *view = control;
    while (view && ![view isKindOfClass:UITableViewCell.class]) view = view.superview;
    return view ? [self.tableView indexPathForCell:(UITableViewCell *)view] : nil;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.tableHeaderView = _intro;
    self.tableView.tableFooterView = _footer;
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    if (_intro) SGFitNote(self.tableView, _intro, 24, 0);
    if (_footer) SGFitNote(self.tableView, _footer, 16, 24);
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    SGInsetForBars(self.tableView);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Reloaded whether or not anything ticks: a choice row is showing whatever was picked on the
    // page it opened, which is gone by the time this one comes back, and may bring rows or take them.
    _shown = [self rowsToShow];
    [self.tableView reloadData];
    if (!_live) return;
    // The counters climb while the page is open; the labels are written straight into the cells so
    // that a reload never lands under a switch being dragged. A canceled back swipe appears the
    // page again without it ever disappearing, so the old timer goes first.
    [_ticker invalidate];
    _ticker = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(tick) userInfo:nil repeats:YES];
}

// Each second: the rows that come and go by themselves, then every value, slider and menu in view.
- (void)tick {
    [self showRows:NO then:nil];
    [self readValues];
    for (UITableViewCell *cell in self.tableView.visibleCells) {
        NSIndexPath *path = [self.tableView indexPathForCell:cell];
        if (!path) continue;
        SGModRow *row = [self rowAt:path];
        if ([cell isKindOfClass:SGModSliderCell.class]) [(SGModSliderCell *)cell readNumber];
        UIButton *menu = (UIButton *)cell.accessoryView;
        if (row.menu && [menu isKindOfClass:UIButton.class] && ![menu.accessibilityValue isEqualToString:row.value()] && !menu.isTracking) {
            cell.accessoryView = [self menuButtonFor:row];
        }
    }
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [_ticker invalidate];
    _ticker = nil;
}

- (void)readValues {
    for (UITableViewCell *cell in self.tableView.visibleCells) {
        if (![self.tableView indexPathForCell:cell]) continue;   // a row fading out
        SGModRow *row = [self rowAt:[self.tableView indexPathForCell:cell]];
        if (SGAccessibilityTextSize() && row.value && !row.number
            && [cell.contentConfiguration isKindOfClass:UIListContentConfiguration.class]) {
            UIListContentConfiguration *content = (UIListContentConfiguration *)cell.contentConfiguration;
            content.secondaryText = stackedValue(row);
            cell.contentConfiguration = content;
            continue;
        }
        if (row.page && row.value) {
            // valueAndChevron is sized to its text, so a new text gets a new one.
            NSString *text = row.value();
            UILabel *shown = (UILabel *)cell.accessoryView.subviews.firstObject;
            if (![shown isKindOfClass:UILabel.class] || [shown.text isEqualToString:text]) continue;
            cell.accessoryView = valueAndChevron(text);
            continue;
        }
        if (row.swatch) {
            UILabel *shown = (UILabel *)cell.accessoryView.subviews.lastObject;
            if ([shown isKindOfClass:UILabel.class] && ![shown.text isEqualToString:row.value()]) cell.accessoryView = valueView(row);
            continue;
        }
        UILabel *label = (UILabel *)cell.accessoryView;
        if (!row.value || row.page || ![label isKindOfClass:UILabel.class]) continue;
        label.text = row.value();
        [label sizeToFit];
        [cell setNeedsLayout];
    }
}

- (SGModRow *)rowAt:(NSIndexPath *)path {
    return _shown[(NSUInteger)path.section][(NSUInteger)path.row];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)table {
    return (NSInteger)_sections.count;
}

- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)_shown[(NSUInteger)section].count;
}

// A slider row is laid out by hand; every other row sizes itself.
- (CGFloat)tableView:(UITableView *)table heightForRowAtIndexPath:(NSIndexPath *)path {
    SGModRow *row = [self rowAt:path];
    return row.number ? [SGModSliderCell heightFor:row width:table.bounds.size.width - table.layoutMargins.left - table.layoutMargins.right] : UITableViewAutomaticDimension;
}

// A section with no row showing has no heading, note or gap: they would sit over no card.
- (BOOL)isEmpty:(NSInteger)section {
    return _shown[(NSUInteger)section].count == 0;
}

- (UIView *)tableView:(UITableView *)table viewForHeaderInSection:(NSInteger)section {
    NSString *title = _sections[(NSUInteger)section].title;
    return title && ![self isEmpty:section] ? SGSectionHeader(table, title) : nil;
}

- (CGFloat)tableView:(UITableView *)table heightForHeaderInSection:(NSInteger)section {
    if ([self isEmpty:section]) return CGFLOAT_MIN;
    return _sections[(NSUInteger)section].title ? SGSectionHeaderHeight() : SGSectionGap;
}

- (UIView *)tableView:(UITableView *)table viewForFooterInSection:(NSInteger)section {
    NSString *footer = _sections[(NSUInteger)section].footer;
    return footer && ![self isEmpty:section] ? SGSectionFooter(table, footer) : nil;
}

- (CGFloat)tableView:(UITableView *)table heightForFooterInSection:(NSInteger)section {
    NSString *footer = _sections[(NSUInteger)section].footer;
    return footer && ![self isEmpty:section] ? SGSectionFooterHeight(table, footer) : CGFLOAT_MIN;
}

- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    SGModRow *row = [self rowAt:path];
    if (row.number) {
        SGModSliderCell *cell = [table dequeueReusableCellWithIdentifier:@"slider"] ?: [[SGModSliderCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"slider"];
        cell.backgroundColor = SGCardBackground();
        [cell showRow:row];
        showWaiting(cell, [self isWaiting:row], [self switchFor:row].title);
        return cell;
    }
    // A checked row's cells set their own accessory and traits, which no other row resets.
    UITableViewCell *cell = SGDequeueCell(table, row.checked ? @"checked" : @"row");
    SGFillCell(cell, row.title, row.subtitle, row.color, row.symbol);
    UIListContentConfiguration *content = (UIListContentConfiguration *)cell.contentConfiguration;
    if (SGAccessibilityTextSize() && row.value) content.secondaryText = stackedValue(row);
    if (row.color) content.secondaryTextProperties.color = row.color;
    BOOL tile = row.symbol && !row.color && self.tiles;
    if (tile) content.image = row.tint ? SGTileImageTinted(row.symbol, row.tint) : SGTileImage(row.symbol);
    else if (!row.color) content.image = nil;
    cell.contentConfiguration = content;
    cell.separatorInset = UIEdgeInsetsMake(0, tile ? SGTileRowInset : row.symbol && row.color ? 48 : 16, 0, 0);

    if (row.key) {
        BOOL locked = flagRowLocked(row);
        // A lock that beats an override shows over one; the others give way to it.
        BOOL beats = NO;
        if (locked) SGLockedFlagValue(row.key, &beats);
        BOOL showsLock = locked && (beats || !SGFlagOverride(row.key));
        BOOL on = row.flag ? (showsLock ? lockedRowOn(row) : flagRowOn(row)) : SGFlag(row.key, row.defaultOn) != row.inverted;
        UIControl *toggle;
        if (row.glows) {
            SGGlowSwitch *glow = [SGGlowSwitch new];
            glow.on = on;
            glow.accessibilityLabel = row.title;
            toggle = glow;
        } else {
            UISwitch *plain = [UISwitch new];
            plain.onTintColor = SGGreen();
            plain.on = on;
            toggle = plain;
        }
        toggle.enabled = !locked;
        // A disabled switch would swallow the tap; letting it through is what gets the row asked.
        toggle.userInteractionEnabled = !locked;
        [toggle addTarget:self action:@selector(toggled:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = row.info ? [self infoButtonBeside:toggle] : toggle;
        cell.selectionStyle = locked ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    } else if (row.page) {
        UIView *link = row.value && !SGAccessibilityTextSize() ? valueAndChevron(row.value()) : SGChevronView();
        cell.accessoryView = row.info ? [self infoButtonBeside:link] : link;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else if (row.menu) {
        cell.accessoryView = [self menuButtonFor:row];
    } else if (row.value) {
        cell.accessoryView = SGAccessibilityTextSize() ? nil : valueView(row);
        cell.selectionStyle = row.action ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    } else if (row.action) {
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    if (row.checked) {
        BOOL checked = row.checked();
        // SGChoicePage's checkmark.
        UIImageView *tick = checked ? SGSymbolView(@"checkmark", 13, UIImageSymbolWeightSemibold, 16) : nil;
        tick.tintColor = SGGreen();
        cell.accessoryView = tick;
        cell.accessibilityTraits = UIAccessibilityTraitButton | (checked ? UIAccessibilityTraitSelected : 0);
    }
    BOOL waiting = [self isWaiting:row];
    showWaiting(cell, waiting, [self switchFor:row].title);
    if (waiting) cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    SGModRow *row = [self rowAt:path];
    if ([self isWaiting:row]) {
        [table deselectRowAtIndexPath:path animated:NO];
        [self nudgeSwitchFor:row];
        return;
    }
    if (flagRowLocked(row)) {
        [table deselectRowAtIndexPath:path animated:YES];
        [self explainLock];
        return;
    }
    if (row.page) [self.navigationController pushViewController:row.page() animated:YES];
    if (!row.action) return;
    row.action();
    [table deselectRowAtIndexPath:path animated:YES];
    [self readValues];
}

// A menu row's value as a pop-up button, the way Settings draws one: the name in gray over the up and down
// chevrons, the menu opening on the first touch and anchored to the button, so it points at the row on iPad.
// A pick runs the row's block and every row is read again, the ones that follow from it with it.
- (UIButton *)menuButtonFor:(SGModRow *)row {
    NSString *current = row.value();
    NSMutableArray<UIAction *> *items = [NSMutableArray array];
    __weak typeof(self) weakSelf = self;
    [row.menu enumerateObjectsUsingBlock:^(NSString *name, NSUInteger i, BOOL *stop) {
        UIAction *item = [UIAction actionWithTitle:name image:nil identifier:nil handler:^(UIAction *action) {
            if (row.chosen) row.chosen((NSInteger)i);
            [weakSelf.tableView reloadData];
        }];
        item.state = [name isEqualToString:current] ? UIMenuElementStateOn : UIMenuElementStateOff;
        [items addObject:item];
    }];
    UIButtonConfiguration *look = [UIButtonConfiguration plainButtonConfiguration];
    NSString *shown = SGAccessibilityTextSize() ? nil : current;   // under the title instead
    look.attributedTitle = shown ? [[NSAttributedString alloc] initWithString:shown attributes:@{NSFontAttributeName: SGTitleFont()}] : nil;
    look.image = [UIImage systemImageNamed:@"chevron.up.chevron.down" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:11 weight:UIImageSymbolWeightSemibold]];
    look.imagePlacement = NSDirectionalRectEdgeTrailing;
    look.imagePadding = 5;
    look.baseForegroundColor = SGGrey();
    look.contentInsets = NSDirectionalEdgeInsetsMake(8, 8, 8, 0);
    UIButton *button = [UIButton buttonWithConfiguration:look primaryAction:nil];
    button.menu = [UIMenu menuWithChildren:items];
    button.showsMenuAsPrimaryAction = YES;
    button.accessibilityLabel = row.title;
    button.accessibilityValue = current;
    [button sizeToFit];
    return button;
}

// The ⓘ to the left of the switch (or of a choice's name and chevron), the gray of a subtitle, 30pt across
// so it is easy to hit next to it.
- (UIView *)infoButtonBeside:(UIView *)toggle {
    UIButton *info = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *symbol = [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightRegular];
    [info setImage:[UIImage systemImageNamed:@"info.circle" withConfiguration:symbol] forState:UIControlStateNormal];
    info.tintColor = SGGrey();
    info.accessibilityLabel = @"About this setting";
    [info addTarget:self action:@selector(infoTapped:) forControlEvents:UIControlEventTouchUpInside];
    [toggle sizeToFit];
    CGFloat side = 30, gap = 8, height = MAX(side, toggle.bounds.size.height);
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, side + gap + toggle.bounds.size.width, height)];
    info.frame = CGRectMake(0, (height - side) / 2, side, side);
    toggle.frame = CGRectMake(side + gap, (height - toggle.bounds.size.height) / 2, toggle.bounds.size.width, toggle.bounds.size.height);
    [box addSubview:info];
    [box addSubview:toggle];
    return box;
}

- (void)infoTapped:(UIButton *)button {
    NSIndexPath *path = [self pathOf:button];
    if (!path) return;
    SGModRow *row = [self rowAt:path];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:row.title message:row.info preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

// A UISwitch or an SGGlowSwitch, both answering isOn.
- (void)toggled:(UIControl *)toggle {
    BOOL on = [(UISwitch *)toggle isOn];
    NSIndexPath *path = [self pathOf:toggle];
    if (!path) return;
    SGModRow *row = [self rowAt:path];
    if (row.flag) SGSetFlagOverride(row.key, on ? @(!row.forceOff) : nil);
    else SGSetEnabled(row.key, on != row.inverted);
    if (row.changed) row.changed(on);
    // A glowing switch is let finish its slide before the reload puts a new one in its place; rows coming
    // or going are let finish first too.
    NSTimeInterval wait = [toggle isKindOfClass:SGGlowSwitch.class] ? 0.45 : 0;
    void (^reload)(void) = ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self.tableView reloadData]; });
    };
    BOOL moved = [self showRowsThen:row.changed ? reload : nil];
    // The rows waiting on this switch stay where they are and fade to their new state.
    NSMutableArray<NSIndexPath *> *waiting = [NSMutableArray array];
    for (NSIndexPath *visible in self.tableView.indexPathsForVisibleRows) {
        if ([[self rowAt:visible].waitsOn isEqualToString:row.key]) [waiting addObject:visible];
    }
    if (waiting.count) [self.tableView reloadRowsAtIndexPaths:waiting withRowAnimation:UITableViewRowAnimationFade];
    if (row.changed && !moved) reload();
    if (on && row.warning) [self warn:row];
}

// A locked row will not move, and nothing on it says why.
- (void)explainLock {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Overridden by another setting"
                         message:@"Another switch is forcing this flag, so the row shows what it forces instead of taking a value of its own."
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)warn:(SGModRow *)row {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[row.title stringByAppendingString:@" is unstable"]
                                                                  message:row.warning
                                                           preferredStyle:UIAlertControllerStyleAlert];
    if (SGRepoURL) [alert addAction:[UIAlertAction actionWithTitle:@"Open GitHub" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        SGOpenURL(SGRepoURL);
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
