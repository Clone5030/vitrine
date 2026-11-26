// Downloads (Mod Settings > Downloads), under either look: Spotify's own offline downloads, made to work.
//
//     DownloadsBridge.m    the one place that talks to the companion library (extension/Downloads), by runtime
//                          lookup: this tweak never links it, so a build without it just reports unavailable
//     DownloadsSettings.m  the page: a glass card for what is happening, the current track's actions, the
//                          quota and device checks, the download status and the diagnostics
//
// What makes Spotify's own download buttons work (the playlist and album buttons, the ⋯ menus, the Download
// toggle in Your Library) is not here but in the companion and three guarded edits to Spotify 9.1.90's
// executable, made at build time by scripts/pipeline.sh. This layer only shows and drives them.
// Threading: main thread only.
#import <UIKit/UIKit.h>

// Posted when the active state or the summary changes, so rows that show them reload.
extern NSNotificationName const SGDownloadsDidChangeNotification;

// Diagnostics, mirrored here so the page's switch has a key; the companion is the one that stores it.
#define SGKeyDownloadsDiagnostics @"spotifyglass.downloads.diagnostics"

// YES when this build carries the companion library (Spotify 9.1.90 only).
BOOL SGDownloadsAvailable(void);
// What the page's card says and what the Mod Settings row shows beside its chevron.
BOOL SGDownloadsActive(void);
NSString *SGDownloadsSummary(void);
NSString *SGDownloadsRowSummary(void);
NSString *SGDownloadsUnavailableReason(void);

UIViewController *SGDownloadsSettingsPage(void);
