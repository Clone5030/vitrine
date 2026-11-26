#pragma once
#import <Foundation/Foundation.h>
void SAPInstallTrackDownloader(void);
void SAPDownloadCurrentTrack(void (^message)(NSString *));
void SAPDownloadCurrentAlbum(void (^message)(NSString *));
void SAPCancelTrackDownload(void);
void SAPVerifyCurrentTrack(void (^message)(NSString *));
BOOL SAPTrackDownloadActive(void);
NSString *SAPTrackDownloadSummary(void);
NSDictionary *SAPTrackDownloadReport(void);
NSDictionary *SAPTrackDownloadReportWithJournal(NSDictionary *journalReport);
// Uses Spotify's already authenticated in-process transport. The payload is
// read-only and the callback is delivered on the main queue.
void SAPCallReadOnlyService(NSString *serviceName, NSString *method, NSData *payload,
                            void (^completion)(NSData *response, NSString *error));
// Explicit user command. One verified endpoint, one send, no replay on timeout.
void SAPCallOfflineCommandOnce(NSString *method,NSData *payload,void (^completion)(NSData *,NSString *));
