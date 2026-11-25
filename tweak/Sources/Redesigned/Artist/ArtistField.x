// Artist redesign: the photo's field behind the whole page, and the tab strip gone.
//
// Tree (trees/clean/artist/01.txt:26-40). The page is a TemplateView holding two scroll views of the page's
// size -- PCFFTabLayoutViewController.overlayScrollView and .containerScrollView -- and the container's stack:
// the header, then PCFFTabLayoutViewController.tabsViewAccessibilityID, the strip of tabs
// (Components.UI.TabsSectionHeading, 44pt) over a paging scroll view with one list per tab. The field goes
// under all of it, as the page's bottom-most view, and what Spotify paints the page, its lists and its rows
// with -- the base surface -- is kept clear by the Kit's repaint hook while sgr_artistRoot is this page.
//
// The strip is Music, Video and Merch. The Music list is the page the Music app gives an artist: the videos
// and the merch have their own tabs only so that they can be left out, so the strip goes and the Music list
// stays. The strip sits in an AutoLayoutStackView, which traps when a view in it hides, so it goes invisible
// and the pages under it move up into its place and stop paging, the way the native look's switch does it
// (Native/Artist/Artist.x). With its switch off (SGRKeyArtistHideTabs) the strip and the paging stay Spotify's.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Artist.h"

static NSString *const kPageIdentifier = @"creator-page";

// Above for the bounce at the top of the page, below for the one at the end of it.
static const UIEdgeInsets kBleed = {600, 0, 600, 0};

static char kFieldKey;
static BOOL hideTabs;

#pragma mark - the page

UIView *SGRArtistPageOf(UIView *view) {
    for (UIView *v = view; v; v = v.superview) {
        if ([v.accessibilityIdentifier isEqualToString:kPageIdentifier]) return v;
    }
    return nil;
}

#pragma mark - the page's field

static SGRArtworkField *fieldOn(UIView *view) {
    for (UIView *v = view; v; v = v.superview) {
        SGRArtworkField *field = objc_getAssociatedObject(v, &kFieldKey);
        if (field) return field;
    }
    return nil;
}

UIColor *SGRArtistFieldColor(UIView *view) {
    SGRArtworkField *field = fieldOn(view);
    return field.fieldColor ?: SGRNeutralField();
}

void SGRArtistSetArtwork(UIView *view, UIImage *image) {
    if (image) [fieldOn(view) setArtwork:image identity:nil animated:YES];
}

static SGRArtworkField *fieldIn(UIView *page) {
    SGRArtworkField *field = objc_getAssociatedObject(page, &kFieldKey);
    if (field) return field;
    field = [[SGRArtworkField alloc] initWithFrame:page.bounds];
    field.bleed = kBleed;
    // The photo's main color, not its bottom edge, which on a portrait is the artist's shirt.
    field.mainColor = YES;
    objc_setAssociatedObject(page, &kFieldKey, field, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SGLog(@"redesign artist: field on the page %.0fx%.0f", page.bounds.size.width, page.bounds.size.height);
    return field;
}

%hook _TtC32CreativeWorkPlatform_TemplateKit12TemplateView
- (void)layoutSubviews {
    %orig;
    UIView *page = (UIView *)self;
    if (![page.accessibilityIdentifier isEqualToString:kPageIdentifier] || page.bounds.size.height < 200) return;
    // The page the repaint hook keeps clear is the one laying out, which is the one on screen.
    sgr_artistRoot = page;
    SGRArtworkField *field = fieldIn(page);
    if (field.superview != page) [page insertSubview:field atIndex:0];
    else if (page.subviews.firstObject != field) [page sendSubviewToBack:field];
    if (!CGRectEqualToRect(field.frame, page.bounds)) field.frame = page.bounds;
    // The page comes in whole once its photo has been read (Kit/SGRField.h).
    [field holdPage:page];
}
%end

// Each tab's list paints itself the base surface from its own pass, and may have before the page first laid
// out and the repaint hook knew the page; its collection view is a private class whose name carries a build
// hash, so the list view around it -- one public name, one child -- is where it is cleared, as the album's is.
%hook _TtC32CreativeWorkPlatform_TemplateKit28CreativeWorkTemplateListView
- (void)layoutSubviews {
    %orig;
    UIView *list = (UIView *)self;
    if (!SGRArtistPageOf(list)) return;
    if (list.backgroundColor && SGIsBaseSurface(list.backgroundColor.CGColor)) list.backgroundColor = UIColor.clearColor;
    for (UIView *sub in list.subviews) {
        if (sub.backgroundColor && SGIsBaseSurface(sub.backgroundColor.CGColor)) sub.backgroundColor = UIColor.clearColor;
    }
}
%end

#pragma mark - the tab strip

static void hideStrip(UIView *strip) {
    if (strip.alpha != 0) strip.alpha = 0;
    if (strip.userInteractionEnabled) strip.userInteractionEnabled = NO;
    strip.accessibilityElementsHidden = YES;
    CGFloat lift = CGRectGetHeight(strip.bounds);
    for (UIView *v in strip.superview.subviews) {
        if (![v isKindOfClass:UIScrollView.class]) continue;
        UIScrollView *pages = (UIScrollView *)v;
        if (pages.scrollEnabled) pages.scrollEnabled = NO;
        CGAffineTransform move = CGAffineTransformMakeTranslation(0, -lift);
        if (!CGAffineTransformEqualToTransform(pages.transform, move)) pages.transform = move;
    }
    static BOOL logged;
    if (!logged) {
        logged = YES;
        SGLog(@"redesign artist: the tab strip gone, the Music list up %.0fpt into its place", lift);
    }
}

// The strip's buttons are the one class of it Spotify names, and they lay out whenever the strip does.
%hook _TtCOOOE16PodcastUI_ECMKitO19LegacyUI_ECMCoreKit10Components18TabsSectionHeading2UI7Private9TabButton
- (void)layoutSubviews {
    %orig;
    for (UIView *v = ((UIView *)self).superview; v; v = v.superview) {
        if (![v.accessibilityIdentifier isEqualToString:@"Components.UI.TabsSectionHeading"]) continue;
        if (hideTabs && SGRArtistPageOf(v)) hideStrip(v);
        return;
    }
}
%end

%ctor {
    // No flags forced here. `ios-creator-impl.context_menu_in_navigation_bar_enabled_artist` moves more out of
    // the header's row, and with it gone Spotify's OverflowStackView force-unwraps the tallest view of a line
    // that has none and traps as the page opens (device crash 2026-09-18 19:09, SIGTRAP in -[OverflowStackView
    // updateConstraints], OverflowStackViewLayoutBuilder.Line.tallestView nil). The row stays Spotify's, and
    // ArtistHeader.x draws more itself.
    if (!SGRedesignedUI()) return;
    hideTabs = SGHidden(SGRKeyArtistHideTabs);
    %init;
    SGRequireClasses(@[
        @"_TtC32CreativeWorkPlatform_TemplateKit12TemplateView",
        @"_TtC32CreativeWorkPlatform_TemplateKit28CreativeWorkTemplateListView",
        @"_TtCOOOE16PodcastUI_ECMKitO19LegacyUI_ECMCoreKit10Components18TabsSectionHeading2UI7Private9TabButton",
    ]);
}
