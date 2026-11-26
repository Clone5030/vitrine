// The surface Vitrine's Downloads page talks to. Vitrine's tweak (spotifyglass.dylib) never links this library:
// it finds SAPVitrineBridge with NSClassFromString, so a build without the companion (another Spotify version,
// no patched executable) simply has no class and the page says downloads are not available.
#import <Foundation/Foundation.h>
#import "DownloadCompatibility.h"
#import "Diagnostics.h"
#import "NativeOffline.h"
#import "OfflineConfig.h"
#import "OfflineDevices.h"
#import "OfflineFlags.h"
#import "TrackDownload.h"
#import "TrackJournal.h"

__attribute__((visibility("default")))
@interface SAPVitrineBridge : NSObject
+ (NSInteger)interfaceVersion;
+ (NSDictionary *)snapshot;
+ (NSString *)downloadSummary;
+ (BOOL)downloadActive;
+ (void)downloadTrack;
+ (void)downloadAlbum;
+ (void)checkTrack;
+ (void)cancelDownload;
+ (void)sendLog;
+ (void)refreshJournal;
+ (BOOL)diagnosticsEnabled;
+ (void)setDiagnosticsEnabled:(BOOL)enabled;
+ (NSString *)compatibilityText:(NSDictionary *)report;
+ (void)refreshCompatibility:(void (^)(NSDictionary *))completion;
+ (void)previewSlots:(void (^)(NSDictionary *, NSString *))completion;
+ (void)releaseSlots:(NSString *)planID cacheIDs:(NSArray *)cacheIDs completion:(void (^)(NSDictionary *, NSString *))completion;
+ (void)enableOffline:(void (^)(NSDictionary *, NSString *))completion;
+ (void)restoreKeyMode:(void (^)(BOOL, NSString *))completion;
+ (void)loadDetails:(BOOL)journal completion:(void (^)(NSDictionary *))completion;
@end

@implementation SAPVitrineBridge
+ (NSInteger)interfaceVersion { return 1; }
+ (NSDictionary *)snapshot { return @{@"download_active": @(SAPTrackDownloadActive()), @"key_request_mode": SAPKeyRequestModeReport()}; }
+ (NSString *)downloadSummary { return SAPTrackDownloadSummary(); }
+ (BOOL)downloadActive { return SAPTrackDownloadActive(); }
+ (void)downloadTrack { SAPDownloadCurrentTrack(nil); }
+ (void)downloadAlbum { SAPDownloadCurrentAlbum(nil); }
+ (void)checkTrack { SAPVerifyCurrentTrack(nil); }
+ (void)cancelDownload { SAPCancelTrackDownload(); }
+ (void)sendLog { SAPJournalNoteAction(@"send_log_requested", @{@"diagnostics_enabled": @(SAPDiagnosticsEnabled())}); }
+ (void)refreshJournal { SAPJournalRefresh(@"settings"); }
+ (BOOL)diagnosticsEnabled { return SAPDiagnosticsEnabled(); }
+ (void)setDiagnosticsEnabled:(BOOL)enabled {
    BOOL before = SAPDiagnosticsEnabled();
    SAPDiagnosticsSetEnabled(enabled);
    SAPJournalNoteAction(@"diagnostics_changed", @{@"before": @(before), @"after": @(SAPDiagnosticsEnabled())});
}
+ (NSString *)compatibilityText:(NSDictionary *)report { return SAPDownloadCompatibilityText(report); }
+ (void)refreshCompatibility:(void (^)(NSDictionary *))completion { SAPRefreshDownloadCompatibility(completion); }
+ (void)previewSlots:(void (^)(NSDictionary *, NSString *))completion { SAPPreviewOfflineDeviceSlots(completion); }
+ (void)releaseSlots:(NSString *)planID cacheIDs:(NSArray *)cacheIDs completion:(void (^)(NSDictionary *, NSString *))completion {
    SAPReleaseOfflineDeviceSlots(planID, cacheIDs, completion);
}
+ (void)enableOffline:(void (^)(NSDictionary *, NSString *))completion { SAPEnableOfflineOnCurrentDevice(completion); }
+ (void)restoreKeyMode:(void (^)(BOOL, NSString *))completion { SAPSetKeyRequestMode(0, completion); }
+ (void)loadDetails:(BOOL)journal completion:(void (^)(NSDictionary *))completion {
    if (completion) completion(@{@"journal_summary": journal && SAPDiagnosticsEnabled() ? SAPJournalSummaryText() : @"Diagnostics are off; download history is not kept."});
}
@end

// Install the Spotify hooks when the companion loads. Waiting until a user taps
// Download misses SPTOfflineManagerImplementation's initializer, which is what
// supplies the native manager wrapper used by playlist and track downloads.
__attribute__((constructor)) static void SAPVitrineDownloadsLoad(void) {
    @autoreleasepool {
        SAPDiagnosticsInitialize();
        SAPInstallOfflineFlags();
        SAPInstallOfflineConfig();
        SAPInstallNativeOffline();
        SAPInstallTrackDownloader();
    }
}
