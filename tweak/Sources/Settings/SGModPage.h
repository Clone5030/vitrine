// A page of sections of rows, the shape of every feature's settings page.
#import "SGPage.h"

// A row is a switch when it has a key, a link to another page when it has a page and a slider when it has
// a number. A flag row
// switches one of Spotify's remote-config flags: on forces it (off for a forceOff row, which is how
// a flag Spotify ships on is turned off), the switch off leaves Spotify's own value. A row
// with a value reads one out on the right and is asked again while the page is open; a page row
// with a value reads it out too, next to the chevron, and is asked when the page appears. A row
// with an action runs it when tapped.
@interface SGModRow : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *subtitle;
@property (nonatomic, copy) NSString *key;
@property (nonatomic) BOOL defaultOn;
@property (nonatomic) BOOL flag;
@property (nonatomic) BOOL forceOff;
@property (nonatomic, copy) UIViewController *(^page)(void);
@property (nonatomic, copy) NSString *(^value)(void);
@property (nonatomic, copy) void (^action)(void);
@property (nonatomic, copy) NSString *warning;
@property (nonatomic, copy) void (^changed)(BOOL on);   // after the switch is stored; the page reloads
@property (nonatomic, strong) UIColor *color;   // title, subtitle and symbol, for a warning row
@property (nonatomic, copy) NSString *symbol;
@property (nonatomic, strong) UIColor *tint;   // the square under the symbol, gray when nil (SGWithTile)
// A switch row that changes the whole app draws SGGlowSwitch instead of a UISwitch.
@property (nonatomic) BOOL glows;
// The switch shows the opposite of what is stored under its key (SGShownRow).
@property (nonatomic) BOOL inverted;
// An ⓘ button beside the row's switch, whose tap reads this out under the row's title.
@property (nonatomic, copy) NSString *info;
// The row shows only while this answers YES, asked again whenever a switch on the page is flipped, the
// page comes back from a choice's list or it is told to (-refreshVisibility): the row fades in or out where
// it sits. Nil shows it always. A row that only waits on a switch takes `waitsOn` instead.
@property (nonatomic, copy) BOOL (^visible)(void);
// The key of a switch row on the same page this row works under: while that switch is off the row stays
// where it is, grayed out, and a tap on it nudges the switch.
@property (nonatomic, copy) NSString *waitsOn;
// A choice row's: a line under each name in its list, in the same order, and what runs once one is stored.
@property (nonatomic, copy) NSArray<NSString *> *choiceNotes;
@property (nonatomic, copy) NSString *choiceFooter;   // under a choice row's list
@property (nonatomic, copy) void (^chosen)(NSInteger index);
// A slider row's (SGSliderRow): its range and step, and the blocks that read its number, store one and
// write one out.
@property (nonatomic) double minimum, maximum, step;
@property (nonatomic, copy) double (^number)(void);
@property (nonatomic, copy) void (^setNumber)(double value);
@property (nonatomic, copy) NSString *(^format)(double value);
// A menu row's (SGMenuRow): the names its pull-down menu offers, the current one being whichever `value` reads.
@property (nonatomic, copy) NSArray<NSString *> *menu;
// A small rounded square of this color before the row's value.
@property (nonatomic, copy) UIColor *(^swatch)(void);
// One of a few rows picked from on the page itself (an action row each): a checkmark against it while this answers
// YES, read as the row is drawn, so its action reloads the table.
@property (nonatomic, copy) BOOL (^checked)(void);
@end

@interface SGModSection : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSArray<SGModRow *> *rows;
@property (nonatomic, copy) NSString *footer;
@end

@interface SGModPage : SGPage
- (instancetype)initWithTitle:(NSString *)title intro:(NSString *)intro sections:(NSArray<SGModSection *> *)sections footer:(NSString *)footer;
// Asks every row's `visible` again, after something other than a switch on the page changed what it reads.
- (void)refreshVisibility;
// Rows draw their symbol on a colored tile; off, the default, they show none. Mod Settings' main page has them.
@property (nonatomic) BOOL tiles;
@end

// The intro of every page whose switches the hooks read at launch.
extern NSString *const SGRestartNote;

SGModRow *SGSwitchRow(NSString *title, NSString *subtitle, NSString *key);   // on until switched off
SGModRow *SGHideRow(NSString *title, NSString *subtitle, NSString *key);     // off until switched on
// A part of Spotify the mod can take away, named for the part and shown on: turning it off stores YES under
// `hideKey`, the way SGHideRow does, so a reset (stock) shows the part again.
SGModRow *SGShownRow(NSString *title, NSString *subtitle, NSString *hideKey);
// A switch for something the mod adds rather than takes away: off until it is asked for.
SGModRow *SGOptionRow(NSString *title, NSString *subtitle, NSString *key);
// A switch whose work is not finished: turning it on says so first, and offers the repo.
SGModRow *SGUnstableRow(NSString *title, NSString *subtitle, NSString *key, NSString *warning);
SGModRow *SGFlagRow(NSString *title, NSString *key);   // forces one of Spotify's flags on
SGModRow *SGKillRow(NSString *title, NSString *key);   // forces a flag Spotify ships on off
SGModRow *SGStatRow(NSString *title, NSString *(^value)(void));
SGModRow *SGActionRow(NSString *title, NSString *subtitle, void (^action)(void));
// Red, with a warning symbol: something is wrong and tapping the row says what to do about it.
SGModRow *SGWarningRow(NSString *title, NSString *subtitle, void (^action)(void));
SGModRow *SGPageRow(NSString *title, UIViewController *(^page)(void));
// A setting picked from a list of names, stored under `key` as the index into it: the row reads the
// name of the current one out and opens a list of them, a checkmark against that one.
SGModRow *SGChoiceRow(NSString *title, NSString *subtitle, NSString *key, NSArray<NSString *> *choices, NSInteger fallback);
// A number on a slider under the row's title, written out by `format` on the right: the thumb snaps to
// `step` and each step is stored through `set` as the thumb reaches it, so a setting applying as it
// changes applies while it is dragged. `subtitle` may be nil.
SGModRow *SGSliderRow(NSString *title, NSString *subtitle, double minimum, double maximum, double step,
                      double (^get)(void), void (^set)(double value), NSString *(^format)(double value));
// A setting picked from a short list without leaving the page: the value is a button whose pull-down menu
// lists `choices`, a checkmark against the one `value` reads, and picking one runs `chosen` with its index,
// after which the page reads every row again.
SGModRow *SGMenuRow(NSString *title, NSArray<NSString *> *choices, NSString *(^value)(void), void (^chosen)(NSInteger index));
// The system color picker in a page sheet, opaque colors only: the checkmark hands 0xRRGGBB to `picked`,
// closing or swiping the sheet away keeps what was there.
void SGPickColor(NSString *title, NSInteger initial, void (^picked)(NSInteger rgb));
UIColor *SGColorRGB(NSInteger rgb);   // 0xRRGGBB, opaque
SGModRow *SGLinkRow(NSString *title, NSString *subtitle, NSString *url);
SGModRow *SGStatActionRow(NSString *title, NSString *subtitle, NSString *(^value)(void), void (^action)(void));
SGModSection *SGSection(NSString *title, NSArray<SGModRow *> *rows);
SGModSection *SGNotedSection(NSString *title, NSArray<SGModRow *> *rows, NSString *footer);
// Gives a row its leading symbol, drawn on a gray tile unless the row has a color of its own.
SGModRow *SGWithSymbol(SGModRow *row, NSString *symbol);
// The same on a tile of `color`, the way Settings colors the icon of each of its rows.
SGModRow *SGWithTile(SGModRow *row, NSString *symbol, UIColor *color);
