#pragma once
#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, SAPSettingsAction) {
    SAPSettingsDownload, SAPSettingsVerify, SAPSettingsCancelDownload,
    SAPSettingsRefreshJournal, SAPSettingsExportJournal, SAPSettingsResetJournal,
    SAPSettingsMute, SAPSettingsToggleRecording, SAPSettingsExportWAV, SAPSettingsExportReport,
    SAPSettingsDownloadAlbum, SAPSettingsSendLog
};
// UI adapters; these call the existing v21 operations without altering them.
@interface SAPSettingsActions : NSObject
+ (NSDictionary *)snapshot;
+ (NSDictionary *)snapshotForDetails:(BOOL)journal;
+ (void)loadDetails:(BOOL)journal completion:(void (^)(NSDictionary *))completion;
+ (void)perform:(SAPSettingsAction)action;
+ (void)setKeyRequestMode:(NSInteger)mode completion:(void (^)(BOOL,NSString *))completion;
+ (void)refreshDownloadCompatibility:(void (^)(NSDictionary *))completion;
+ (void)previewOfflineDeviceSlots:(void (^)(NSDictionary *,NSString *))completion;
+ (void)releaseOfflineDeviceSlots:(NSString *)planID cacheIDs:(NSArray *)cacheIDs completion:(void (^)(NSDictionary *,NSString *))completion;
+ (void)enableOfflineOnCurrentDevice:(void (^)(NSDictionary *,NSString *))completion;
@end
