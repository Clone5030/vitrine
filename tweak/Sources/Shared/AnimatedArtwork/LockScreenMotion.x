// The lock screen's artwork moves: the track's Canvas, else Apple Music's animated album cover, and with
// Every song chosen, failing both, the cover over a moving blur of itself (SGFluidClip.h). iOS 26 takes a
// local video through MPMediaItemAnimatedArtwork under one of two now playing keys, 1:1 or 3:4, of those
// the system lists. It rides on Spotify's now playing info as an extra (Shared/Player/NowPlayingExtras.h).
//
// The system turns down a clip of another shape than its key's, and a preview still of another shape with
// it, so a clip that does not fit (a Canvas is mostly 9:16) is cut to the key's shape about its middle, and
// the still is filled to the size the system asks for. The cut, like the cover's clip, is made only when the
// lock screen asks for the video, and kept: the cut by the clip and shape, the cover's clip by the picture
// the track names, so an album's songs share one.
//
// The choice is read on every track, and a change applies at once: Off takes the clip away, Moving artwork
// and Every song look the playing track up. Lyrics is LyricsArtwork.x's, which reads it the same way, so the
// lock screen widget's star (LockScreenStar.x) can swap the two without a restart. Moving artwork with
// lyrics looks the track up too and hands its clip to LyricsArtwork.x, which draws the lines over it.
#import <MediaPlayer/MediaPlayer.h>
#import "Core/SGCore.h"
#import "AnimatedArtwork.h"
#import "SGFluidClip.h"
#import "SGMotionClip.h"
#import "Shared/LockScreenLyrics/LockScreenLyrics.h"
#import "Shared/LockScreenLyrics/SGLyricsClip.h"
#import "Shared/Player/NowPlayingExtras.h"
#import "Shared/Player/PlayerState.h"

// How far a clip's width over height may be from its key's and still be taken as it is.
static const CGFloat kSameShape = 0.02;

static NSString *sg_title;
static NSString *sg_picture;   // the picture the track names, for the cover's clip
static NSUInteger sg_walk;   // counts the tracks walked, so a poster that comes late is told from the newest
static SGLockArtwork sg_choice;
static dispatch_queue_t sg_queue;   // cuts clips and makes the cover's, one at a time
static SGMotionFollower *sg_follower;

// Moving artwork with lyrics walks the sources too, and hands the clip to LyricsArtwork.x.
static BOOL motionOn(SGLockArtwork choice) {
    return choice == SGLockArtworkMotion || choice == SGLockArtworkEverySong || choice == SGLockArtworkMotionLyrics;
}

// Full-screen cover is for a track with no moving artwork, under any choice but the two with lyrics, which fill
// the same 3:4 key themselves.
static BOOL fullCoverOn(SGLockArtwork choice) {
    return SGFlag(SGKeyMotionFullCover, NO) && !SGLockArtworkShowsLyrics(choice);
}

// The key a clip shown at `shown` goes under, and the shape it is cut to (width over height): 1:1 for a
// square clip, else 3:4, each where the system lists it, else the other. nil while it lists neither, before
// MediaPlayer has started: the next track asks again.
API_AVAILABLE(ios(26.0))
static NSString *keyFor(CGSize shown, CGFloat *ratio) {
    NSArray<NSString *> *keys = MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys;
    BOOL square = shown.height > 0 && fabs(shown.width / shown.height - 1) <= kSameShape;
    BOOL tall = [keys containsObject:MPNowPlayingInfoProperty3x4AnimatedArtwork];
    if ([keys containsObject:MPNowPlayingInfoProperty1x1AnimatedArtwork] && (square || !tall)) {
        *ratio = 1;
        return MPNowPlayingInfoProperty1x1AnimatedArtwork;
    }
    *ratio = 0.75;
    return tall ? MPNowPlayingInfoProperty3x4AnimatedArtwork : nil;
}

// `image` filled into `size` about its middle, at scale 1 and opaque, as the preview the system asked for.
static UIImage *filled(UIImage *image, CGSize size) {
    size = CGSizeMake(round(size.width), round(size.height));
    if (!image || size.width < 1 || size.height < 1 || image.size.width <= 0 || image.size.height <= 0) return image;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    format.opaque = YES;
    CGFloat scale = MAX(size.width / image.size.width, size.height / image.size.height);
    CGSize drawn = CGSizeMake(image.size.width * scale, image.size.height * scale);
    return [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [image drawInRect:CGRectMake((size.width - drawn.width) / 2, (size.height - drawn.height) / 2, drawn.width, drawn.height)];
    }];
}

API_AVAILABLE(ios(26.0))
static void show(NSURL *file) {
    NSUInteger walk = sg_walk;
    NSString *title = sg_title;
    SGMotionPoster(file, ^(UIImage *poster) {
        if (!poster || poster.size.height <= 0 || walk != sg_walk) return;
        CGFloat ratio;
        NSString *key = keyFor(poster.size, &ratio);
        if (!key) {
            SGLog(@"lock motion: the system lists no key yet (%@)", MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys);
            return;
        }
        BOOL fits = fabs(poster.size.width / poster.size.height - ratio) <= kSameShape;
        NSURL *shaped = fits ? file : SGMotionMadeFile([NSString stringWithFormat:@"cut\n%@\n%g", file.lastPathComponent, ratio]);
        MPMediaItemAnimatedArtwork *artwork = [[MPMediaItemAnimatedArtwork alloc] initWithArtworkID:shaped.lastPathComponent
            previewImageRequestHandler:^(CGSize wanted, void (^completion)(UIImage *)) { completion(filled(poster, wanted)); }
            videoAssetFileURLRequestHandler:^(CGSize wanted, void (^completion)(NSURL *)) {
                if (fits) {
                    completion(file);
                    return;
                }
                dispatch_async(sg_queue, ^{
                    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
                    BOOL ok = [NSFileManager.defaultManager fileExistsAtPath:shaped.path] || SGMotionClipShape(file, ratio, shaped);
                    SGLog(@"lock motion: %@ cut to %@ %@ in %.0f ms", file.lastPathComponent, ratio == 1 ? @"1:1" : @"3:4",
                          ok ? @"ready" : @"not written", (CFAbsoluteTimeGetCurrent() - start) * 1000);
                    completion(ok ? shaped : nil);
                });
            }];
        SGNowPlayingSetExtras(@"motion", @{key: artwork}, title);
        SGLog(@"lock motion: %@, %.0fx%.0f, as %@%@", file.lastPathComponent, poster.size.width, poster.size.height,
              ratio == 1 ? @"1:1" : @"3:4", fits ? @"" : @", cut to fit");
    });
}

// Under Moving artwork with lyrics: the clip found for the track, and whether LyricsArtwork.x asked for it
// plain (the track has no synced lines) and it shows so.
static NSURL *sg_lyricsFile;
static BOOL sg_plain, sg_plainShown;

void SGLockMotionShowPlain(BOOL plain) {
    if (@available(iOS 26.0, *)) {
        sg_plain = plain;
        BOOL want = plain && sg_choice == SGLockArtworkMotionLyrics && sg_lyricsFile;
        if (want == sg_plainShown) return;
        sg_plainShown = want;
        if (want) show(sg_lyricsFile);
        else SGNowPlayingSetExtras(@"motion", nil, nil);
        SGLog(@"lock motion: %@", want ? [NSString stringWithFormat:@"%@ shown plain, the track has no synced lines", sg_lyricsFile.lastPathComponent]
                                       : @"the plain clip taken off for the lyrics");
    }
}

// The cover Spotify handed the system for `title`, read on the main thread as LyricsArtwork.x reads it,
// then `then` on sg_queue with it, or with NULL when the info is another song's or has none.
static void withCover(NSString *title, void (^then)(CGImageRef cover)) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSDictionary *info = MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo;
        MPMediaItemArtwork *artwork = info[MPMediaItemPropertyArtwork];
        UIImage *cover = [info[MPMediaItemPropertyTitle] isEqual:title] && [artwork isKindOfClass:MPMediaItemArtwork.class]
            ? [artwork imageWithSize:CGSizeMake(600, 600)] : nil;
        dispatch_async(sg_queue, ^{ then(cover.CGImage); });
    });
}

// The picture the track names, so the songs of an album share a clip; the track itself when it names none.
static NSString *pictureOf(SPTPlayerTrack *track, NSDictionary *metadata) {
    for (NSString *field in @[@"image_xlarge_url", @"image_large_url", @"image_url"]) {
        id value = metadata[field];
        if ([value isKindOfClass:NSString.class] && [value length]) return value;
    }
    return SGURIString(track.URI);
}

// The cover's clip is 3:4 (SGLyricsClipSize), so it goes only where the system lists that key.
API_AVAILABLE(ios(26.0))
static void showCover(NSString *picture) {
    if (![MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys containsObject:MPNowPlayingInfoProperty3x4AnimatedArtwork]) return;
    NSURL *file = SGMotionMadeFile([@"fluid\n" stringByAppendingString:picture]);
    NSString *title = sg_title;
    CGSize size = SGLyricsClipSize(SGMotionPixels());
    MPMediaItemAnimatedArtwork *artwork = [[MPMediaItemAnimatedArtwork alloc] initWithArtworkID:file.lastPathComponent
        previewImageRequestHandler:^(CGSize wanted, void (^completion)(UIImage *)) {
            withCover(title, ^(CGImageRef cover) {
                CGImageRef frame = SGFluidClipFrame(cover, size);
                completion(frame ? filled([UIImage imageWithCGImage:frame], wanted) : nil);
                CGImageRelease(frame);
            });
        }
        videoAssetFileURLRequestHandler:^(CGSize wanted, void (^completion)(NSURL *)) {
            withCover(title, ^(CGImageRef cover) {
                CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
                BOOL ok = [NSFileManager.defaultManager fileExistsAtPath:file.path] || SGFluidClipWrite(file, cover, size);
                SGLog(@"lock motion: the cover's clip %@ %@ in %.0f ms", file.lastPathComponent, ok ? @"ready" : @"not written",
                      (CFAbsoluteTimeGetCurrent() - start) * 1000);
                completion(ok ? file : nil);
            });
        }];
    SGNowPlayingSetExtras(@"motion", @{MPNowPlayingInfoProperty3x4AnimatedArtwork: artwork}, title);
    SGLog(@"lock motion: no moving artwork, the cover's clip offered as %@", file.lastPathComponent);
}

// The cover filled edge to edge, for a track with no moving artwork while Full-screen cover is on.
API_AVAILABLE(ios(26.0))
static void showFullCover(NSString *picture) {
    if (![MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys containsObject:MPNowPlayingInfoProperty3x4AnimatedArtwork]) return;
    NSURL *file = SGMotionMadeFile([@"still\n" stringByAppendingString:picture]);
    NSString *title = sg_title;
    CGSize size = SGLyricsClipSize(SGMotionPixels());
    MPMediaItemAnimatedArtwork *artwork = [[MPMediaItemAnimatedArtwork alloc] initWithArtworkID:file.lastPathComponent
        previewImageRequestHandler:^(CGSize wanted, void (^completion)(UIImage *)) {
            withCover(title, ^(CGImageRef cover) {
                CGImageRef frame = SGCoverClipFrame(cover, size);
                completion(frame ? filled([UIImage imageWithCGImage:frame], wanted) : nil);
                CGImageRelease(frame);
            });
        }
        videoAssetFileURLRequestHandler:^(CGSize wanted, void (^completion)(NSURL *)) {
            withCover(title, ^(CGImageRef cover) {
                BOOL ok = [NSFileManager.defaultManager fileExistsAtPath:file.path] || SGCoverClipWrite(file, cover, size);
                SGLog(@"lock motion: the full-screen cover %@ %@", file.lastPathComponent, ok ? @"ready" : @"not written");
                completion(ok ? file : nil);
            });
        }];
    SGNowPlayingSetExtras(@"motion", @{MPNowPlayingInfoProperty3x4AnimatedArtwork: artwork}, title);
    SGLog(@"lock motion: no moving artwork, the full-screen cover offered as %@", file.lastPathComponent);
}

%ctor {
    if (@available(iOS 26.0, *)) {
        sg_choice = SGLockScreenArtwork();
        sg_queue = dispatch_queue_create("spotifyglass.lockscreen.motion", DISPATCH_QUEUE_SERIAL);
        // Each walk takes the last one's clip off first, so the lock screen falls back to the still cover.
        sg_follower = [[SGMotionFollower alloc] initWithBegin:^BOOL(NSString *uri, SPTPlayerState *state) {
            sg_walk++;
            SGNowPlayingSetExtras(@"motion", nil, nil);
            sg_lyricsFile = nil;
            sg_plainShown = NO;
            NSDictionary *metadata = [state.track.metadata isKindOfClass:NSDictionary.class] ? state.track.metadata : nil;
            sg_title = state.track.trackTitle;
            sg_picture = pictureOf(state.track, metadata);
            sg_choice = SGLockScreenArtwork();
            // Full-screen cover covers the choices that show artwork at all, so it walks for the clip first.
            return motionOn(sg_choice) || fullCoverOn(sg_choice);
        } found:^(NSString *uri, NSURL *file) {
            // Under the lyrics instead, and never as this file's extra too: both would fill the same 3:4 key.
            if (sg_choice == SGLockArtworkMotionLyrics) {
                if (file) SGLyricsArtworkSetMotion(uri, file);
                // A track with no synced lines shows it plain, as Moving artwork would; LyricsArtwork.x says which.
                sg_lyricsFile = file;
                SGLockMotionShowPlain(sg_plain);
                SGLog(@"lock motion: %@ for the lyrics of %@", file ? file.lastPathComponent : @"no clip", uri);
            } else if (file && motionOn(sg_choice)) {
                show(file);
            } else if (fullCoverOn(sg_choice)) {
                // Moving artwork under the choices that do not show it is not shown: the cover is.
                showFullCover(sg_picture);
            } else if (!file && sg_choice == SGLockArtworkEverySong) {
                showCover(sg_picture);
            }
        }];
        // Heard on the writing thread and handed to main without waiting: a main-queue observer makes every
        // background defaults write wait for main, which deadlocks launch while main waits on Spotify's CoreThread.
        [NSNotificationCenter.defaultCenter addObserverForName:NSUserDefaultsDidChangeNotification object:nil queue:nil
                                                    usingBlock:^(NSNotification *note) {
            SGPrefsChanged();
            dispatch_async(dispatch_get_main_queue(), ^{
                SGLockArtwork choice = SGLockScreenArtwork();
                if (choice == sg_choice) return;
                SGLog(@"lock motion: the choice changed to %ld, the playing track looked up again", (long)choice);
                sg_choice = choice;
                [sg_follower restart];
            });
        }];
        SGLog(@"lock motion: %@, the lock screen takes %@", motionOn(sg_choice) ? (sg_choice == SGLockArtworkEverySong ? @"on for every song" : @"on") : @"off",
              MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys);
    }
}
