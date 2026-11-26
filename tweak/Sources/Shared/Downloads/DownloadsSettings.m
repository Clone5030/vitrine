// Mod Settings > Downloads. A glass card says what is happening; under it, the current track's actions
// (download it, download its album, check it, cancel), the quota and device checks, the download status and the
// diagnostics. Every action is the companion library's (DownloadsBridge.h); this file only draws and asks.
#import "Core/SGCore.h"
#import "Core/SGGlass.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "Downloads.h"
#import "DownloadsBridge.h"

static NSString *const kPixieURL = @"https://github.com/Glongq/Vitrine-Pixie";

#pragma mark - helpers

static void say(NSString *title, NSString *message) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [SGTopController() presentViewController:alert animated:YES completion:nil];
}

static void changed(void) {
    [NSNotificationCenter.defaultCenter postNotificationName:SGDownloadsDidChangeNotification object:nil];
}

// One check or slot command at a time: the rows show "Working…" and ignore taps until it answers.
static BOOL busy;
static void setBusy(BOOL on) {
    busy = on;
    changed();
}

static NSDictionary *keyMode(void) {
    NSDictionary *mode = [SGDownloadsCompanion() snapshot][@"key_request_mode"];
    return [mode isKindOfClass:NSDictionary.class] ? mode : @{};
}

#pragma mark - the card

static char kCardGlassKey;

@interface SGDownloadsCard : UIView
- (void)update;
@end

@implementation SGDownloadsCard {
    UIImageView *_icon;
    UILabel *_title, *_detail, *_state;
    UIView *_dot;
    BOOL _available, _active;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _icon = [UIImageView new];
    _icon.contentMode = UIViewContentModeCenter;
    _icon.tintColor = UIColor.whiteColor;
    _title = [UILabel new];
    _title.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
    _title.textColor = UIColor.whiteColor;
    _detail = [UILabel new];
    _detail.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
    _detail.textColor = [UIColor colorWithWhite:1 alpha:0.72];
    _detail.numberOfLines = 3;
    _state = [UILabel new];
    _state.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    _state.textColor = UIColor.whiteColor;
    _dot = [UIView new];
    _dot.layer.cornerRadius = 4;
    for (UIView *view in @[_icon, _title, _detail, _dot, _state]) [self addSubview:view];
    self.isAccessibilityElement = NO;
    return self;
}

- (void)update {
    _available = SGDownloadsAvailable();
    _active = _available && SGDownloadsActive();
    NSString *summary = SGDownloadsSummary();
    NSRange newline = [summary rangeOfString:@"\n"];
    if (_available && newline.location != NSNotFound) {
        _title.text = [summary substringToIndex:newline.location];
        _detail.text = [summary substringFromIndex:newline.location + 1];
    } else {
        _title.text = @"Downloads";
        _detail.text = summary;
    }
    UIColor *tint = !_available ? UIColor.systemGrayColor : _active ? UIColor.systemOrangeColor : UIColor.systemGreenColor;
    _icon.image = [UIImage systemImageNamed:!_available ? @"icloud.slash.fill" : _active ? @"arrow.down.circle.fill" : @"checkmark.circle.fill"
                          withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:26 weight:UIImageSymbolWeightSemibold]];
    _icon.tintColor = tint;
    _dot.backgroundColor = tint;
    _state.text = !_available ? @"Unavailable" : _active ? @"Downloading" : @"Ready";
    self.accessibilityLabel = [NSString stringWithFormat:@"%@. %@. %@", _title.text, _detail.text, _state.text];
    self.isAccessibilityElement = YES;
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect card = CGRectInset(self.bounds, 16, 6);
    UIVisualEffectView *glass = SGGlassFor(self, &kCardGlassKey);
    glass.frame = card;
    SGShapeGlass(glass, 30, NO);

    CGFloat pad = 18, orb = 52;
    UIVisualEffectView *orbGlass = SGGlassAt(self, 1);
    orbGlass.frame = CGRectMake(CGRectGetMinX(card) + pad, CGRectGetMinY(card) + pad, orb, orb);
    SGShapeGlass(orbGlass, orb / 2, YES);
    _icon.frame = orbGlass.frame;

    CGFloat textX = CGRectGetMaxX(orbGlass.frame) + 14, textW = MAX(0, CGRectGetMaxX(card) - pad - textX);
    _title.frame = CGRectMake(textX, CGRectGetMinY(card) + pad, textW, 26);
    CGSize detail = [_detail sizeThatFits:CGSizeMake(textW, CGFLOAT_MAX)];
    _detail.frame = CGRectMake(textX, CGRectGetMaxY(_title.frame) + 2, textW, MIN(ceil(detail.height), 58));

    CGSize state = [_state sizeThatFits:CGSizeMake(200, 30)];
    CGFloat pillW = ceil(state.width) + 16 + 8 + 12, pillH = 30;
    UIVisualEffectView *pill = SGGlassAt(self, 2);
    pill.frame = CGRectMake(CGRectGetMinX(card) + pad, CGRectGetMaxY(card) - pad - pillH, pillW, pillH);
    SGShapeGlass(pill, pillH / 2, YES);
    _dot.frame = CGRectMake(CGRectGetMinX(pill.frame) + 12, CGRectGetMidY(pill.frame) - 4, 8, 8);
    _state.frame = CGRectMake(CGRectGetMaxX(_dot.frame) + 8, CGRectGetMinY(pill.frame), ceil(state.width), pillH);
}

- (CGSize)sizeThatFits:(CGSize)size { return CGSizeMake(size.width, 168); }
@end

#pragma mark - status details

@interface SGDownloadsDetailsPage : SGModPage
@end

@implementation SGDownloadsDetailsPage {
    NSUInteger _generation;
}

- (instancetype)init {
    __block __weak SGDownloadsDetailsPage *weakSelf = nil;
    SGModRow *refresh = SGWithSymbol(SGActionRow(@"Refresh status", nil, ^{ [weakSelf load]; }), @"arrow.clockwise");
    self = [super initWithTitle:@"Download status" intro:nil sections:@[SGSection(nil, @[refresh])] footer:nil];
    weakSelf = self;
    return self;
}

- (void)show:(NSString *)text {
    UIView *note = SGNote(text.length ? text : @"No data");
    SGFitNote(self.tableView, note, 8, 12);
    self.tableView.tableHeaderView = note;
}

- (void)load {
    Class<SGDownloadsCompanion> companion = SGDownloadsCompanion();
    NSUInteger expected = ++_generation;
    BOOL diagnostics = [companion diagnosticsEnabled];
    if (diagnostics) [companion refreshJournal];
    else [self show:@"Diagnostics are off, so the log is not kept. Switch Diagnostics on (Downloads > Diagnostics) to collect download history. Checking the current track works without it."];
    __weak SGDownloadsDetailsPage *weak = self;
    void (^fetch)(void) = ^{
        [companion loadDetails:YES completion:^(NSDictionary *value) {
            SGDownloadsDetailsPage *page = weak;
            if (!page || page->_generation != expected) return;
            [page show:value[@"journal_summary"]];
        }];
    };
    if (!diagnostics) return;
    [self show:@"Updating…"];
    fetch();
    // The journal settles a moment after it is asked to refresh.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SGDownloadsDetailsPage *page = weak;
        if (page && page->_generation == expected && page.view.window) fetch();
    });
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self load];
}

- (void)viewWillDisappear:(BOOL)animated {
    _generation++;
    [super viewWillDisappear:animated];
}
@end

#pragma mark - the page

@interface SGDownloadsPage : SGModPage
@end

@implementation SGDownloadsPage {
    SGDownloadsCard *_card;
    NSTimer *_timer;
    BOOL _lastActive;
    NSString *_lastSummary;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _card = [[SGDownloadsCard alloc] initWithFrame:CGRectMake(0, 0, self.tableView.bounds.size.width, 168)];
    [_card update];
    self.tableView.tableHeaderView = _card;
}

- (void)tick {
    BOOL active = SGDownloadsAvailable() && SGDownloadsActive();
    NSString *summary = SGDownloadsSummary();
    if (active == _lastActive && [summary isEqualToString:_lastSummary]) return;
    _lastActive = active;
    _lastSummary = summary;
    [_card update];
    changed();
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    _lastActive = SGDownloadsAvailable() && SGDownloadsActive();
    _lastSummary = SGDownloadsSummary();
    [_card update];
    if (!_timer) {
        // Once a second while the page is on screen: what a download reports, not a frame loop.
        _timer = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(tick) userInfo:nil repeats:YES];
        _timer.tolerance = 0.3;
    }
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [_timer invalidate];
    _timer = nil;
}

- (void)dealloc { [_timer invalidate]; }
@end

#pragma mark - rows

static SGModRow *symbolRow(SGModRow *row, NSString *symbol, UIColor *color) {
    row = SGWithSymbol(row, symbol);
    if (color) row.color = color;
    return row;
}

// Every command that talks to Spotify's servers: one at a time, with the result said in an alert.
static void refreshQuotas(void) {
    if (busy) return;
    setBusy(YES);
    [SGDownloadsCompanion() refreshCompatibility:^(NSDictionary *result) {
        setBusy(NO);
        say(@"Quota and license check", [SGDownloadsCompanion() compatibilityText:result]);
    }];
}

static void enableOffline(void) {
    if (busy) return;
    setBusy(YES);
    [SGDownloadsCompanion() enableOffline:^(NSDictionary *result, NSString *error) {
        setBusy(NO);
        if (error) { say(@"Registration not confirmed", error); return; }
        NSDictionary *licenses = result[@"sources"][@"licenses"];
        say(@"Offline registration confirmed",
            [NSString stringWithFormat:@"Spotify reports this copy as enabled for offline listening. Free device slots: %@ of %@.",
             licenses[@"free_licenses"] ?: @"?", licenses[@"max_licenses"] ?: @"?"]);
    }];
}

static void confirmRelease(NSDictionary *plan, NSArray *devices) {
    NSMutableArray *names = [NSMutableArray array], *ids = [NSMutableArray array];
    for (NSDictionary *device in devices) {
        NSString *cache = device[@"cache_id"] ?: @"";
        [ids addObject:cache];
        [names addObject:[NSString stringWithFormat:@"%@ · %@", device[@"name"] ?: @"Device", [cache substringToIndex:MIN(cache.length, 8)]]];
    }
    NSString *message = [NSString stringWithFormat:@"Only use this to fix download problems, such as a device-limit error. Do not reset slots if downloads work normally.\n\nDisable offline registration for:\n%@\n\nCached tracks in these copies may become unavailable offline. The device list and free-slot count are verified after each command.", [names componentsJoinedByString:@"\n"]];
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"Release offline registrations?" message:message preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Release %lu registration%@", (unsigned long)ids.count, ids.count == 1 ? @"" : @"s"]
                                                style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        setBusy(YES);
        [SGDownloadsCompanion() releaseSlots:plan[@"id"] cacheIDs:ids completion:^(NSDictionary *result, NSString *error) {
            setBusy(NO);
            if (error) { say(@"Release not fully confirmed", error); return; }
            UIAlertController *done = [UIAlertController alertControllerWithTitle:@"Released slots verified"
                message:[NSString stringWithFormat:@"Free device slots: %@ of %@. Enabling offline listening on this copy uses one slot.", result[@"free_licenses"], result[@"max_licenses"]]
                preferredStyle:UIAlertControllerStyleAlert];
            [done addAction:[UIAlertAction actionWithTitle:@"Done" style:UIAlertActionStyleCancel handler:nil]];
            [done addAction:[UIAlertAction actionWithTitle:@"Enable this copy" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { enableOffline(); }]];
            [SGTopController() presentViewController:done animated:YES completion:nil];
        }];
    }]];
    [SGTopController() presentViewController:confirm animated:YES completion:nil];
}

static void manageSlots(void) {
    if (busy) return;
    setBusy(YES);
    [SGDownloadsCompanion() previewSlots:^(NSDictionary *plan, NSString *error) {
        setBusy(NO);
        if (error) { say(@"No registration changed", error); return; }
        NSArray *devices = plan[@"active_devices"];
        UIViewController *top = SGTopController();
        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Occupied offline slots"
            message:[NSString stringWithFormat:@"Free slots: %@ of %@. Only release registrations to fix download problems. Old copies may lose offline access. Select a registration to review; nothing changes until you confirm.", plan[@"free_licenses"], plan[@"max_licenses"]]
            preferredStyle:UIAlertControllerStyleActionSheet];
        for (NSDictionary *device in devices) {
            NSString *cache = device[@"cache_id"] ?: @"";
            NSString *name = [NSString stringWithFormat:@"%@ · %@", device[@"name"] ?: @"Device", [cache substringToIndex:MIN(cache.length, 8)]];
            [sheet addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) { confirmRelease(plan, @[device]); }]];
        }
        if (devices.count > 1)
            [sheet addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Release all %lu registrations…", (unsigned long)devices.count]
                                                      style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) { confirmRelease(plan, devices); }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        sheet.popoverPresentationController.sourceView = top.view;
        sheet.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(top.view.bounds), CGRectGetMidY(top.view.bounds), 1, 1);
        [top presentViewController:sheet animated:YES completion:nil];
    }];
}

static void requestModeTapped(void) {
    NSDictionary *mode = keyMode();
    if (![mode[@"restore_zero_supported"] boolValue]) {
        say(@"Request mode", mode[@"detail"] ?: @"Mode 0 is the one that lets Spotify issue offline licenses. Nothing needs restoring.");
        return;
    }
    UIAlertController *choice = [UIAlertController alertControllerWithTitle:@"Restore mode 0?"
        message:@"The verified selector was observed returning 1. This only restores mode 0, after a fresh quota and license check. It does not guarantee that downloading will work."
        preferredStyle:UIAlertControllerStyleAlert];
    [choice addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [choice addAction:[UIAlertAction actionWithTitle:@"Restore mode 0" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        setBusy(YES);
        [SGDownloadsCompanion() restoreKeyMode:^(BOOL didChange, NSString *reason) {
            setBusy(NO);
            say(didChange ? @"Mode 0 restored" : @"Mode unchanged", reason);
        }];
    }]];
    [SGTopController() presentViewController:choice animated:YES completion:nil];
}

static NSString *workingOr(NSString *(^value)(void)) { return busy ? @"Working…" : value(); }

UIViewController *SGDownloadsSettingsPage(void) {
    if (!SGDownloadsAvailable()) {
        SGModRow *why = SGWarningRow(@"Downloads are unavailable in this build", @"Tap to see why", ^{
            say(@"Downloads", SGDownloadsUnavailableReason());
        });
        return [[SGDownloadsPage alloc] initWithTitle:@"Downloads" intro:nil sections:@[
            SGSection(nil, @[why]),
            SGSection(@"About", @[symbolRow(SGLinkRow(@"Pixie Download Manager", @"Glongq/Vitrine-Pixie, where the downloads come from", kPixieURL), @"link", nil)]),
        ] footer:nil];
    }
    Class<SGDownloadsCompanion> companion = SGDownloadsCompanion();
    SGSetEnabled(SGKeyDownloadsDiagnostics, [companion diagnosticsEnabled]);

    SGModRow *download = symbolRow(SGActionRow(@"Download current track", @"The song playing right now", ^{ [SGDownloadsCompanion() downloadTrack]; }),
                                   @"arrow.down.circle.fill", nil);
    download.visible = ^BOOL { return !SGDownloadsActive(); };
    SGModRow *status = symbolRow(SGActionRow(@"Track download status", @"A download is running", ^{ [SGDownloadsCompanion() downloadTrack]; }),
                                 @"arrow.down.circle.fill", nil);
    status.visible = ^BOOL { return SGDownloadsActive(); };
    SGModRow *album = symbolRow(SGActionRow(@"Download current track's album", @"Every track on its album", ^{ [SGDownloadsCompanion() downloadAlbum]; }),
                                @"square.stack.fill", nil);
    SGModRow *check = symbolRow(SGActionRow(@"Check current track", @"Is it saved for offline listening?", ^{ [SGDownloadsCompanion() checkTrack]; }),
                                @"checkmark.circle.fill", nil);
    SGModRow *cancel = symbolRow(SGActionRow(@"Cancel download", nil, ^{ [SGDownloadsCompanion() cancelDownload]; changed(); }),
                                 @"xmark.circle.fill", UIColor.systemOrangeColor);
    cancel.visible = ^BOOL { return SGDownloadsActive(); };

    SGModRow *mode = symbolRow(SGStatActionRow(@"Configured request mode", @"Mode 0 lets Spotify issue offline licenses", ^NSString * {
        NSInteger configured = [keyMode()[@"configured_mode"] respondsToSelector:@selector(integerValue)] ? [keyMode()[@"configured_mode"] integerValue] : -1;
        return workingOr(^NSString * { return configured < 0 ? @"?" : configured == 0 ? @"0" : @"1"; });
    }, ^{ if (!busy) requestModeTapped(); }), @"arrow.triangle.2.circlepath", nil);
    SGModRow *quotas = symbolRow(SGStatActionRow(@"Refresh quotas and licenses", @"Read only · nothing is reset", ^NSString * { return busy ? @"Working…" : @""; }, ^{ refreshQuotas(); }),
                                 @"arrow.clockwise", nil);
    SGModRow *slots = symbolRow(SGActionRow(@"Manage offline device slots", @"Troubleshooting only · may disable old copies' offline access", ^{ manageSlots(); }),
                                @"externaldrive.badge.person.crop", UIColor.systemOrangeColor);
    SGModRow *enable = symbolRow(SGActionRow(@"Enable offline listening on this copy", @"Uses one available device-license slot", ^{ enableOffline(); }),
                                 @"iphone.badge.play", nil);

    SGModRow *log = symbolRow(SGPageRow(@"Download status", ^UIViewController * { return [SGDownloadsDetailsPage new]; }), @"chart.bar.fill", nil);
    SGModRow *diagnostics = SGWithSymbol(SGOptionRow(@"Diagnostics", @"Detailed passive events, off by default", SGKeyDownloadsDiagnostics), @"slider.horizontal.3");
    diagnostics.changed = ^(BOOL on) { [SGDownloadsCompanion() setDiagnosticsEnabled:on]; };
    SGModRow *send = symbolRow(SGActionRow(@"Send log", @"One package: report, events and download history", ^{ [SGDownloadsCompanion() sendLog]; }),
                               @"square.and.arrow.up", nil);

    NSArray<SGModSection *> *sections = @[
        SGNotedSection(@"Current track", @[download, status, album, check, cancel], @"Tracks are saved in Spotify for offline listening."),
        SGNotedSection(@"Download compatibility", @[mode, quotas, slots, enable],
                       @"5 licenses = up to 5 devices with offline music.\n\nOnly change settings in this menu if downloads are not working."),
        SGSection(@"Status", @[log]),
        SGNotedSection(@"Diagnostics", @[diagnostics, send], @"Enable Diagnostics for detailed passive events."),
        SGNotedSection(@"About", @[symbolRow(SGLinkRow(@"Pixie Download Manager", @"Glongq/Vitrine-Pixie, the engine behind this page", kPixieURL), @"link", nil)],
                       @"Spotify's own download buttons on playlists, albums and menus work too. Music stays in Spotify's offline storage."),
    ];
    return [[SGDownloadsPage alloc] initWithTitle:@"Downloads" intro:nil sections:sections footer:nil];
}
