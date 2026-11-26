#import "Localization.h"
#import "SupportLog.h"
#import "DownloadCompatibility.h"
#import "OfflineDevices.h"
#import <UIKit/UIKit.h>
#import <AVFAudio/AVFAudio.h>
#import <dlfcn.h>
#import "AudioProbe.h"
#import "SourceGraph.h"
#import "OfflineFlags.h"
#import "TrackDownload.h"
#import "OfflineConfig.h"
#import "NativeOffline.h"
#import "TrackJournal.h"
#import "AudioProbeUI.h"
#import "Features.h"
#import "Diagnostics.h"
#import "DiagnosticTrace.h"
#import "TracePlatform.h"
#import "NativeKeyTrace.h"
#import "PlayerTrace.h"
#import "NativeErrorLog.h"

static NSURL *SAPDocuments(void) {
    return [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
}

static UIViewController *SAPTopController(void) {
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows)
            if (candidate.isKeyWindow && candidate.windowLevel == UIWindowLevelNormal) window = candidate;
    }
    UIViewController *controller = window.rootViewController;
    while (controller) {
        if (controller.presentedViewController && !controller.presentedViewController.isBeingDismissed) controller = controller.presentedViewController;
        else if ([controller isKindOfClass:UINavigationController.class]) controller = ((UINavigationController *)controller).visibleViewController;
        else if ([controller isKindOfClass:UITabBarController.class]) controller = ((UITabBarController *)controller).selectedViewController;
        else break;
    }
    return controller;
}

static void SAPPresent(UIViewController *modal) {
    UIViewController *host = SAPTopController();
    id<UIViewControllerTransitionCoordinator> transition = host.transitionCoordinator;
    if (transition) {
        BOOL registered = [transition animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
            dispatch_async(dispatch_get_main_queue(), ^{ SAPPresent(modal); });
        }];
        if (registered) return;
    }
    [host presentViewController:modal animated:YES completion:nil];
}

static void SAPMessage(NSString *message) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:SAPL(@"Менеджер загрузок",@"Downloads") message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action){[NSNotificationCenter.defaultCenter postNotificationName:@"SAPDownloadSettingsChanged" object:nil];}]];
    SAPPresent(alert);
}

static __weak UIAlertController *SAPDownloadAlert;
static void SAPDownloadMessage(NSString *message) {
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    UIAlertController *current = SAPDownloadAlert;
    if (current && !current.isBeingDismissed) { current.message = message; return; }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:SAPL(@"Скачать текущий трек",@"Download current track") message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action){[NSNotificationCenter.defaultCenter postNotificationName:@"SAPDownloadSettingsChanged" object:nil];}]];
    SAPDownloadAlert = alert;
    SAPPresent(alert);
}

static void SAPShareItems(NSArray *items) {
    if (!items.count) return;
    UIViewController *controller = SAPTopController();
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:items applicationActivities:nil];
    share.popoverPresentationController.sourceView = controller.view;
    share.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(controller.view.bounds), CGRectGetMidY(controller.view.bounds), 1, 1);
    SAPPresent(share);
}

static void SAPShare(NSURL *url) {
    if (!url) return;
    UIViewController *controller = SAPTopController();
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    share.popoverPresentationController.sourceView = controller.view;
    share.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(controller.view.bounds), CGRectGetMidY(controller.view.bounds), 1, 1);
    SAPPresent(share);
}

#if SAP_ENABLE_WAV_CAPTURE
static void put16(uint8_t *p, uint16_t value) { p[0] = value; p[1] = value >> 8; }
static void put32(uint8_t *p, uint32_t value) { for (unsigned i = 0; i < 4; ++i) p[i] = value >> (i * 8); }

@interface SAPRecorder : NSObject {
    dispatch_queue_t _writer;
    dispatch_source_t _timer;
    FILE *_file;
    uint64_t _bytes;
    SAPCaptureFormat _format;
    BOOL _writeFailed;
}
@property(nonatomic) BOOL recording; // Main thread only.
@property(nonatomic, strong) NSURL *lastFile;
+ (instancetype)shared;
- (void)start;
- (void)stopAndShare;
@end

@implementation SAPRecorder
+ (instancetype)shared {
    static SAPRecorder *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [SAPRecorder new]; instance->_writer = dispatch_queue_create("SpotifyAudioProbe.wav-writer", DISPATCH_QUEUE_SERIAL); });
    return instance;
}

- (void)writeHeader {
    // IEEE Float32 WAV with a fact chunk, preserving decoded sample precision.
    uint8_t header[56] = {0};
    memcpy(header, "RIFF", 4); put32(header + 4, (uint32_t)_bytes + 48);
    memcpy(header + 8, "WAVEfmt ", 8); put32(header + 16, 16);
    put16(header + 20, 3); put16(header + 22, (uint16_t)_format.channels);
    put32(header + 24, (uint32_t)_format.sampleRate);
    put32(header + 28, (uint32_t)_format.sampleRate * _format.channels * 4);
    put16(header + 32, (uint16_t)(_format.channels * 4)); put16(header + 34, 32);
    memcpy(header + 36, "fact", 4); put32(header + 40, 4);
    put32(header + 44, _format.channels ? (uint32_t)(_bytes / (_format.channels * 4)) : 0);
    memcpy(header + 48, "data", 4); put32(header + 52, (uint32_t)_bytes);
    if (fseek(_file, 0, SEEK_SET) != 0 || fwrite(header, 1, sizeof(header), _file) != sizeof(header)) _writeFailed = YES;
}

- (void)drain {
    if (!_file || _writeFailed) return;
    uint8_t buffer[65536];
    size_t count;
    while ((count = SpotifyAudioProbeReadCapture(buffer, sizeof(buffer))) > 0) {
        if (_bytes + count > UINT32_MAX - 48) { _writeFailed = YES; break; }
        size_t written = fwrite(buffer, 1, count, _file);
        _bytes += written;
        if (written != count) { _writeFailed = YES; break; }
    }
    if (_writeFailed) SpotifyAudioProbeEndCapture();
}

- (void)start {
    if (self.recording) return;
    self.recording = YES;
    dispatch_async(_writer, ^{
        self->_bytes = 0; self->_writeFailed = NO;
        NSURL *directory = [SAPDocuments() URLByAppendingPathComponent:@"AudioProbe" isDirectory:YES];
        [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *name = [NSString stringWithFormat:@"Spotify-%@.wav", NSUUID.UUID.UUIDString];
        NSURL *url = [directory URLByAppendingPathComponent:name];
        self->_file = fopen(url.fileSystemRepresentation, "wb");
        // Reserve the header before enabling capture; the consumer is ready.
        uint8_t padding[56] = {0};
        BOOL reserved = self->_file && fwrite(padding, 1, sizeof(padding), self->_file) == sizeof(padding);
        if (!reserved || !SpotifyAudioProbeBeginCapture(&self->_format)) {
            if (self->_file) fclose(self->_file);
            self->_file = NULL;
            [NSFileManager.defaultManager removeItemAtURL:url error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.recording = NO;
                SAPMessage(SAPL(@"Запись не началась: нет активного поддерживаемого PCM-потока или не удалось создать файл. Запусти воспроизведение на этом iPhone, затем повтори.",@"Recording could not start: no active supported PCM stream, or the file could not be created. Start playback on this iPhone and try again."));
            });
            return;
        }
        self->_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self->_writer);
        dispatch_source_set_timer(self->_timer, dispatch_time(DISPATCH_TIME_NOW, 0), 50 * NSEC_PER_MSEC, 10 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(self->_timer, ^{ [self drain]; });
        dispatch_resume(self->_timer);
        dispatch_async(dispatch_get_main_queue(), ^{ self.lastFile = url; SAPMessage(SAPL(@"Запись WAV началась. Для завершения открой «Менеджер загрузок Pixie» → «Остановить запись и экспортировать».",@"WAV recording started. To finish, open Pixie Download Manager → Stop recording and export.")); });
    });
}

- (void)stopAndShare {
    if (!self.recording) return;
    self.recording = NO;
    dispatch_async(_writer, ^{
        if (self->_timer) { dispatch_source_cancel(self->_timer); self->_timer = nil; }
        SpotifyAudioProbeEndCapture();
        [self drain];
        if (self->_file) { [self writeHeader]; fclose(self->_file); self->_file = NULL; }
        uint64_t dropped = SpotifyAudioProbeDroppedCaptureFrames();
        BOOL changed = SpotifyAudioProbeCaptureFormatChanged();
        BOOL failed = self->_writeFailed;
        uint64_t bytes = self->_bytes;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (failed || dropped || changed || !bytes) {
                SAPMessage([NSString stringWithFormat:SAPL(@"Файл сохранён. PCM: %llu байт. Пропущено: %llu кадров. Изменение формата: %@. Ошибка записи: %@. Файл доступен через «Экспорт последнего WAV».",@"File saved. PCM: %llu bytes. Dropped: %llu frames. Format changed: %@. Write error: %@. Use Export last WAV to access the file."), (unsigned long long)bytes, (unsigned long long)dropped, changed ? SAPL(@"да",@"yes") : SAPL(@"нет",@"no"), failed ? SAPL(@"да",@"yes") : SAPL(@"нет",@"no")]);
            } else SAPShare(self.lastFile);
        });
    });
}
@end

#endif

static BOOL SAPRecording(void) {
#if SAP_ENABLE_WAV_CAPTURE
    return SAPRecorder.shared.recording;
#else
    return NO;
#endif
}
static BOOL SAPLastWAVAvailable(void) {
#if SAP_ENABLE_WAV_CAPTURE
    return SAPRecorder.shared.lastFile!=nil;
#else
    return NO;
#endif
}

static NSString *fourcc(uint32_t value) {
    char text[5] = {(char)(value >> 24), (char)(value >> 16), (char)(value >> 8), (char)value, 0};
    for (unsigned i = 0; i < 4; ++i) if (text[i] < 32 || text[i] > 126) text[i] = '?';
    return [NSString stringWithUTF8String:text];
}

static NSDictionary *SAPLocationReport(const SAPCodeLocation *location) {
    return @{@"address": [NSString stringWithFormat:@"0x%llx", (unsigned long long)location->address],
        @"image_base": [NSString stringWithFormat:@"0x%llx", (unsigned long long)location->imageBase],
        @"preferred_address": [NSString stringWithFormat:@"0x%llx", (unsigned long long)location->preferredAddress],
        @"image": [NSString stringWithUTF8String:location->image] ?: @"",
        @"symbol": [NSString stringWithUTF8String:location->symbol] ?: @""};
}
static NSDictionary *SAPSourceReport(void) {
    SAPSourceGraph graph; SAPReadSourceGraph(&graph);
    NSMutableArray *methods = [NSMutableArray arrayWithCapacity:8];
    for (unsigned i = 0; i < 8; ++i) [methods addObject:SAPLocationReport(&graph.methods[i])];
    return @{@"status": @(graph.status), @"callback": SAPLocationReport(&graph.callback),
        @"owner": [NSString stringWithFormat:@"0x%llx", (unsigned long long)graph.owner],
        @"source": [NSString stringWithFormat:@"0x%llx", (unsigned long long)graph.source],
        @"vtable": [NSString stringWithFormat:@"0x%llx", (unsigned long long)graph.vtable],
        @"methods": methods};
}

// В общий отчёт идёт компактная версия журнала: подробности лежат в своих файлах.
static NSDictionary *SAPJournalCompact(NSDictionary *report,NSString *currentURI) {
    NSMutableDictionary *value = [report mutableCopy];
    NSArray *tracks=value[@"tracks"];
    NSMutableArray *samples=[NSMutableArray array];
    NSString *current=value[@"focused_uri"];
    if(!current.length)current=currentURI;
    for(NSDictionary *track in tracks)
        if([track[@"uri"] isEqual:current]) {[samples addObject:track];break;}
    for(NSDictionary *track in tracks) {
        if(samples.count>=16)break;
        if(![samples containsObject:track] && ([track[@"state"] isEqual:@"error"] ||
            (track[@"ui_downloaded_matches_wire"] && ![track[@"ui_downloaded_matches_wire"] boolValue]))) [samples addObject:track];
    }
    value[@"comparison_samples"]=samples;
    for (NSString *key in @[@"tracks", @"recent_transitions", @"total_progress_samples", @"note"]) [value removeObjectForKey:key];
    return value;
}

static dispatch_queue_t SAPReportQueue(void) {
    static dispatch_queue_t queue;static dispatch_once_t once;
    dispatch_once(&once,^{queue=dispatch_queue_create("SpotifyAudioProbe.reports",dispatch_queue_attr_make_with_autorelease_frequency(DISPATCH_QUEUE_SERIAL,DISPATCH_AUTORELEASE_FREQUENCY_WORK_ITEM));});return queue;
}
static NSDictionary *SAPCompleteDiagnosticSnapshotWithJournal(NSDictionary *native,NSDictionary *journal) {
    NSDictionary *download=SAPTrackDownloadReportWithJournal(journal);
    NSMutableDictionary *report=[native[@"report"] mutableCopy];
    report[@"track_download"]=download;report[@"track_journal"]=SAPJournalCompact(journal,download[@"track_uri"]);
    NSMutableDictionary *result=[native mutableCopy];result[@"report"]=report;result[@"journal_summary"]=download[@"journal_summary"];return result;
}
static NSDictionary *SAPCompleteDiagnosticSnapshot(NSDictionary *native) {
    return SAPCompleteDiagnosticSnapshotWithJournal(native,SAPJournalReport());
}

@implementation SAPSettingsActions
+ (NSDictionary *)snapshot {
    return @{@"diagnostics_enabled":@(SAPDiagnosticsEnabled()),
        @"diagnostics":SAPL(@"Диагностика выключена. Включи переключатель «Диагностика» для сбора данных.",@"Diagnostics are off. Enable Diagnostics to collect data."),
        @"journal_summary":SAPL(@"Диагностика выключена. Журнал не обновляется. Проверка текущего трека доступна отдельно.",@"Diagnostics are off. The log is not updated. You can still check the current track separately."),
        @"download_active":@(SAPTrackDownloadActive()),@"key_request_mode":SAPKeyRequestModeReport(),@"recording":@(SAPRecording()),
        @"last_wav_available":@(SAPLastWAVAvailable())};
}
+ (NSDictionary *)snapshotForDetails:(BOOL)journal {
    if(!SAPDiagnosticsEnabled())return [self snapshot];
    if(!journal)return SAPCompleteDiagnosticSnapshot([self diagnosticSnapshot]);
    NSMutableDictionary *value=[[self snapshot]mutableCopy];value[@"journal_summary"]=SAPJournalSummaryText();return value;
}
+ (void)loadDetails:(BOOL)journal completion:(void (^)(NSDictionary *))completion {
    if(!SAPDiagnosticsEnabled()){if(completion)completion([self snapshot]);return;}
    // Native/UI objects are read on the calling main thread; only immutable
    // values and the journal's own snapshot cross to the report queue.
    NSDictionary *native=journal?[self snapshot]:[self diagnosticSnapshot];
    dispatch_async(SAPReportQueue(),^{
        NSDictionary *value;
        if(journal){NSMutableDictionary *copy=[native mutableCopy];copy[@"journal_summary"]=SAPJournalSummaryForReport(SAPJournalReport());value=copy;}
        else value=SAPCompleteDiagnosticSnapshot(native);
        dispatch_async(dispatch_get_main_queue(),^{if(completion)completion(value);});
    });
}
+ (NSDictionary *)diagnosticSnapshot {
    SAPSnapshot s; SpotifyAudioProbeReadSnapshot(&s);
    NSString *source = [NSString stringWithUTF8String:s.callbackImage] ?: @"";
    NSArray *ports = [AVAudioSession.sharedInstance.currentRoute.outputs valueForKey:@"portName"];
    NSString *route = [ports componentsJoinedByString:@", "];
    NSDictionary *report = @{
        @"probe_version": @26,@"pixie_build":@"9.1.90-v1.2",@"wav_capture_supported":@(SAP_ENABLE_WAV_CAPTURE),@"diagnostics_enabled":@(SAPDiagnosticsEnabled()), @"backend_ready": @(s.backendReady), @"pcm_confirmed": @(s.pcmConfirmed),
        @"au_set_calls": @(s.setPropertyCalls), @"au_callback_attempts": @(s.callbackAttempts),
        @"au_last_scope": @(s.lastCallbackScope), @"au_last_type": fourcc(s.lastComponentType),
        @"au_last_element": @(s.lastCallbackElement), @"au_last_subtype": fourcc(s.lastComponentSubtype),
        @"au_last_status": @(s.lastSetStatus), @"objc_hooks": @(s.objcHooks),
        @"sample_buffer_calls": @(s.sampleBufferCalls), @"player_buffer_calls": @(s.playerBufferCalls),
        @"compressed_buffers": @(s.compressedBuffers), @"extraction_errors": @(s.extractionErrors),
        @"last_sample_format": fourcc(s.lastSampleFormat),
        @"registrations": @(s.registrations), @"output_starts": @(s.outputStarts), @"callbacks": @(s.callbacks),
        @"frames": @(s.frames), @"pcm_bytes": @(s.pcmBytes), @"nonzero_callbacks": @(s.nonzeroCallbacks),
        @"muted_callbacks": @(s.mutedCallbacks), @"callback_errors": @(s.callbackErrors),
        @"sample_rate": @(s.sampleRate), @"channels": @(s.channels), @"format": fourcc(s.formatID),
        @"format_flags": @(s.formatFlags), @"bits_per_channel": @(s.bitsPerChannel),
        @"source_image": source, @"source_callback": [NSString stringWithFormat:@"0x%llx", (unsigned long long)s.procAddress],
        @"unit": [NSString stringWithFormat:@"0x%llx", (unsigned long long)s.unitAddress],
        @"track_source": SAPSourceReport(), @"offline_flags": SAPOfflineFlagsReport(), @"offline_config": SAPOfflineConfigReport() ,
        @"key_request_mode":SAPKeyRequestModeReport(),@"compatibility_check":SAPDownloadCompatibilityReport(),
        @"trace_coverage":SAPTraceReport(),@"native_key_trace":SAPNativeKeyTraceReport(),
        @"route": route ?: @"", @"pool_exhausted": @(s.poolExhausted), @"retired": @(s.retired),
        @"last_callback_age_seconds": @(s.lastCallbackAgeSeconds)
    };
    NSString *message = [NSString stringWithFormat:SAPL(@"%@\nCallback: %llu · Кадров: %llu\nPCM: %llu байт · Ненулевых блоков: %llu\n%.0f Hz · %u ch · %u bit · %@\nИсточник: %@\nВыход: %@\nЗаглушённых блоков: %llu%@",@"%@\nCallbacks: %llu · Frames: %llu\nPCM: %llu bytes · Nonzero buffers: %llu\n%.0f Hz · %u ch · %u bit · %@\nSource: %@\nOutput: %@\nMuted buffers: %llu%@"),
        [NSString stringWithFormat:SAPL(@"v26 · %@ · Хуков AV: %u\nAU вызовов: %u · Запусков: %u\nКолбэки: %u → %u · %@\nSampleBuffer: %llu · PlayerNode: %llu\nСжатых: %llu (%@) · Ошибок: %llu\n%@",@"v26 · %@ · AV hooks: %u\nAU calls: %u · Starts: %u\nCallbacks: %u → %u · %@\nSampleBuffer: %llu · PlayerNode: %llu\nCompressed: %llu (%@) · Errors: %llu\n%@"),
            s.backendReady ? SAPL(@"библиотека готова",@"library ready") : SAPL(@"ошибка AudioToolbox",@"AudioToolbox error"), s.objcHooks,
            s.setPropertyCalls, s.outputStarts, s.callbackAttempts, s.registrations, fourcc(s.lastComponentType),
            (unsigned long long)s.sampleBufferCalls,
            (unsigned long long)s.playerBufferCalls, (unsigned long long)s.compressedBuffers,
            fourcc(s.lastSampleFormat), (unsigned long long)s.extractionErrors,
            s.pcmConfirmed ? SAPL(@"PCM получен",@"PCM confirmed") : SAPL(@"PCM пока не подтверждён",@"PCM not confirmed yet")],
        (unsigned long long)s.callbacks, (unsigned long long)s.frames, (unsigned long long)s.pcmBytes,
        (unsigned long long)s.nonzeroCallbacks, s.sampleRate, s.channels, s.bitsPerChannel, fourcc(s.formatID),
        source.lastPathComponent.length ? source.lastPathComponent : SAPL(@"не зарегистрирован",@"not registered"), route,
        (unsigned long long)s.mutedCallbacks, SAPRecording() ? SAPL(@"\n● Идёт запись WAV",@"\n● Recording WAV") : @""];
    return @{ @"report":report, @"diagnostics":message, @"journal_summary":@"",
        @"download_active":@(SAPTrackDownloadActive()), @"key_request_mode":SAPKeyRequestModeReport(), @"recording":@(SAPRecording()),
        @"last_wav_available":@(SAPLastWAVAvailable()) };
}
+ (void)setKeyRequestMode:(NSInteger)mode completion:(void (^)(BOOL,NSString *))completion {
    SAPSetKeyRequestMode(mode,completion);
}
+ (void)refreshDownloadCompatibility:(void (^)(NSDictionary *))completion {
    SAPRefreshDownloadCompatibility(completion);
}
+ (void)previewOfflineDeviceSlots:(void (^)(NSDictionary *,NSString *))completion {SAPPreviewOfflineDeviceSlots(completion);}
+ (void)releaseOfflineDeviceSlots:(NSString *)planID cacheIDs:(NSArray *)cacheIDs completion:(void (^)(NSDictionary *,NSString *))completion {SAPReleaseOfflineDeviceSlots(planID,cacheIDs,completion);}
+ (void)enableOfflineOnCurrentDevice:(void (^)(NSDictionary *,NSString *))completion {SAPEnableOfflineOnCurrentDevice(completion);}
+ (void)perform:(SAPSettingsAction)action {
    if(!SAPTraceIsActive()){[self performObserved:action];return;}
    SAPTraceID operation=SAPTraceBegin(@"settings_action",@"pixie_ui",@{@"action_number":@(action)});
    SAPTraceWithOperation(operation,^{[self performObserved:action];});
    SAP_TRACE("ui","action_handler_returned",operation,@{@"action_number":@(action),@"asynchronous_completion_proven":@NO});
}
+ (void)performObserved:(SAPSettingsAction)action {
    switch(action) {
        case SAPSettingsDownload: SAPDownloadCurrentTrack(^(NSString *text){SAPDownloadMessage(text);});break;
        case SAPSettingsDownloadAlbum: SAPDownloadCurrentAlbum(^(NSString *text){SAPDownloadMessage(text);});break;
        case SAPSettingsVerify: SAPVerifyCurrentTrack(^(NSString *text){SAPDownloadMessage(text);});break;
        case SAPSettingsCancelDownload: SAPCancelTrackDownload();break;
        case SAPSettingsRefreshJournal: SAPJournalRefresh(@"settings");break;
        case SAPSettingsExportJournal: {
            dispatch_async(SAPReportQueue(),^{
                NSDictionary *report=SAPJournalReport();NSMutableArray *items=[NSMutableArray array];
                NSURL *table=SAPJournalWriteTableSnapshot(report);if(table)[items addObject:table];
                NSURL *json=SAPJournalWriteReportSnapshot(report);if(json)[items addObject:json];
                NSURL *log=[SAPDocuments() URLByAppendingPathComponent:report[@"log_file"]?:@"SpotifyAudioProbeJournal.log"];
                if([NSFileManager.defaultManager fileExistsAtPath:log.path])[items addObject:log];
                dispatch_async(dispatch_get_main_queue(),^{if(items.count)SAPShareItems(items);else SAPMessage(SAPL(@"Журнал пока пуст.",@"The log is empty."));});
            });break;
        }
        case SAPSettingsResetJournal: SAPJournalReset();break;
        case SAPSettingsMute:
            if(!SpotifyAudioProbeMuteForSeconds(2))SAPMessage(SAPL(@"Сначала запусти воспроизведение на этом iPhone.",@"Start playback on this iPhone first."));break;
        case SAPSettingsToggleRecording:
#if SAP_ENABLE_WAV_CAPTURE
            if(SAPRecorder.shared.recording)[SAPRecorder.shared stopAndShare];else[SAPRecorder.shared start];break;
        case SAPSettingsExportWAV: SAPShare(SAPRecorder.shared.lastFile);break;
#else
        case SAPSettingsExportWAV: break;
#endif
        case SAPSettingsExportReport: {
            NSDictionary *native=[self diagnosticSnapshot];
            dispatch_async(SAPReportQueue(),^{
                NSDictionary *report=SAPCompleteDiagnosticSnapshot(native)[@"report"];
                NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:NULL];
                NSURL *url=[SAPDocuments() URLByAppendingPathComponent:@"SpotifyAudioProbe.json"];
                BOOL saved=json && [json writeToURL:url atomically:YES];
                dispatch_async(dispatch_get_main_queue(),^{if(saved)SAPShare(url);else SAPMessage(SAPL(@"Не удалось сохранить отчёт.",@"Could not save the report."));});
            });break;
        }
        case SAPSettingsSendLog: {
            SAPJournalNoteAction(@"send_log_requested",@{@"diagnostics_enabled":@(SAPDiagnosticsEnabled())});
            NSDictionary *native=[self diagnosticSnapshot];
            SAPTraceCaptureRuntimeManifest("support_log_export");
            dispatch_async(SAPReportQueue(),^{
                SAPJournalFlushActions();
                NSDictionary *journal=SAPJournalReport();
                NSMutableDictionary *report=[SAPCompleteDiagnosticSnapshotWithJournal(native,journal)[@"report"] mutableCopy];
                report[@"observation_note"]=[native[@"report"][@"diagnostics_enabled"] boolValue]?@"Passive diagnostic events were enabled when this package was exported.":@"Passive diagnostic events were disabled when this package was exported; their absence does not prove that no event occurred.";
                report[@"diagnostic_trace"]=SAPTraceExport();
                NSURL *summary=[SAPDocuments() URLByAppendingPathComponent:@"PixieSupportLog.json"];
                NSMutableArray *files=[NSMutableArray array];
                for(NSString *name in @[@"SpotifyAudioProbeJournal.log",@"SpotifyAudioProbeJournal.1.log",@"PixieActions.log",@"PixieActions.1.log"]) {
                    NSURL *url=[SAPDocuments() URLByAppendingPathComponent:name];
                    [files addObject:SAPSupportLogReadFile(url)];
                }
                NSURL *(*vitrineReport)(void)=dlsym(RTLD_DEFAULT,"SGWriteDiagnosticsFile");
                if(vitrineReport) {
                    NSURL *url=vitrineReport();
                    if([url isKindOfClass:NSURL.class])[files addObject:SAPSupportLogReadFile(url)];
                    else [files addObject:@{@"name":@"vitrine-diagnostics.txt",@"read_status":@"unavailable",@"error":@"Vitrine did not produce a diagnostics file"}];
                }else [files addObject:@{@"name":@"vitrine-diagnostics.txt",@"read_status":@"unavailable",@"error":@"Vitrine diagnostics exporter is not loaded"}];
                NSURL *eeveeLog=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"eeveespotify_debug.log"]];
                [files addObject:SAPSupportLogReadFile(eeveeLog)];
                NSError *error=nil;
                BOOL saved=SAPSupportLogWrite(summary,report,journal,SAPJournalSummaryForReport(journal),files,&error);
                dispatch_async(dispatch_get_main_queue(),^{if(saved)SAPShare(summary);else SAPMessage([NSString stringWithFormat:@"Could not save the support log: %@",error.localizedDescription?:@"unknown error"]);});
            });break;
        }
    }
}
@end

__attribute__((constructor)) static void SAPLoad(void) {
    @autoreleasepool {
        SAPDiagnosticsInitialize();
        if(SAPDiagnosticsEnabled()){SAPPlayerTraceSetActive(YES);SAPNativeErrorLogSetActive(YES);}
        [NSNotificationCenter.defaultCenter addObserverForName:SAPDiagnosticsDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *note){
            SAPPlayerTraceSetActive(SAPDiagnosticsEnabled());SAPNativeErrorLogSetActive(SAPDiagnosticsEnabled());
        }];
        SpotifyAudioProbeInitialize();
        SAPInstallOfflineFlags();
        SAPInstallOfflineConfig();
        SAPInstallNativeOffline();
        SAPInstallTrackDownloader();
        SAP_TRACE("startup","pixie_hooks_installed",0,@{@"offline_flags":SAPOfflineFlagsReport(),@"offline_config":SAPOfflineConfigReport(),@"native_offline":SAPNativeOfflineReport(),@"transport":SAPTrackDownloadReport(),@"hooks":SAPTraceHookManifest()});
    }
}
