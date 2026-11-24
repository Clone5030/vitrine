// Moving artwork for a track: its Canvas, or Apple Music's animated album cover where the album has one,
// and for the lock screen, failing both, the cover over a moving blur of itself (SGFluidClip.h).
// SGMotionCatalog.m looks covers and logos up in Apple Music's catalog. SGMotionStore.m keeps every video
// as a local file, the form the system's lock screen takes.
#import <UIKit/UIKit.h>

// What the lock screen fills the screen with, stored as the index of SGLockArtwork. It took over from the
// Moving artwork switch, whose key is moved onto it once: on is Moving artwork, off is Off.
#define SGKeyLockScreenArtwork @"spotifyglass.lockscreen.artwork"
#define SGKeyLockScreenMotion @"spotifyglass.lockscreen.motion"
typedef NS_ENUM(NSInteger, SGLockArtwork) {
    SGLockArtworkOff = 0,
    SGLockArtworkMotion,   // the Canvas, else Apple Music's animated cover (LockScreenMotion.x)
    SGLockArtworkLyrics,   // a clip per line of lyrics (Shared/LockScreenLyrics/LyricsArtwork.x)
    SGLockArtworkEverySong,   // Moving artwork, else the cover over a moving blur of it (LockScreenMotion.x)
    // The lyrics over the moving artwork, else Lyrics: LockScreenMotion.x finds the clip, LyricsArtwork.x
    // draws the lines over it.
    SGLockArtworkMotionLyrics,
};
// Off below iOS 26, which has no animated artwork on the lock screen.
SGLockArtwork SGLockScreenArtwork(void);
// Under Moving artwork with lyrics, LyricsArtwork.x says whether the playing track has no synced lines (YES), so
// LockScreenMotion.x shows its moving artwork plain, as Moving artwork does, or has them (NO), so it takes it off
// for the lyrics' clips. Main queue.
void SGLockMotionShowPlain(BOOL plain);
static inline BOOL SGLockArtworkShowsLyrics(SGLockArtwork artwork) {
    return artwork == SGLockArtworkLyrics || artwork == SGLockArtworkMotionLyrics;
}
// How the lyrics are drawn, stored as the index of SGLyricsClipStyle (Still unless changed).
#define SGKeyLockScreenLyricsStyle @"spotifyglass.lockscreen.lyricsStyle"
// Off until switched on: the lock screen widget's star switches the choice between a choice with lyrics and
// one without (LockScreenStar.x), and takes the place of Spotify's like and dislike buttons. StarBack is the
// choice the star left, to go back to.
#define SGKeyLockScreenStar @"spotifyglass.lockscreen.star"
#define SGKeyLockScreenStarBack @"spotifyglass.lockscreen.star.back"
// Off until switched on: download in Low Data Mode too.
#define SGKeyMotionLowData @"spotifyglass.motion.lowdata"
// Off until switched on: a track with no moving artwork shows its cover over the whole player and the whole lock
// screen's artwork, instead of square over the field (PlayerMotion.x, LockScreenMotion.x).
#define SGKeyMotionFullCover @"spotifyglass.motion.fullcover"

typedef NS_ENUM(NSInteger, SGMotionShape) {
    SGMotionSquare,   // 1:1
    SGMotionTall,     // 3:4
};

// Apple Music's animated cover for an album, as a local file, or nil. `done` runs on the main queue.
// `pixels` is the width it is shown at; the closest stream at or above it is downloaded.
void SGMotionAlbumCover(NSString *artist, NSString *album, SGMotionShape shape, CGFloat pixels,
                        void (^done)(NSURL *file));

// The artist's logo from Apple Music, a transparent PNG `pixels` wide, or nil. Main queue.
void SGMotionArtistLogo(NSString *artist, CGFloat pixels, void (^done)(UIImage *logo));

// The width a full-screen clip is downloaded at: three quarters of the screen's pixels. A tall cover at the
// screen's full width ran to 29 MB a song; at this width it was 7 MB and looks the same in motion.
CGFloat SGMotionPixels(void);

// Apple Music's catalog songs with this ISRC, each with its isrc, durationInMillis and hasHaptics, or nil
// when the catalog could not be asked. Kept for the launch. Main queue.
void SGMotionSongsWithISRC(NSString *isrc, void (^done)(NSArray *songs));

// Where moving artwork comes from (MotionSources.m): the keys that are on, in the order they are asked,
// Spotify's Canvas then Apple Music's animated cover unless the user changed it.
#define SGKeyMotionSources @"spotifyglass.motion.sources"
NSArray<NSString *> *SGMotionSourceOrder(void);
BOOL SGMotionAppleMusicOn(void);
// The track's Canvas video as its metadata names it (canvas.url, of a canvas.type that is a video), or nil.
NSURL *SGMotionCanvasIn(NSDictionary *metadata);
// The first clip the order finds for the track `uri`, as a local file, or nil, and the key of the source it
// came from. `canvas` is the track's Canvas video, nil when its metadata names none, and then Spotify's
// Canvas service is asked for it. Main queue.
void SGMotionClipFor(NSString *uri, NSURL *canvas, NSString *artist, NSString *album, SGMotionShape shape, CGFloat pixels,
                     void (^done)(NSURL *file, NSString *source));

// Follows the player for one user of moving artwork, the lock screen or the redesign's player
// (SGMotionFollower.m). Each track's sources are walked once, and again when its Canvas turns up in a later
// state, as it does on a skip, where Spotify reports the track before its extended metadata, unless the clip
// showing came from a source above Canvas. `begin` runs as a walk starts, to take the last clip off, and
// says whether to walk at all; `found` gets the walk's clip, nil for none, and never runs for a walk a newer
// one overtook. Once a walk has ended, the next track's clip is fetched ahead. Main queue.
@class SPTPlayerState;
@interface SGMotionFollower : NSObject
- (instancetype)initWithBegin:(BOOL (^)(NSString *uri, SPTPlayerState *state))begin
                        found:(void (^)(NSString *uri, NSURL *file))found;
// The track is walked again from the player's last state: a setting it depends on changed.
- (void)restart;
@end
// The row that opens the ordered list, for the Player page and the lock screen's.
@class SGModRow;
SGModRow *SGMotionSourcesRow(void);

// Any remote video (a Canvas) as a local file, or nil. Main queue.
void SGMotionFile(NSURL *remote, void (^done)(NSURL *file));
// Where a video the mod makes itself is kept under `key`, among the downloads, which are kept to the
// newest few. Whether it is there yet is the caller's to check. Any thread.
NSURL *SGMotionMadeFile(NSString *key);

// The first frame of a local video. Main queue.
void SGMotionPoster(NSURL *file, void (^done)(UIImage *poster));

// Settings: what the lock screen shows, the lyrics' style and Low Data Mode; below iOS 26 the one row
// SGLockScreenArtworkNeedsRow, which says the setting needs iOS 26 and, tapped, why.
NSArray *SGLockScreenMotionRows(void);
SGModRow *SGLockScreenArtworkNeedsRow(void);

// Pure steps, for the harness.
NSString *SGMotionNameKey(NSString *name);
NSString *SGMotionSearchName(NSString *name);
NSString *SGMotionStreamIn(NSString *master, CGFloat pixels);
NSString *SGMotionWholeFileIn(NSString *media);
