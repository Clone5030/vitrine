// A video of the person's own as a song's animated artwork, chosen in the player's ⋯ menu. It is made into a loop
// with no seam: the last second is blended into the first, so the clip ends on the frame it starts on, and kept as
// an H.264 file under the song's address (Application Support/spotifyglass/customart). SGMotionClipFor asks for it
// before any other source, so the player, the landscape screen and the lock screen all play it, and the song's
// walk is run again as it is set or taken off (SGCustomArtworkDidChangeNotification, which SGMotionFollower hears).
//
// Threading: Choose and Remove on the main thread; the loop is made on a queue of its own.
#import <UIKit/UIKit.h>

extern NSNotificationName const SGCustomArtworkDidChangeNotification;

// The clip made for the track, or nil. Any thread.
NSURL *SGCustomArtworkFor(NSString *uri);
void SGCustomArtworkRemove(NSString *uri);
// Opens the photo library for a video, makes its loop and keeps it for `uri`. `working` is called with YES as the
// making begins and NO as it ends, kept or not; a video that cannot be used is said so in an alert.
void SGCustomArtworkChoose(NSString *uri, void (^working)(BOOL working));
