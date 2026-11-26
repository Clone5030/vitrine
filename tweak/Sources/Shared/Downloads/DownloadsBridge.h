// What the companion library (extension/Downloads/src/TaurusBridge.m) answers to. Found at runtime, never linked.
#import <Foundation/Foundation.h>

@protocol SGDownloadsCompanion <NSObject>
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

// nil when this build has no companion.
Class<SGDownloadsCompanion> SGDownloadsCompanion(void);
