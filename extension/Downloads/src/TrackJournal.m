#import "Localization.h"
#import "TrackJournal.h"
#import "WireProto.h"
#import "NativeErrorLog.h"
#import "PlayerTrace.h"
#import "Diagnostics.h"
#import "Deadline.h"
#import "DiagnosticTrace.h"
#include <os/lock.h>
#include <stdatomic.h>

// Границы: журнал живёт внутри Spotify и не должен расти без предела.
static const NSUInteger maximumTracks = 20000, maximumTransitions = 400, maximumEvents = 120;
static const NSUInteger maximumEntities = 24, maximumTrackTransitions = 12;
static const NSUInteger chunkSize = 300, maximumChunks = 12, maximumReportedTracks = 3000;
static const double refreshThrottle = 2, pollInterval = 5, sessionIdleTimeout = 45;
static const double maximumSessionSeconds = 1800, stalledAfter = 45;

static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
static dispatch_queue_t journal;
static void *journalKey = &journalKey;
static SAPJournalCaller caller;
static void (^quotaSampler)(void);
static atomic_bool callerAvailable;
static NSMutableDictionary *outstanding;   // метод -> когда отправлен и какой попыткой
static NSMutableArray *transportEvents;
static NSString *focusedURI;
static NSMutableArray *unanswered;         // методы, не ответившие ни по одному каналу
static NSMutableArray *lifetimes;
static dispatch_source_t pollTimer;
static BOOL subscribed;
static double lastRefresh,lastQuotaSample;
static void diagnosticsChanged(void);
static void sampleQuota(void) {
    if(quotaSampler && CFAbsoluteTimeGetCurrent()-lastQuotaSample>=30) {
        lastQuotaSample=CFAbsoluteTimeGetCurrent();quotaSampler();
    }
}
static NSUInteger pollTicks;
static NSUInteger subscriptionGeneration;
static NSUInteger playerTraceSessionGeneration;
static atomic_uint playerTraceSinkPending,playerTraceSinkDropped;

static NSMutableDictionary *tracks;          // uri -> SAPTrack
static NSMutableArray *transitions;          // последние переходы любого трека
static NSMutableArray *errorEvents, *contextAddedEvents, *entityEvents;
static NSMutableDictionary *entities;        // uri плейлиста -> состояние/прогресс
static NSMutableDictionary *snapshots;       // license_status, bulk_preflight, offline_playback, quota
static NSMutableDictionary *methodCalls;     // имя метода -> число наблюдённых ответов
static NSMutableArray *totalProgressSamples;
static NSDictionary *totalProgress;
static NSMutableDictionary *session;         // текущая сессия загрузки
static NSMutableArray *sessionHistory;
static NSMutableArray *actionEvents;
static double journalStarted;

static double rightNow(void) { return CFAbsoluteTimeGetCurrent(); }
static NSNumber *stamp(double value) { return value > 0 ? @(round((value + kCFAbsoluteTimeIntervalSince1970) * 1000) / 1000) : nil; }
static NSNumber *age(double value) { return value > 0 ? @(round((rightNow() - value) * 10) / 10) : nil; }

NSString *SAPJournalItemStateName(NSUInteger state) {
    switch (state) {
        case 0: return @"not_downloaded"; case 1: return @"error"; case 2: return @"expired";
        case 3: return @"downloaded"; case 4: return @"awaiting_redownload"; case 5: return @"downloading";
        case 6: return @"waiting"; case 7: return @"waiting_limit_exceeded"; default: return @"unknown";
    }
}
static NSString *contextStateName(NSUInteger state) {
    switch (state) {
        case 0: return @"not_downloaded"; case 1: return @"error"; case 2: return @"requested";
        case 3: return @"downloaded"; case 4: return @"downloading"; case 5: return @"waiting"; default: return @"unknown";
    }
}
static NSString *errorName(uint64_t code) {
    switch (code) {
        case 0: return @"SUCCESS"; case 1: return @"GENERIC"; case 8: return @"DISK_FULL";
        case 14: return @"EXPIRED"; case 19: return @"TOO_MANY_TRACKS"; case 23: return @"NOT_ALLOWED";
        case 36: return @"CONNECTION_DISABLED"; case 7028: return @"DEVICE_LIMIT_REACHED"; default: return @"UNKNOWN";
    }
}
static NSString *reasonName(uint64_t reason) {
    switch (reason) {
        case 0: return @"unspecified"; case 1: return @"user_local_device"; case 2: return @"user_remote_device";
        case 3: return @"auto_download"; default: return @"unknown";
    }
}
// Незавершённые состояния: трек ещё должен куда-то перейти.
static BOOL pendingState(NSUInteger state) { return state == 4 || state == 5 || state == 6; }
static BOOL failedState(NSUInteger state) { return state == 1 || state == 7; }
static NSString *shortIdentifier(NSString *uri) {
    NSRange range = [uri rangeOfString:@":" options:NSBackwardsSearch];
    return range.location == NSNotFound ? uri : [uri substringFromIndex:range.location + 1];
}

@interface SAPTrack : NSObject {
@public
    NSString *uri, *entity, *lastSource;
    NSUInteger state, videoState, progress, maxProgress, observations, rowQueries, addRequests, removeRequests;
    BOOL seen;
    NSInteger legacyState;
    double legacyAt, iconAt, wireAt;
    NSInteger uiStatus;              // значок строки: 0 нет, 1 ожидание, 2 идёт, 3 скачан, 4 ошибка
    double firstSeen, lastSeen, lastChange, enteredState, lastProgressAt, requestedAt;
    NSNumber *requestError;
    NSDictionary *nativeError;
    double nativeKeyAt, nativeDownloadAt;
    NSMutableArray *nativeEvents;
    NSMutableArray *history, *errors;
    NSMutableDictionary *timeInState;
}
@end
@implementation SAPTrack @end
static NSDictionary *trackDictionary(SAPTrack *record,double moment);

static void setup(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        journal = dispatch_queue_create("SpotifyAudioProbe.track-journal",
            dispatch_queue_attr_make_with_autorelease_frequency(DISPATCH_QUEUE_SERIAL, DISPATCH_AUTORELEASE_FREQUENCY_WORK_ITEM));
        dispatch_queue_set_specific(journal, journalKey, journalKey, NULL);
        tracks = [NSMutableDictionary dictionary]; transitions = [NSMutableArray array];
        errorEvents = [NSMutableArray array]; contextAddedEvents = [NSMutableArray array];
        entityEvents = [NSMutableArray array]; entities = [NSMutableDictionary dictionary];
        snapshots = [NSMutableDictionary dictionary]; methodCalls = [NSMutableDictionary dictionary];
        totalProgressSamples = [NSMutableArray array]; sessionHistory = [NSMutableArray array];
        actionEvents = [NSMutableArray array];
        outstanding = [NSMutableDictionary dictionary]; unanswered = [NSMutableArray array];transportEvents=[NSMutableArray array];
        lifetimes = [NSMutableArray array]; journalStarted = rightNow();
        [NSNotificationCenter.defaultCenter addObserverForName:SAPDiagnosticsDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *note){diagnosticsChanged();}];
    });
}
static void onJournal(void (^work)(void)) {
    setup();SAPTraceID operation=SAPTraceCurrentOperation();uint64_t epoch=SAPTraceGeneration();
    dispatch_async(journal,^{SAPTraceWithOperation(epoch==SAPTraceGeneration()?operation:0,work);});
}
BOOL SAPJournalOnOwnQueue(void) { return dispatch_get_specific(journalKey) != NULL; }

static void trimEvents(NSMutableArray *list, NSUInteger limit) { while (list.count > limit) [list removeObjectAtIndex:0]; }

// --- постоянный журнал на диске ------------------------------------------
// Всё, что видит журнал, пишется строкой в Documents/SpotifyAudioProbeJournal.log.
// Файл переживает перезапуск приложения: отчёт показывает текущее состояние,
// а лог — весь путь каждого трека, включая то, что было до перезапуска.

static NSURL *documentsURL(NSString *name);
static NSString *uiStatusName(NSInteger status);
@class SAPJournalRead;
static SAPJournalRead *send(NSString *method, NSData *payload, BOOL stream);
static void requestReconciliation(NSString *uri);
static FILE *logStream;
static unsigned long long logBytes;
static NSDateFormatter *logClock;
static const unsigned long long maximumLogBytes = 8 * 1024 * 1024;
static FILE *actionStream;
static unsigned long long actionBytes;
static const unsigned long long maximumActionBytes = 2 * 1024 * 1024;

void SAPJournalNoteAction(NSString *name,NSDictionary *facts) {
    if(![name isKindOfClass:NSString.class] || !name.length || name.length>80 ||
       ![facts isKindOfClass:NSDictionary.class])return;
    NSString *eventName=[name copy];NSDictionary *values=[facts copy];
    // Preserve the observation time before this event reaches the journal queue.
    SAP_TRACE("pixie_action",name.UTF8String,SAPTraceCurrentOperation(),values);
    onJournal(^{
        NSDictionary *entry=@{@"at":stamp(rightNow())?:@0,@"event":eventName,@"facts":values};
        NSData *line=[NSJSONSerialization dataWithJSONObject:entry options:NSJSONWritingSortedKeys error:NULL];
        if(!line)return;
        os_unfair_lock_lock(&lock);[actionEvents addObject:entry];trimEvents(actionEvents,200);os_unfair_lock_unlock(&lock);
        if(actionStream && actionBytes>maximumActionBytes) {
            fclose(actionStream);actionStream=NULL;actionBytes=0;
            NSURL *current=documentsURL(@"PixieActions.log"),*previous=documentsURL(@"PixieActions.1.log");
            [NSFileManager.defaultManager removeItemAtURL:previous error:NULL];
            [NSFileManager.defaultManager moveItemAtURL:current toURL:previous error:NULL];
        }
        if(!actionStream) {
            actionStream=fopen(documentsURL(@"PixieActions.log").fileSystemRepresentation,"a");
            if(!actionStream)return;
            actionBytes=(unsigned long long)ftello(actionStream);
        }
        if(fwrite(line.bytes,1,line.length,actionStream)==line.length &&
           fwrite("\n",1,1,actionStream)==1)actionBytes+=line.length+1;
        fflush(actionStream);
    });
}
void SAPJournalFlushActions(void) {
    setup();if(!SAPJournalOnOwnQueue())dispatch_sync(journal, ^{if(actionStream)fflush(actionStream);});
}

static void journalWrite(NSString *kind, NSString *detail) { // только на очереди журнала
    if(!SAPDiagnosticsEnabled())return;
    if (!detail.length) return;
    if (!logClock) {
        logClock = [NSDateFormatter new];
        logClock.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        logClock.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    }
    if (logStream && logBytes > maximumLogBytes) {
        fclose(logStream); logStream = NULL; logBytes = 0;
        NSURL *url = documentsURL(@"SpotifyAudioProbeJournal.log");
        NSURL *previous = documentsURL(@"SpotifyAudioProbeJournal.1.log");
        [NSFileManager.defaultManager removeItemAtURL:previous error:NULL];
        [NSFileManager.defaultManager moveItemAtURL:url toURL:previous error:NULL];
    }
    if (!logStream) {
        NSURL *url = documentsURL(@"SpotifyAudioProbeJournal.log");
        logStream = fopen(url.fileSystemRepresentation, "a");
        if (!logStream) return;
        logBytes = (unsigned long long)ftello(logStream);
        int written = fprintf(logStream, "=== SpotifyAudioProbe journal opened %s ===\n", [logClock stringFromDate:NSDate.date].UTF8String);
        if (written > 0) logBytes += (unsigned long long)written;
    }
    NSString *line = [NSString stringWithFormat:@"%@ %-9@ %@\n", [logClock stringFromDate:NSDate.date], kind ?: @"", detail];
    const char *bytes = line.UTF8String;
    if (!bytes) return;
    size_t length = strlen(bytes);
    if (fwrite(bytes, 1, length, logStream) == length) logBytes += length;
    fflush(logStream);
}
static void journalLog(NSString *kind, NSString *format, ...) NS_FORMAT_FUNCTION(2, 3);
static void journalLog(NSString *kind, NSString *format, ...) {
    if(!SAPDiagnosticsEnabled())return;
    va_list arguments; va_start(arguments, format);
    NSString *detail = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    journalWrite(kind, detail);
}

// --- учёт состояний -------------------------------------------------------

static SAPTrack *recordFor(NSString *uri) { // вызывать под stateLock
    SAPTrack *record = tracks[uri];
    if (record) return record;
    if (tracks.count >= maximumTracks) {
        NSArray *oldest = [tracks.allValues sortedArrayUsingComparator:^NSComparisonResult(SAPTrack *a, SAPTrack *b) {
            return a->lastSeen < b->lastSeen ? NSOrderedAscending : a->lastSeen > b->lastSeen ? NSOrderedDescending : NSOrderedSame;
        }];
        for (NSUInteger i = 0; i < oldest.count / 10 + 1; i++) [tracks removeObjectForKey:((SAPTrack *)oldest[i])->uri];
    }
    record = [SAPTrack new];
    record->uri = [uri copy]; record->firstSeen = rightNow(); record->uiStatus = -1; record->legacyState = -1;
    record->history = [NSMutableArray array]; record->errors = [NSMutableArray array];
    record->nativeEvents = [NSMutableArray array];
    record->timeInState = [NSMutableDictionary dictionary];
    tracks[uri] = record;
    return record;
}
static void beginSession(NSString *reason, NSString *entity);
static void endSessionIfIdle(void);
static void traceComparison(SAPTrack *record) {
    if(!SAPTraceIsActive())return;
    os_unfair_lock_lock(&lock);
    NSDictionary *facts=@{@"uri":record->uri,@"wire_observed":@(record->seen),@"wire_state":@(record->state),
        @"wire_journal_decoded_at":stamp(record->wireAt)?:NSNull.null,@"wire_source":record->lastSource?:@"unavailable",
        @"icon_observed":@(record->uiStatus>=0),@"icon_status":@(record->uiStatus),@"icon_captured_at":stamp(record->iconAt)?:NSNull.null,
        @"downloaded_states_agree":record->seen&&record->uiStatus>=0?@((record->state==3)==(record->uiStatus==3)):NSNull.null,
        @"correlation":@"same URI, independent observations; not a simultaneous snapshot",@"file_verified":@NO};
    os_unfair_lock_unlock(&lock);
    SAP_TRACE("comparison","wire_and_icon",SAPTraceCurrentOperation(),facts);
}

static void applyState(NSString *uri, NSUInteger state, NSUInteger videoState, NSUInteger progress, BOOL hasProgress, NSString *source) {
    if (![uri isKindOfClass:NSString.class] || !uri.length || uri.length > 256) return;
    double moment = rightNow();
    NSString *logLine = nil, *progressLine = nil, *errorLine = nil;
    BOOL startSession = NO;
    os_unfair_lock_lock(&lock);
    SAPTrack *record = recordFor(uri);
    record->observations++; record->lastSeen = moment; record->lastSource = source;
    record->videoState = videoState; record->wireAt = moment;
    BOOL changed = !record->seen || record->state != state;
    if (changed) {
        NSString *from = record->seen ? SAPJournalItemStateName(record->state) : @"unseen";
        double held = record->seen && record->enteredState > 0 ? moment - record->enteredState : 0;
        if (held > 0) {
            NSNumber *spent = record->timeInState[from];
            record->timeInState[from] = @(round((spent.doubleValue + held) * 10) / 10);
        }
        record->state = state; record->seen = YES; record->enteredState = moment; record->lastChange = moment;
        NSDictionary *entry = @{@"track_uri": uri, @"from": from, @"to": SAPJournalItemStateName(state),
            @"progress": @(progress), @"at": stamp(moment) ?: @0, @"source": source ?: @""};
        [record->history addObject:entry];
        while (record->history.count > maximumTrackTransitions) [record->history removeObjectAtIndex:0];
        [transitions addObject:entry]; trimEvents(transitions, maximumTransitions);
        logLine = [NSString stringWithFormat:@"%@ %@ -> %@ %lu%% held=%@ source=%@ obs=%lu",
            shortIdentifier(uri), from, SAPJournalItemStateName(state), (unsigned long)progress,
            held > 0 ? [NSString stringWithFormat:@"%.1fs", held] : @"-", source ?: @"", (unsigned long)record->observations];
        // Error ядра приходит без URI, поэтому ошибку привязываем по времени и помечаем correlated.
        if (failedState(state)) {
            NSDictionary *recent = errorEvents.lastObject;
            double errorAge = recent ? moment - [recent[@"absolute"] doubleValue] : -1;
            NSMutableDictionary *failure = [@{@"at": stamp(moment) ?: @0, @"state": SAPJournalItemStateName(state),
                @"progress": @(record->progress), @"previous_state": from,
                @"attempts": @(record->addRequests)} mutableCopy];
            if (record->requestError) {
                failure[@"add_response"] = record->requestError;
                failure[@"add_response_name"] = errorName(record->requestError.unsignedLongLongValue);
            }
            if ([recent[@"code"] unsignedLongLongValue] && errorAge >= -0.01 && errorAge <= 15) {
                failure[@"core_error"] = recent[@"code"]; failure[@"core_error_name"] = recent[@"name"];
                failure[@"core_error_age_seconds"] = @(MAX(0, round(errorAge * 10) / 10));
                failure[@"correlated"] = @YES;
            }
            [record->errors addObject:failure];
            while (record->errors.count > 8) [record->errors removeObjectAtIndex:0];
            errorLine = [NSString stringWithFormat:@"%@ %@ after %@ at %lu%%%@%@", shortIdentifier(uri),
                SAPJournalItemStateName(state), from, (unsigned long)record->progress,
                failure[@"core_error_name"] ? [NSString stringWithFormat:@" core=%@(%@) %@s ago", failure[@"core_error_name"], failure[@"core_error"], failure[@"core_error_age_seconds"]] : @"",
                failure[@"add_response_name"] ? [NSString stringWithFormat:@" add=%@", failure[@"add_response_name"]] : @""];
        }
        startSession = pendingState(state) && !session;
    }
    if (hasProgress && progress != record->progress) {
        NSUInteger previous = record->progress;
        record->progress = progress; record->lastProgressAt = moment;
        if (progress > record->maxProgress) record->maxProgress = progress;
        progressLine = [NSString stringWithFormat:@"%@ %@ %lu%% -> %lu%% source=%@", shortIdentifier(uri),
            SAPJournalItemStateName(record->state), (unsigned long)previous, (unsigned long)progress, source ?: @""];
    }
    os_unfair_lock_unlock(&lock);
    if (logLine) { NSLog(@"[SpotifyAudioProbe] state %@", logLine); journalWrite(@"state", logLine); }
    if(changed && state==3 && record->nativeError)
        journalLog(@"recovered",@"%@ downloaded after previous native error %@; historical error does not override current state",uri,record->nativeError[@"name"]);
    if (errorLine) { NSLog(@"[SpotifyAudioProbe] FAILED %@", errorLine); journalWrite(@"failed", errorLine); }
    if (progressLine) journalWrite(@"progress", progressLine);
    if(logLine && record->uiStatus>=0)
        journalLog(@"compare",@"%@ wire=%@ icon=%@ legacy=%@",shortIdentifier(uri),SAPJournalItemStateName(state),
            uiStatusName(record->uiStatus),record->legacyState>=0?uiStatusName(record->legacyState):@"unseen");
    if((logLine||progressLine)&&record->uiStatus>=0)traceComparison(record);
    if (startSession) beginSession(@"item_state", nil);
}
// Статус значка, который реально рисует строка плейлиста
// (SPTFreeTierOfflineStatusUpdatingContentOperation.offlineSyncStatusForURL:).
void SAPJournalNoteUIStatus(NSString *uri, NSInteger status) {
    if(!SAPDiagnosticsEnabled())return;
    if (![uri isKindOfClass:NSString.class] || !uri.length || uri.length > 256) return;
    SAP_TRACE("ui","download_icon_observed",SAPTraceCurrentOperation(),@{@"uri":uri,@"status":@(status),@"state_domain":@"GLUEOfflineSyncStatus",@"file_or_audio_verified":@NO});
    NSString *copied = [uri copy];double capturedAt=rightNow();
    onJournal(^{
        if(!SAPDiagnosticsEnabled())return;
        NSString *line = nil;
        os_unfair_lock_lock(&lock);
        SAPTrack *record = recordFor(copied);
        if (record->uiStatus != status) {
            NSString *from = record->uiStatus >= 0 ? uiStatusName(record->uiStatus) : @"unseen";
            record->uiStatus = status;
            line = [NSString stringWithFormat:@"%@ icon %@ -> %@ (state %@)", shortIdentifier(copied), from,
                uiStatusName(status), record->seen ? SAPJournalItemStateName(record->state) : @"unseen"];
        }
        record->iconAt=capturedAt;
        os_unfair_lock_unlock(&lock);
        if(line)traceComparison(record);
        if (line) { journalWrite(@"icon", line); requestReconciliation(copied); }
    });
}

void SAPJournalNoteRowState(NSString *uri, NSUInteger state) {
    if(!SAPDiagnosticsEnabled())return;
    if (![uri isKindOfClass:NSString.class] || !uri.length) return;
    SAP_TRACE("ui","row_state_observed",SAPTraceCurrentOperation(),@{@"uri":uri,@"state":@(state),@"state_domain":@"GLUEOfflineSyncStatus"});
    NSString *copied = [uri copy];
    onJournal(^{
        if(!SAPDiagnosticsEnabled())return;
        os_unfair_lock_lock(&lock);
        SAPTrack *record=recordFor(copied); record->rowQueries++;
        BOOL changed=record->legacyState!=(NSInteger)state;
        record->legacyState=(NSInteger)state; record->legacyAt=rightNow();
        os_unfair_lock_unlock(&lock);
        // This API uses GLUEOfflineSyncStatus (0..4), not protobuf Item.State (0..7).
        // A row observation must never overwrite the authoritative wire state.
        if(changed) {
            journalLog(@"row", @"%@ legacy=%@", shortIdentifier(copied), uiStatusName((NSInteger)state));
            requestReconciliation(copied);
        }
    });
}
void SAPJournalNoteNativeError(NSString *uri,NSNumber *code,NSString *name) {
    if(!SAPDiagnosticsEnabled())return;
    if(![uri hasPrefix:@"spotify:track:"] || uri.length!=36 || !name.length)return;
    SAP_TRACE("native_log","track_error",SAPTraceCurrentOperation(),@{@"uri":uri,@"name":name,@"code_present_in_line":code?:NSNull.null,@"source":@"native_log_exact_uri",@"server_rejection_reason_proven":@NO});
    double moment=rightNow();
    onJournal(^{
        if(!SAPDiagnosticsEnabled())return;
        os_unfair_lock_lock(&lock);SAPTrack *record=recordFor(uri);
        NSMutableDictionary *error=[@{@"name":name,@"uri":uri,@"at":@(moment+kCFAbsoluteTimeIntervalSince1970),@"source":@"native_log_exact_uri"} mutableCopy];
        if(code)error[@"code"]=code;
        else if([record->nativeError[@"code"] integerValue]==7004 && [name isEqual:@"key_denied"])error[@"code"]=@7004;
        error[@"code_present_in_this_line"]=code?:NSNull.null;
        error[@"code_copied_from_previous_record"]=@(!code&&error[@"code"]!=nil);
        record->nativeError=[error copy];
        [record->nativeEvents addObject:record->nativeError];trimEvents(record->nativeEvents,12);
        os_unfair_lock_unlock(&lock);
        journalLog(@"native_error",@"%@ %@ code=%@",uri,name,code?:@"not present in this line");
    });
}
void SAPJournalNoteNativeSuccess(NSString *uri,NSString *event) {
    if(!SAPDiagnosticsEnabled())return;
    if(![uri hasPrefix:@"spotify:track:"] || uri.length!=36 ||
       (![event isEqual:@"key_received"] && ![event isEqual:@"downloaded"]))return;
    SAP_TRACE("native_log",event.UTF8String,SAPTraceCurrentOperation(),@{@"uri":uri,@"source":@"native_log_exact_uri",@"native_request_link":@"not_proven_by_this_log_line",@"audio_playback_tested":@NO});
    double moment=rightNow();
    onJournal(^{
        if(!SAPDiagnosticsEnabled())return;
        os_unfair_lock_lock(&lock);SAPTrack *record=recordFor(uri);
        if([event isEqual:@"key_received"])record->nativeKeyAt=moment;else record->nativeDownloadAt=moment;
        NSDictionary *value=@{@"name":event,@"uri":uri,@"at":@(moment+kCFAbsoluteTimeIntervalSince1970),@"source":@"native_log_exact_uri"};
        [record->nativeEvents addObject:value];trimEvents(record->nativeEvents,12);
        NSDictionary *priorError=record->nativeError;os_unfair_lock_unlock(&lock);
        journalLog(@"native_success",@"%@ %@ previous_error=%@",uri,event,priorError[@"name"]?:@"none observed");
    });
}
NSDictionary *SAPJournalNativeErrorForURI(NSString *uri) {
    if(!SAPDiagnosticsEnabled())return nil;
    setup();os_unfair_lock_lock(&lock);SAPTrack *record=tracks[uri];NSDictionary *error=record?record->nativeError:nil;os_unfair_lock_unlock(&lock);return error;
}
void SAPJournalNoteQuota(NSDictionary *quota) {
    if(!SAPDiagnosticsEnabled())return;
    if (![quota isKindOfClass:NSDictionary.class]) return;
    SAP_TRACE("queue","native_manager_snapshot",SAPTraceCurrentOperation(),quota);
    NSDictionary *copied = [quota copy];
    onJournal(^{
        if(!SAPDiagnosticsEnabled())return;
        NSMutableDictionary *value = [copied mutableCopy];
        value[@"at"] = stamp(rightNow());
        os_unfair_lock_lock(&lock); snapshots[@"quota"] = value; os_unfair_lock_unlock(&lock);
        journalLog(@"quota", @"tracks %@/%@ episodes %@/%@ duration %@s local_prepared=%@ online=%@ connection_allows=%@ license_expired=%@ sync_level=%@ allow_tracks=%@ reason=%@",
            copied[@"current_tracks"] ?: @"?", copied[@"music_limit"] ?: @"?",
            copied[@"current_episodes"] ?: @"?", copied[@"episode_limit"] ?: @"?",
            copied[@"music_duration_seconds"] ?: @"?", copied[@"local_prepared"] ?: @"?",
            copied[@"online"] ?: @"?", copied[@"connection_allows_offlining"] ?: @"?",
            copied[@"track_license_expired"] ?: @"?", copied[@"sync_level"] ?: @"?",
            copied[@"allow_spotify_tracks"] ?: @"?", copied[@"reason"] ?: @"");
    });
}
void SAPJournalNoteEntityReset(NSString *entity) {
    if(!SAPDiagnosticsEnabled())return;
    if (![entity isKindOfClass:NSString.class] || !entity.length) return;
    NSString *copied = [entity copy];
    onJournal(^{
        if(!SAPDiagnosticsEnabled())return;
        os_unfair_lock_lock(&lock);
        [entityEvents addObject:@{@"entity": copied, @"action": @"reset", @"at": stamp(rightNow()) ?: @0}];
        trimEvents(entityEvents, maximumEvents);
        os_unfair_lock_unlock(&lock);
        NSLog(@"[SpotifyAudioProbe] offline reset requested for %@", copied);
        journalLog(@"entity", @"reset %@", copied);
    });
}
void SAPJournalNoteEntityRequest(NSString *entity, NSArray *trackURLs) {
    if(!SAPDiagnosticsEnabled())return;
    if (![entity isKindOfClass:NSString.class] || !entity.length) return;
    NSString *copiedEntity = [entity copy];
    NSMutableArray *uris = [NSMutableArray array];
    if ([trackURLs isKindOfClass:NSArray.class]) for (id value in trackURLs) {
        NSString *text = [value isKindOfClass:NSURL.class] ? [value absoluteString] : [value isKindOfClass:NSString.class] ? value : nil;
        if (text.length && text.length <= 256) [uris addObject:text];
        if (uris.count >= maximumTracks) break;
    }
    onJournal(^{
        if(!SAPDiagnosticsEnabled())return;
        double moment = rightNow();
        os_unfair_lock_lock(&lock);
        for (NSString *uri in uris) {
            SAPTrack *record = recordFor(uri);
            if (!record->entity) record->entity = copiedEntity;
            if (!record->requestedAt) record->requestedAt = moment;
        }
        NSMutableDictionary *entry = entities[copiedEntity];
        if (!entry) {
            if (entities.count >= maximumEntities) [entities removeAllObjects];
            entry = [NSMutableDictionary dictionary]; entities[copiedEntity] = entry;
        }
        entry[@"uri"] = copiedEntity; entry[@"requested_at"] = stamp(moment);
        entry[@"requested_tracks"] = @(uris.count);
        [entityEvents addObject:@{@"entity": copiedEntity, @"action": @"download", @"tracks": @(uris.count), @"at": stamp(moment) ?: @0}];
        trimEvents(entityEvents, maximumEvents);
        os_unfair_lock_unlock(&lock);
        NSLog(@"[SpotifyAudioProbe] offline download requested for %@ with %lu tracks", copiedEntity, (unsigned long)uris.count);
        journalLog(@"entity", @"download %@ tracks=%lu", copiedEntity, (unsigned long)uris.count);
        beginSession(@"entity_download", copiedEntity);
    });
}

// --- разбор трафика сервиса Offline --------------------------------------

static NSArray *subMessages(NSArray *fields, unsigned number) {
    NSMutableArray *result = [NSMutableArray array];
    for (NSDictionary *field in fields) {
        if ([field[@"number"] unsignedIntValue] != number || [field[@"wire"] unsignedIntValue] != 2) continue;
        NSArray *parsed = SAPProtoFields(field[@"value"]);
        if (parsed) [result addObject:parsed];
        if (result.count >= maximumTracks) break;
    }
    return result;
}
static NSArray *stringList(NSArray *fields, unsigned number) {
    NSMutableArray *result = [NSMutableArray array];
    for (NSDictionary *field in fields) {
        if ([field[@"number"] unsignedIntValue] != number || [field[@"wire"] unsignedIntValue] != 2) continue;
        NSString *text = [[NSString alloc] initWithData:field[@"value"] encoding:NSUTF8StringEncoding];
        if (text.length) [result addObject:text];
        if (result.count >= maximumTracks) break;
    }
    return result;
}
static double floatField(NSArray *fields, unsigned number) {
    for (NSDictionary *field in fields.reverseObjectEnumerator) {
        if ([field[@"number"] unsignedIntValue] != number || [field[@"wire"] unsignedIntValue] != 5) continue;
        NSData *data = field[@"value"]; if (data.length != 4) continue;
        uint32_t bits = 0; memcpy(&bits, data.bytes, 4); float value = 0; memcpy(&value, &bits, 4);
        return isfinite(value) ? value : 0;
    }
    return 0;
}
// Progress: analysis/offline-esperanto-service.md
static NSDictionary *progressDictionary(NSArray *fields) {
    return @{@"queued_tracks": @(SAPProtoNumber(fields, 1, 0)), @"queued_bytes": @(SAPProtoNumber(fields, 2, 0)),
        @"downloaded_tracks": @(SAPProtoNumber(fields, 3, 0)), @"downloaded_bytes": @(SAPProtoNumber(fields, 4, 0)),
        @"total_tracks": @(SAPProtoNumber(fields, 5, 0)), @"total_bytes": @(SAPProtoNumber(fields, 6, 0)),
        @"downloading": @(SAPProtoNumber(fields, 7, 0) != 0), @"download_speed": @(SAPProtoNumber(fields, 8, 0)),
        @"percent_complete": @(round(floatField(fields, 9) * 10) / 10), @"seconds_left": @(SAPProtoNumber(fields, 10, 0)),
        @"track_totals_state": @(SAPProtoNumber(fields, 11, 0)), @"at": stamp(rightNow()) ?: @0};
}
static void readItems(NSArray *fields, unsigned number, NSString *source) {
    for (NSArray *item in subMessages(fields, number)) {
        NSString *uri = SAPProtoString(item, 1);
        if (!uri.length) continue;
        applyState(uri, (NSUInteger)SAPProtoNumber(item, 2, 0), (NSUInteger)SAPProtoNumber(item, 3, 0),
            (NSUInteger)SAPProtoNumber(item, 4, 0), YES, source);
    }
}
static void noteDownloadRequest(NSString *method, NSArray *request, NSString *source) {
    NSString *uri = SAPProtoString(request, 2);
    if (!uri.length) return;
    double moment = rightNow();
    os_unfair_lock_lock(&lock);
    SAPTrack *record = recordFor(uri);
    if ([method isEqual:@"AddDownload"]) { record->addRequests++; record->requestedAt = moment; }
    else record->removeRequests++;
    os_unfair_lock_unlock(&lock);
    NSLog(@"[SpotifyAudioProbe] %@ %@ (%@)", method, shortIdentifier(uri), source ?: @"");
    journalLog(@"request", @"%@ %@ source=%@", method, shortIdentifier(uri), source ?: @"");
}
static void noteDownloadResponse(NSString *method, NSArray *request, NSArray *response) {
    NSString *uri = SAPProtoString(request, 2);
    uint64_t code = SAPProtoNumber(response, 1, 0);
    if (!uri.length) return;
    os_unfair_lock_lock(&lock);
    SAPTrack *record = recordFor(uri);
    if ([method isEqual:@"AddDownload"]) record->requestError = @(code);
    os_unfair_lock_unlock(&lock);
    journalLog(code ? @"rejected" : @"accepted", @"%@ %@ -> %@ (%llu)", method, shortIdentifier(uri), errorName(code), (unsigned long long)code);
    if (code) NSLog(@"[SpotifyAudioProbe] %@ %@ rejected: %@ (%llu)", method, shortIdentifier(uri), errorName(code), (unsigned long long)code);
}
static void noteContexts(NSArray *response, NSString *source) {
    for (NSArray *info in subMessages(response, 1)) {
        NSArray *contexts = subMessages(info, 1);
        NSArray *context = contexts.firstObject;
        NSString *uri = context ? SAPProtoString(context, 1) : nil;
        if (uri.length) {
            NSUInteger state = (NSUInteger)SAPProtoNumber(context, 2, 0);
            double percent = round(floatField(context, 3) * 10) / 10;
            os_unfair_lock_lock(&lock);
            NSMutableDictionary *entry = entities[uri];
            if (!entry) {
                if (entities.count >= maximumEntities) [entities removeAllObjects];
                entry = [NSMutableDictionary dictionary]; entities[uri] = entry;
            }
            NSString *previousState = entry[@"state"] ?: @"";
            double previousPercent = [entry[@"percent_complete"] doubleValue];
            entry[@"uri"] = uri; entry[@"state"] = contextStateName(state); entry[@"state_code"] = @(state);
            entry[@"percent_complete"] = @(percent); entry[@"updated_at"] = stamp(rightNow());
            BOOL interesting = ![previousState isEqual:contextStateName(state)] || fabs(previousPercent - percent) >= 1;
            os_unfair_lock_unlock(&lock);
            if (interesting) journalLog(@"context", @"%@ %@ %.1f%%", shortIdentifier(uri), contextStateName(state), percent);
        }
        readItems(info, 2, source);
    }
}
static void noteContextsProgress(NSArray *response) {
    for (NSArray *entry in subMessages(response, 1)) {
        NSString *uri = SAPProtoString(entry, 1);
        NSArray *progress = subMessages(entry, 2).firstObject;
        if (!uri.length || !progress) continue;
        NSDictionary *value = progressDictionary(progress);
        os_unfair_lock_lock(&lock);
        NSMutableDictionary *stored = entities[uri];
        if (!stored) {
            if (entities.count >= maximumEntities) [entities removeAllObjects];
            stored = [NSMutableDictionary dictionary]; entities[uri] = stored;
        }
        NSMutableDictionary *previous=[stored[@"progress"] mutableCopy]; [previous removeObjectForKey:@"at"];
        NSMutableDictionary *comparable=[value mutableCopy]; [comparable removeObjectForKey:@"at"];
        BOOL changed=![previous isEqual:comparable];
        stored[@"uri"] = uri; stored[@"progress"] = value;
        os_unfair_lock_unlock(&lock);
        if(changed) journalLog(@"queue", @"%@ %@/%@ tracks, %@/%@ bytes, %@ B/s, left %@s, downloading=%@",
            shortIdentifier(uri), value[@"downloaded_tracks"], value[@"total_tracks"],
            value[@"downloaded_bytes"], value[@"total_bytes"], value[@"download_speed"],
            value[@"seconds_left"], value[@"downloading"]);
    }
}
static void decodeCall(NSString *method, NSData *request, NSData *response, NSString *source) {
    if(!SAPDiagnosticsEnabled())return;
    NSArray *requestFields = request.length ? SAPProtoFields(request) : @[];
    NSArray *responseFields = response ? SAPProtoFields(response) : nil;
    os_unfair_lock_lock(&lock);
    methodCalls[method] = @([methodCalls[method] unsignedLongLongValue] + 1);
    os_unfair_lock_unlock(&lock);
    if (!responseFields) { journalLog(@"silent", @"%@ answered with no body (%@)", method, source ?: @""); return; }
    NSString *label = [NSString stringWithFormat:@"%@/%@", method, source ?: @"app"];
    if ([method isEqual:@"GetItems"] || [method isEqual:@"SubscribeItems"]) {
        if (requestFields.count) {
            NSArray *asked = stringList(requestFields, 1);
            os_unfair_lock_lock(&lock);
            for (NSString *uri in asked) recordFor(uri);
            os_unfair_lock_unlock(&lock);
        }
        readItems(responseFields, 1, label);
    } else if ([method isEqual:@"GetContexts"] || [method isEqual:@"SubscribeContexts"]) {
        noteContexts(responseFields, label);
    } else if ([method isEqual:@"GetContextsProgress"] || [method isEqual:@"SubscribeContextsProgress"]) {
        noteContextsProgress(responseFields);
    } else if ([method isEqual:@"GetTotalProgress"] || [method isEqual:@"SubscribeTotalProgress"]) {
        NSArray *progress = subMessages(responseFields, 1).firstObject;
        if (progress) {
            NSDictionary *value = progressDictionary(progress);
            BOOL changedTotal = NO;
            os_unfair_lock_lock(&lock);
            totalProgress = value;
            NSDictionary *previous = totalProgressSamples.lastObject;
            if (![previous[@"queued_tracks"] isEqual:value[@"queued_tracks"]] ||
                ![previous[@"downloaded_tracks"] isEqual:value[@"downloaded_tracks"]] ||
                ![previous[@"percent_complete"] isEqual:value[@"percent_complete"]]) {
                [totalProgressSamples addObject:value]; trimEvents(totalProgressSamples, maximumEvents);
                changedTotal = YES;
            }
            os_unfair_lock_unlock(&lock);
            if (changedTotal) journalLog(@"total", @"queued=%@ downloaded=%@/%@ bytes=%@/%@ speed=%@ left=%@s percent=%@ downloading=%@ totals=%@",
                value[@"queued_tracks"], value[@"downloaded_tracks"], value[@"total_tracks"],
                value[@"downloaded_bytes"], value[@"total_bytes"], value[@"download_speed"],
                value[@"seconds_left"], value[@"percent_complete"], value[@"downloading"], value[@"track_totals_state"]);
        }
    } else if ([method isEqual:@"AddDownload"] || [method isEqual:@"RemoveDownload"]) {
        noteDownloadRequest(method, requestFields, label);
        noteDownloadResponse(method, requestFields, responseFields);
    } else if ([method isEqual:@"SubscribeError"]) {
        uint64_t code = SAPProtoNumber(responseFields, 1, 0);
        os_unfair_lock_lock(&lock);
        double seen = rightNow();
        snapshots[@"core_status"]=@{@"code":@(code), @"at":stamp(seen)?:@0};
        if(code) {
            [errorEvents addObject:@{@"code": @(code), @"name": errorName(code), @"at": stamp(seen) ?: @0, @"absolute": @(seen)}];
            trimEvents(errorEvents, maximumEvents);
        }
        os_unfair_lock_unlock(&lock);
        if(code) journalLog(@"core", @"error %@ (%llu) source=%@", errorName(code), (unsigned long long)code, label);
    } else if ([method isEqual:@"SubscribeContextAdded"]) {
        NSString *uri = SAPProtoString(responseFields, 1);
        uint64_t reason = SAPProtoNumber(responseFields, 2, 0);
        if (uri.length) {
            os_unfair_lock_lock(&lock);
            [contextAddedEvents addObject:@{@"uri": uri, @"reason": reasonName(reason), @"at": stamp(rightNow()) ?: @0}];
            trimEvents(contextAddedEvents, maximumEvents);
            os_unfair_lock_unlock(&lock);
            journalLog(@"context", @"added %@ reason=%@", shortIdentifier(uri), reasonName(reason));
        }
    } else if ([method isEqual:@"LicenseStatus"]) {
        NSDictionary *value = @{@"max_licenses": @(SAPProtoNumber(responseFields, 1, 0)),
            @"free_licenses": @(SAPProtoNumber(responseFields, 2, 0)),
            @"error": @(SAPProtoNumber(responseFields, 3, 0)),
            @"error_name": errorName(SAPProtoNumber(responseFields, 3, 0)), @"at": stamp(rightNow()) ?: @0};
        os_unfair_lock_lock(&lock);
        BOOL changedLicense = ![snapshots[@"license_status"][@"free_licenses"] isEqual:value[@"free_licenses"]] ||
            ![snapshots[@"license_status"][@"max_licenses"] isEqual:value[@"max_licenses"]];
        snapshots[@"license_status"] = value; os_unfair_lock_unlock(&lock);
        if (changedLicense) journalLog(@"license", @"free=%@ max=%@ error=%@", value[@"free_licenses"], value[@"max_licenses"], value[@"error_name"]);
    } else if ([method isEqual:@"BulkRedownloadPreflight"]) {
        NSDictionary *value = @{@"total_download_bytes": @(SAPProtoNumber(responseFields, 1, 0)),
            @"total_tracks": @(SAPProtoNumber(responseFields, 2, 0)),
            @"is_on_cellular": @(SAPProtoNumber(responseFields, 3, 0) != 0),
            @"sync_over_cellular_allowed": @(SAPProtoNumber(responseFields, 4, 0) != 0),
            @"has_sufficient_storage": @(SAPProtoNumber(responseFields, 5, 0) != 0),
            @"downloads_in_progress": @(SAPProtoNumber(responseFields, 6, 0)),
            @"current_downloaded_bytes": @(SAPProtoNumber(responseFields, 7, 0)), @"at": stamp(rightNow()) ?: @0};
        os_unfair_lock_lock(&lock);
        BOOL changedPreflight = ![snapshots[@"bulk_preflight"][@"has_sufficient_storage"] isEqual:value[@"has_sufficient_storage"]] ||
            ![snapshots[@"bulk_preflight"][@"downloads_in_progress"] isEqual:value[@"downloads_in_progress"]] ||
            ![snapshots[@"bulk_preflight"][@"sync_over_cellular_allowed"] isEqual:value[@"sync_over_cellular_allowed"]];
        snapshots[@"bulk_preflight"] = value; os_unfair_lock_unlock(&lock);
        if (changedPreflight) journalLog(@"storage", @"sufficient=%@ cellular=%@ cellular_allowed=%@ in_progress=%@ pending_bytes=%@",
            value[@"has_sufficient_storage"], value[@"is_on_cellular"], value[@"sync_over_cellular_allowed"],
            value[@"downloads_in_progress"], value[@"total_download_bytes"]);
    } else if ([method isEqual:@"GetOfflinePlaybackStatus"] || [method isEqual:@"SubscribeOfflinePlaybackStatus"]) {
        NSDictionary *value = @{@"allowed": @(SAPProtoNumber(responseFields, 1, 0) != 0),
            @"explicitly_enabled": @(SAPProtoNumber(responseFields, 2, 0) != 0),
            @"implicitly_enabled": @(SAPProtoNumber(responseFields, 3, 0) != 0), @"at": stamp(rightNow()) ?: @0};
        os_unfair_lock_lock(&lock);
        BOOL changedPlayback = ![snapshots[@"offline_playback"][@"allowed"] isEqual:value[@"allowed"]];
        snapshots[@"offline_playback"] = value; os_unfair_lock_unlock(&lock);
        if (changedPlayback) journalLog(@"playback", @"allowed=%@ explicit=%@ implicit=%@",
            value[@"allowed"], value[@"explicitly_enabled"], value[@"implicitly_enabled"]);
    }
}
void SAPJournalObserveCall(NSString *method, NSData *request, NSData *response, NSString *source) {
    if(!SAPDiagnosticsEnabled())return;
    if (![method isKindOfClass:NSString.class] || method.length > 64) return;
    if (response && ![response isKindOfClass:NSData.class]) return;
    SAP_TRACE("offline_observation","response_decoded_at_journal_boundary",SAPTraceCurrentOperation(),@{@"method":method,@"source":source?:@"unknown",
        @"response":SAPTraceWireSummary(@"spotify.offline_esperanto.proto.Offline",method,response,YES),@"rpc_parent_link":SAPTraceCurrentOperation()?@"callback_context":@"unavailable"});
    NSString *copiedMethod = [method copy], *copiedSource = [source copy];
    NSData *copiedRequest = [request isKindOfClass:NSData.class] && request.length <= 1048576 ? [request copy] : nil;
    NSData *copiedResponse = response.length <= 4 * 1024 * 1024 ? [response copy] : nil;
    onJournal(^{
        if(!SAPDiagnosticsEnabled())return;
        @try { decodeCall(copiedMethod, copiedRequest, copiedResponse, copiedSource); }
        @catch (NSException *exception) {
            NSLog(@"[SpotifyAudioProbe] journal decode failed for %@: %@", copiedMethod, exception.name);
            journalLog(@"decode", @"%@ failed: %@", copiedMethod, exception.name);
        }
        endSessionIfIdle();
    });
}

// --- собственные read-only вызовы, подписки и опрос ------------------------

// Each batch/context has its own identity. A reply to one GetItems batch cannot
// acknowledge a different batch, and passive subscription updates acknowledge none.
@interface SAPJournalRead : NSObject
@property(nonatomic,copy) NSString *identifier, *method;
@property(nonatomic,copy) NSData *payload;
@property(nonatomic,strong) id lifetime;
@property(nonatomic,strong) dispatch_source_t deadline;
@property(nonatomic) NSUInteger attempt;
@property(nonatomic) double sentAt;
@property(nonatomic,copy) NSString *verificationURI;
@property(nonatomic,copy) void (^verification)(NSDictionary *);
@end
@implementation SAPJournalRead @end
#ifdef SAP_TESTING
static const double answerTimeout=0.04;
#else
static const double answerTimeout=4;
#endif
static void releaseRead(SAPJournalRead *operation, BOOL cancel) {
    if(operation.deadline){dispatch_source_cancel(operation.deadline);operation.deadline=nil;}
    if(cancel && [operation.lifetime respondsToSelector:@selector(cancel)]) [operation.lifetime performSelector:@selector(cancel)];
    operation.lifetime=nil;
}
static void sendReadAttempt(SAPJournalRead *operation);
static void readTimedOut(SAPJournalRead *operation, NSUInteger attempt, NSString *reason) {
    if(outstanding[operation.identifier]!=operation || operation.attempt!=attempt)return;
    releaseRead(operation,YES);
    SAPJournalNoteCallIssue(operation.method,operation.verificationURI,attempt?@"bridge":@"preferred",reason);
    journalLog(@"silent", @"id=%@ %@ bytes=%lu attempt=%lu %@", operation.identifier,operation.method,
        (unsigned long)operation.payload.length,(unsigned long)attempt+1,reason);
    if(attempt<3) { operation.attempt++;sendReadAttempt(operation);return; }
    os_unfair_lock_lock(&lock);
    [outstanding removeObjectForKey:operation.identifier];
    if(SAPDiagnosticsEnabled())[unanswered addObject:@{@"id":operation.identifier,@"method":operation.method,@"bytes":@(operation.payload.length),
        @"attempts":@4,@"reason":reason,@"at":stamp(rightNow())?:@0,
        @"requested_uris":stringList(SAPProtoFields(operation.payload),[operation.method isEqual:@"GetContexts"]?3:1)}];
    trimEvents(unanswered,maximumEvents);
    os_unfair_lock_unlock(&lock);
    void (^completion)(NSDictionary *)=operation.verification;operation.verification=nil;
    if(completion)dispatch_async(dispatch_get_main_queue(),^{completion(nil);});
}
static void sendReadAttempt(SAPJournalRead *operation) {
    NSUInteger attempt=operation.attempt;operation.sentAt=rightNow();
    journalLog(@"call", @"id=%@ %@ sent bytes=%lu route=%@",operation.identifier,operation.method,
        (unsigned long)operation.payload.length,attempt?@"bridge":@"preferred");
    id lifetime=nil;
    @try {
        lifetime=caller(operation.method,operation.payload,NO,attempt,^(NSData *data){
            onJournal(^{
                if(outstanding[operation.identifier]!=operation || operation.attempt!=attempt)return;
                if(![data isKindOfClass:NSData.class] || data.length>4*1024*1024 || !SAPProtoFields(data)) {
                    readTimedOut(operation,attempt,@"invalid or missing reply");return;
                }
                os_unfair_lock_lock(&lock);[outstanding removeObjectForKey:operation.identifier];os_unfair_lock_unlock(&lock);
                releaseRead(operation,NO);
                journalLog(@"reply", @"id=%@ %@ bytes=%lu route=%@",operation.identifier,operation.method,
                    (unsigned long)data.length,attempt?@"bridge":@"preferred");
                decodeCall(operation.method,operation.payload,data,attempt?@"probe:bridge":@"probe:preferred");
                void (^completion)(NSDictionary *)=operation.verification;operation.verification=nil;
                if(completion) {
                    NSDictionary *result=nil;
                    for(NSArray *item in subMessages(SAPProtoFields(data),1)) {
                        if(![SAPProtoString(item,1) isEqual:operation.verificationURI])continue;
                        NSUInteger state=SAPProtoNumber(item,2,0);
                        result=@{@"uri":operation.verificationURI,@"state":SAPJournalItemStateName(state),
                            @"state_code":@(state),@"progress":@(SAPProtoNumber(item,4,0)),@"source":@"manual:GetItems"};
                        if(SAPDiagnosticsEnabled()) {
                            os_unfair_lock_lock(&lock);SAPTrack *record=tracks[operation.verificationURI];
                            if(record)result=trackDictionary(record,rightNow());os_unfair_lock_unlock(&lock);
                        }
                        break;
                    }
                    dispatch_async(dispatch_get_main_queue(),^{completion(result);});
                }
                endSessionIfIdle();
            });
        });
    } @catch(NSException *exception) { readTimedOut(operation,attempt,exception.name);return; }
    // A synchronous invalid callback can queue a retry; only this attempt owns its handle.
    if(outstanding[operation.identifier]==operation && operation.attempt==attempt)operation.lifetime=lifetime;
    operation.deadline=SAPScheduleDeadline(journal,answerTimeout,^{
        readTimedOut(operation,attempt,@"no response before timeout");
    });
}
static SAPJournalRead *send(NSString *method, NSData *payload, BOOL stream) {
    if(!caller)return nil;
    NSData *body=payload?:NSData.data;
    if(stream) {
        NSUInteger expected=subscriptionGeneration;
        id lifetime=caller(method,body,YES,0,^(NSData *data){
            onJournal(^{
                if(expected!=subscriptionGeneration || !subscribed)return;
                if([data isKindOfClass:NSData.class] && data.length<=4*1024*1024)decodeCall(method,body,data,@"probe:stream");
            });
        });
        if(lifetime)[lifetimes addObject:lifetime];
        return nil;
    }
    // Coalesce identical pending reads, but retain separate operations for different payloads.
    for(SAPJournalRead *pending in outstanding.allValues)
        if([pending.method isEqual:method] && [pending.payload isEqual:body])return pending;
    if(outstanding.count>=64) {journalLog(@"call",@"%@ skipped: pending read limit",method);return nil;}
    SAPJournalRead *operation=[SAPJournalRead new];operation.identifier=NSUUID.UUID.UUIDString;
    operation.method=method;operation.payload=body;
    os_unfair_lock_lock(&lock);outstanding[operation.identifier]=operation;os_unfair_lock_unlock(&lock);
    sendReadAttempt(operation);return operation;
}
void SAPJournalVerifyTrack(NSString *uri,void (^completion)(NSDictionary *)) {
    if(![uri hasPrefix:@"spotify:track:"] || uri.length>256) {
        if(completion)completion(nil);return;
    }
    onJournal(^{
        if(SAPDiagnosticsEnabled()){os_unfair_lock_lock(&lock);focusedURI=[uri copy];os_unfair_lock_unlock(&lock);}
        SAPJournalRead *operation=send(@"GetItems",SAPProtoBytes(1,[uri dataUsingEncoding:NSUTF8StringEncoding]),NO);
        if(operation) {operation.verificationURI=uri;operation.verification=completion;}
        else if(completion)dispatch_async(dispatch_get_main_queue(),^{completion(nil);});
    });
}
void SAPJournalNoteCallIssue(NSString *method,NSString *uri,NSString *channel,NSString *issue) {
    if(!SAPDiagnosticsEnabled())return;
    onJournal(^{
        if(!SAPDiagnosticsEnabled())return;
        os_unfair_lock_lock(&lock);
        [transportEvents addObject:@{@"method":method?:@"",@"uri":uri?:@"",@"channel":channel?:@"",@"issue":issue?:@"",@"at":stamp(rightNow())?:@0}];
        trimEvents(transportEvents,maximumEvents);os_unfair_lock_unlock(&lock);
        journalLog(@"transport",@"%@ uri=%@ channel=%@ %@",method?:@"",uri?:@"",channel?:@"",issue?:@"");
    });
}
static NSMutableDictionary *reconciliationTimes;
static void requestReconciliation(NSString *uri) {
    if(!SAPDiagnosticsEnabled())return;
    if(!caller || ![uri hasPrefix:@"spotify:track:"])return;
    if(!reconciliationTimes)reconciliationTimes=[NSMutableDictionary dictionary];
    if(rightNow()-[reconciliationTimes[uri] doubleValue]<10)return;
    if(reconciliationTimes.count>=maximumTracks)[reconciliationTimes removeAllObjects];
    reconciliationTimes[uri]=@(rightNow());
    send(@"GetItems",SAPProtoBytes(1,[uri dataUsingEncoding:NSUTF8StringEncoding]),NO);
}
static void cancelLifetimes(void) {
    SAPNativeErrorLogSetActive(NO);
    SAPPlayerTraceSetActive(NO);
    playerTraceSessionGeneration++;
    for (id lifetime in [lifetimes copy]) if ([lifetime respondsToSelector:@selector(cancel)]) [lifetime performSelector:@selector(cancel)];
    [lifetimes removeAllObjects]; subscribed = NO;subscriptionGeneration++;
    for(SAPJournalRead *operation in [outstanding.allValues copy]) {
        // A user-requested one-track verification works without diagnostics.
        if(operation.verificationURI)continue;
        releaseRead(operation,YES);
        os_unfair_lock_lock(&lock);[outstanding removeObjectForKey:operation.identifier];os_unfair_lock_unlock(&lock);
    }
}
static NSData *uriListRequest(unsigned number, NSArray<NSString *> *uris) {
    NSMutableData *payload = [NSMutableData data];
    for (NSString *uri in uris) [payload appendData:SAPProtoBytes(number, [uri dataUsingEncoding:NSUTF8StringEncoding])];
    return payload;
}
// GetContextsRequest: policy.items(1.1) = true, uris(3).
static NSData *contextRequest(NSArray<NSString *> *uris) {
    NSMutableData *payload = [SAPProtoBytes(1, SAPProtoInteger(1, 1)) mutableCopy];
    [payload appendData:uriListRequest(3, uris)];
    return payload;
}
static NSArray<NSString *> *entityList(NSUInteger limit) {
    os_unfair_lock_lock(&lock);
    NSArray *keys = [entities.allKeys sortedArrayUsingSelector:@selector(compare:)];
    os_unfair_lock_unlock(&lock);
    return keys.count > limit ? [keys subarrayWithRange:NSMakeRange(0, limit)] : keys;
}
// Сначала то, что ещё не доехало: незавершённые, затем сбойные, затем невиданные.
static NSArray<NSString *> *urisToQuery(void) {
    NSMutableArray *pending = [NSMutableArray array], *failed = [NSMutableArray array], *rest = [NSMutableArray array];
    os_unfair_lock_lock(&lock);
    for (SAPTrack *record in tracks.allValues) {
        if (!record->seen || pendingState(record->state)) [pending addObject:record->uri];
        else if (failedState(record->state) || record->state == 0) [failed addObject:record->uri];
        else [rest addObject:record->uri];
    }
    os_unfair_lock_unlock(&lock);
    NSMutableArray *result = [pending mutableCopy];
    [result addObjectsFromArray:failed]; [result addObjectsFromArray:rest];
    NSUInteger limit = chunkSize * maximumChunks;
    return result.count > limit ? [result subarrayWithRange:NSMakeRange(0, limit)] : result;
}
static void refreshItems(void) {
    NSArray *uris = urisToQuery();
    for (NSUInteger start = 0; start < uris.count; start += chunkSize) {
        NSRange range = NSMakeRange(start, MIN(chunkSize, uris.count - start));
        send(@"GetItems", uriListRequest(1, [uris subarrayWithRange:range]), NO);
    }
}
static void refreshContexts(void) {
    NSArray *list = entityList(8);
    if (!list.count) return;
    for (NSString *entity in list) send(@"GetContexts", contextRequest(@[entity]), NO);
    send(@"GetContextsProgress", uriListRequest(1, list), NO);
}
static void refreshSnapshots(void) {
    send(@"GetTotalProgress", NSData.data, NO);
    send(@"LicenseStatus", NSData.data, NO);
    send(@"BulkRedownloadPreflight", NSData.data, NO);
    send(@"GetOfflinePlaybackStatus", NSData.data, NO);
}
static void startSubscriptions(void) {
    if (!SAPDiagnosticsEnabled() || subscribed || !caller) return;
    subscribed = YES;
    send(@"SubscribeError", NSData.data, YES);
    send(@"SubscribeTotalProgress", NSData.data, YES);
    send(@"SubscribeContextAdded", NSData.data, YES);
    NSArray *list = entityList(4);
    if (list.count) send(@"SubscribeContexts", contextRequest(list), YES);
}
static void stopPolling(void) { if (pollTimer) { dispatch_source_cancel(pollTimer); pollTimer = nil; } }
static void diagnosticsChanged(void) {
    onJournal(^{
        if(SAPDiagnosticsEnabled()) {SAPJournalRefresh(@"diagnostics enabled");return;}
        stopPolling();cancelLifetimes();
        os_unfair_lock_lock(&lock);
        if(session) {
            session[@"stopped_reason"]=@"diagnostics disabled";session[@"finished_at"]=stamp(rightNow());
            [session removeObjectForKey:@"started_absolute"];
            [sessionHistory addObject:[session copy]];trimEvents(sessionHistory,4);session=nil;
        }
        os_unfair_lock_unlock(&lock);
        if(logStream){fclose(logStream);logStream=NULL;}
        lastRefresh=0;lastQuotaSample=0;
    });
}
static void poll(void);
static void startPolling(void) {
    if (!SAPDiagnosticsEnabled() || pollTimer) return;
    pollTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, journal);
    dispatch_source_set_timer(pollTimer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(pollInterval * NSEC_PER_SEC)),
        (uint64_t)(pollInterval * NSEC_PER_SEC), NSEC_PER_SEC / 2);
    dispatch_source_set_event_handler(pollTimer, ^{ poll(); });
    dispatch_resume(pollTimer);
}

static NSDictionary *stateCountsLocked(NSUInteger *pendingOut) { // под stateLock
    NSMutableDictionary *counts = [NSMutableDictionary dictionary];
    NSUInteger pending = 0;
    for (SAPTrack *record in tracks.allValues) {
        NSString *name = record->seen ? SAPJournalItemStateName(record->state) : @"unseen";
        counts[name] = @([counts[name] unsignedIntegerValue] + 1);
        if (record->seen && pendingState(record->state)) pending++;
    }
    if (pendingOut) *pendingOut = pending;
    return counts;
}
static NSDictionary *stateCounts(NSUInteger *pendingOut) {
    os_unfair_lock_lock(&lock);
    NSDictionary *counts = stateCountsLocked(pendingOut);
    os_unfair_lock_unlock(&lock);
    return counts;
}
static void beginSession(NSString *reason, NSString *entity) {
    if(!SAPDiagnosticsEnabled())return;
    if (session) {
        os_unfair_lock_lock(&lock);
        if (entity.length) session[@"entity"] = entity;
        session[@"last_activity"] = stamp(rightNow());
        os_unfair_lock_unlock(&lock);
        startSubscriptions(); startPolling();
        return;
    }
    double moment = rightNow();
    NSMutableDictionary *started = [@{@"reason": reason ?: @"", @"started_at": stamp(moment) ?: @0,
        @"last_activity": stamp(moment) ?: @0, @"started_absolute": @(moment)} mutableCopy];
    if (entity.length) started[@"entity"] = entity;
    os_unfair_lock_lock(&lock); session = started; os_unfair_lock_unlock(&lock);
    NSLog(@"[SpotifyAudioProbe] download session started (%@%@%@)", reason ?: @"", entity.length ? @", " : @"", entity ?: @"");
    journalLog(@"session", @"started reason=%@ entity=%@ tracked=%lu", reason ?: @"", entity ?: @"-", (unsigned long)tracks.count);
    SAPNativeErrorLogSetActive(YES);
    NSUInteger traceSession=++playerTraceSessionGeneration;
    SAPPlayerTraceSetSink(^(NSDictionary *event){
        if(atomic_fetch_add(&playerTraceSinkPending,1)>=16){
            atomic_fetch_sub(&playerTraceSinkPending,1);atomic_fetch_add(&playerTraceSinkDropped,1);return;
        }
        onJournal(^{
            @try {
                if(!session || playerTraceSessionGeneration!=traceSession)return;
                NSData *json=[NSJSONSerialization dataWithJSONObject:event options:NSJSONWritingSortedKeys error:NULL];
                if(json)journalWrite(@"player",[[NSString alloc]initWithData:json encoding:NSUTF8StringEncoding]);
            } @finally {atomic_fetch_sub(&playerTraceSinkPending,1);}
        });
    });
    SAPPlayerTraceSetActive(YES);
    startSubscriptions(); startPolling();
    refreshSnapshots(); refreshContexts(); refreshItems();sampleQuota();
}
static void endSessionIfIdle(void) {
    if (!session) return;
    NSUInteger pending = 0; NSDictionary *counts = stateCounts(&pending);
    double moment = rightNow();
    if (pending) {
        os_unfair_lock_lock(&lock);
        session[@"last_activity"] = stamp(moment);
        session[@"peak_pending"] = @(MAX(pending, [session[@"peak_pending"] unsignedIntegerValue]));
        os_unfair_lock_unlock(&lock);
        return;
    }
    double last = [session[@"last_activity"] doubleValue] - kCFAbsoluteTimeIntervalSince1970;
    if (moment - last < sessionIdleTimeout) return;
    os_unfair_lock_lock(&lock);
    session[@"finished_at"] = stamp(moment);
    session[@"duration_seconds"] = @(round(moment - [session[@"started_absolute"] doubleValue]));
    session[@"final_counts"] = counts;
    [session removeObjectForKey:@"started_absolute"];
    [sessionHistory addObject:[session copy]]; trimEvents(sessionHistory, 4);
    os_unfair_lock_unlock(&lock);
    NSLog(@"[SpotifyAudioProbe] download session finished: %@", counts);
    journalLog(@"session", @"finished after %@s counts=%@", session[@"duration_seconds"], counts);
    os_unfair_lock_lock(&lock); session = nil; os_unfair_lock_unlock(&lock);
    stopPolling(); cancelLifetimes();
}
static void poll(void) {
    if(!SAPDiagnosticsEnabled()){stopPolling();cancelLifetimes();return;}
    if (!session) { stopPolling(); return; }
    double started = [session[@"started_absolute"] doubleValue];
    if (started > 0 && rightNow() - started > maximumSessionSeconds) {
        journalLog(@"session", @"stopped after %.0fs polling limit", rightNow() - started);
        os_unfair_lock_lock(&lock);
        session[@"stopped_reason"] = @"polling limit reached";
        session[@"finished_at"] = stamp(rightNow());
        session[@"final_counts"] = stateCountsLocked(NULL);
        [session removeObjectForKey:@"started_absolute"];
        [sessionHistory addObject:[session copy]]; trimEvents(sessionHistory, 4);
        session = nil;
        os_unfair_lock_unlock(&lock);
        stopPolling(); cancelLifetimes();
        return;
    }
    pollTicks++;
    refreshItems();
    if (pollTicks % 2 == 0) { refreshContexts(); send(@"GetTotalProgress", NSData.data, NO); }
    if (pollTicks % 6 == 0) { refreshSnapshots(); if (quotaSampler) quotaSampler(); }
    endSessionIfIdle();
}
void SAPJournalSetQuotaSampler(void (^sampler)(void)) {
    void (^copied)(void) = [sampler copy];
    onJournal(^{ quotaSampler = copied; });
}
void SAPJournalSetCaller(SAPJournalCaller value) {
    SAPJournalCaller copied = [value copy];
    onJournal(^{
        caller = copied; atomic_store(&callerAvailable, copied != nil);
        journalLog(@"call", @"core channel %@", copied ? @"available" : @"cleared");
        if (session) { startSubscriptions(); startPolling(); }
    });
}
void SAPJournalRefresh(NSString *reason) {
    if(!SAPDiagnosticsEnabled())return;
    onJournal(^{
        if(!SAPDiagnosticsEnabled())return;
        double moment = rightNow();
        if (moment - lastRefresh < refreshThrottle) return;
        lastRefresh = moment;
        beginSession(reason?:@"manual refresh",nil);
        refreshSnapshots(); refreshContexts(); refreshItems();sampleQuota();
        if (reason.length) { NSLog(@"[SpotifyAudioProbe] journal refresh (%@)", reason); journalLog(@"refresh", @"%@", reason); }
    });
}
void SAPJournalReset(void) {
    onJournal(^{
        os_unfair_lock_lock(&lock);
        [tracks removeAllObjects]; [transitions removeAllObjects]; [errorEvents removeAllObjects];
        [contextAddedEvents removeAllObjects]; [entityEvents removeAllObjects]; [entities removeAllObjects];
        [snapshots removeAllObjects]; [methodCalls removeAllObjects]; [totalProgressSamples removeAllObjects];
        [sessionHistory removeAllObjects]; [unanswered removeAllObjects];[transportEvents removeAllObjects];focusedURI=nil;
        totalProgress = nil; journalStarted = rightNow();
        os_unfair_lock_unlock(&lock);
        session = nil; pollTicks = 0;lastQuotaSample=0; stopPolling(); cancelLifetimes();[reconciliationTimes removeAllObjects];
        SAPPlayerTraceReset();
        if(SAPTraceIsActive())SAPPlayerTraceSetActive(YES);
        NSLog(@"[SpotifyAudioProbe] journal reset");
        journalWrite(@"reset", @"journal cleared by user");
    });
}

// --- отчёты ---------------------------------------------------------------

static NSString *uiStatusName(NSInteger status) {
    switch (status) {
        case 0: return @"not_synced"; case 1: return @"pending"; case 2: return @"in_progress";
        case 3: return @"synced"; case 4: return @"failed"; default: return @"unknown";
    }
}
// Порядок в отчёте: сначала то, что сломалось, потом то, что висит, потом остальное.
static NSUInteger priorityOf(SAPTrack *record) {
    if (!record->seen) return 3;
    if (failedState(record->state)) return 0;
    if (record->state == 0 || record->state == 2) return 1;
    if (pendingState(record->state)) return 2;
    return 4;
}
static NSDictionary *trackDictionary(SAPTrack *record, double moment) { // под stateLock
    NSString *state = record->seen ? SAPJournalItemStateName(record->state) : @"unseen";
    double inState = record->enteredState > 0 ? moment - record->enteredState : 0;
    BOOL stalled = record->seen && pendingState(record->state) &&
        (record->lastProgressAt > 0 ? moment - record->lastProgressAt : inState) > stalledAfter;
    NSMutableDictionary *value = [@{
        @"uri": record->uri ?: @"", @"id": shortIdentifier(record->uri) ?: @"",
        @"state": state, @"state_code": @(record->state), @"progress": @(record->progress),
        @"max_progress": @(record->maxProgress), @"in_state_seconds": @(round(inState)),
        @"stalled": @(stalled), @"observations": @(record->observations), @"row_queries": @(record->rowQueries),
        @"add_requests": @(record->addRequests), @"remove_requests": @(record->removeRequests),
        @"transitions": [record->history copy], @"time_in_state": [record->timeInState copy],
        @"source": record->lastSource ?: @""} mutableCopy];
    if (record->videoState) value[@"video_state"] = SAPJournalItemStateName(record->videoState);
    if (record->entity) value[@"entity"] = record->entity;
    if (record->requestError) {
        value[@"add_response"] = record->requestError;
        value[@"add_response_name"] = errorName(record->requestError.unsignedLongLongValue);
    }
    if (record->requestedAt) value[@"requested_age_seconds"] = age(record->requestedAt) ?: @0;
    if (record->firstSeen) value[@"first_seen_age_seconds"] = age(record->firstSeen) ?: @0;
    if (record->lastChange) value[@"last_change_age_seconds"] = age(record->lastChange) ?: @0;
    if (record->lastProgressAt) value[@"last_progress_age_seconds"] = age(record->lastProgressAt) ?: @0;
    if(record->legacyState>=0) {
        value[@"legacy_state_code"]=@(record->legacyState);value[@"legacy_state"]=uiStatusName(record->legacyState);
        value[@"legacy_age_seconds"]=age(record->legacyAt)?:@0;
    }
    if(record->wireAt)value[@"wire_age_seconds"]=age(record->wireAt)?:@0;
    if(record->uiStatus>=0 && record->seen) {
        value[@"ui_downloaded_matches_wire"]=@((record->uiStatus==3)==(record->state==3));
        value[@"comparison_note"]=@"UI and wire are timestamped observations, not an atomic snapshot";
    }
    if (record->uiStatus >= 0) {
        value[@"ui_status"] = uiStatusName(record->uiStatus);
        value[@"ui_status_code"] = @(record->uiStatus);value[@"ui_age_seconds"]=age(record->iconAt)?:@0;
    }
    if(record->nativeError) {
        value[@"native_error"]=record->nativeError;
        double errorAt=[record->nativeError[@"at"] doubleValue]-kCFAbsoluteTimeIntervalSince1970;
        value[@"key_received_after_native_error"]=@(record->nativeKeyAt>errorAt);
        value[@"downloaded_after_native_error"]=@((record->state==3 && record->wireAt>errorAt) || record->nativeDownloadAt>errorAt);
    }
    if(record->nativeEvents.count)value[@"native_events"]=[record->nativeEvents copy];
    if (record->errors.count) value[@"errors"] = [record->errors copy];
    return value;
}
NSDictionary *SAPJournalReport(void) {
    setup();
    double moment = rightNow();
    NSUInteger pending = 0;
    os_unfair_lock_lock(&lock);
    NSDictionary *counts = stateCountsLocked(&pending);
    NSArray *sorted = [tracks.allValues sortedArrayUsingComparator:^NSComparisonResult(SAPTrack *a, SAPTrack *b) {
        NSUInteger left = priorityOf(a), right = priorityOf(b);
        if (left != right) return left < right ? NSOrderedAscending : NSOrderedDescending;
        return a->lastChange > b->lastChange ? NSOrderedAscending : a->lastChange < b->lastChange ? NSOrderedDescending : NSOrderedSame;
    }];
    NSMutableArray *list = [NSMutableArray array];
    NSMutableArray *stalled = [NSMutableArray array];
    NSUInteger requested = 0, withAddError = 0;
    for (SAPTrack *record in sorted) {
        if (record->requestedAt) requested++;
        if (record->requestError.unsignedLongLongValue) withAddError++;
        if (list.count >= maximumReportedTracks) continue;
        NSDictionary *value = trackDictionary(record, moment);
        [list addObject:value];
        if ([value[@"stalled"] boolValue] && stalled.count < 40) [stalled addObject:value[@"uri"]];
    }
    NSDictionary *report = @{
        @"native_error_observer":SAPNativeErrorLogReport(),
        @"player_trace":SAPPlayerTraceReport(),
        @"player_trace_sink_dropped":@(atomic_load(&playerTraceSinkDropped)),
        @"diagnostics_enabled":@(SAPDiagnosticsEnabled()),
        @"journal_version": @6,@"focused_uri":focusedURI?:@"",@"transport_events":[transportEvents copy],
        @"action_events":[actionEvents copy],@"action_log_file":@"PixieActions.log",
        @"generated_at": stamp(moment) ?: @0,
        @"journal_age_seconds": @(round(moment - journalStarted)),
        @"caller_available": @(atomic_load(&callerAvailable)), @"subscribed": @(subscribed),
        @"tracked_tracks": @(tracks.count), @"reported_tracks": @(list.count),
        @"requested_tracks": @(requested), @"add_errors": @(withAddError),
        @"pending_tracks": @(pending), @"state_counts": counts,
        @"session": session ? [session copy] : @{}, @"session_history": [sessionHistory copy],
        @"entities": [[NSDictionary alloc] initWithDictionary:entities copyItems:YES], @"entity_events": [entityEvents copy],
        @"total_progress": totalProgress ?: @{}, @"total_progress_samples": [totalProgressSamples copy],
        @"snapshots": [snapshots copy], @"core_errors": [errorEvents copy],
        @"context_added": [contextAddedEvents copy], @"method_calls": [methodCalls copy],
        @"stalled_tracks": stalled, @"recent_transitions": [transitions copy],
        @"unanswered_calls": [unanswered copy], @"outstanding_calls": [[outstanding allKeys] copy],
        @"log_file": @"SpotifyAudioProbeJournal.log",
        @"tracks": list,
        @"note": SAPL(@"Error ядра офлайна не содержит URI (Error{code} — analysis/offline-esperanto-service.md), "
                 @"поэтому ошибка привязывается к треку по времени и помечается как correlated.",
                 @"Offline core errors contain no URI (Error{code}; see analysis/offline-esperanto-service.md), so errors are associated with tracks by timestamp and marked as correlated.")
    };
    os_unfair_lock_unlock(&lock);
    return report;
}
static NSString *durationText(double seconds) {
    if (seconds <= 0) return SAPL(@"0с",@"0s");
    unsigned total = (unsigned)round(seconds);
    if (total < 60) return [NSString stringWithFormat:SAPL(@"%uс",@"%us"), total];
    if (total < 3600) return [NSString stringWithFormat:SAPL(@"%uм %02uс",@"%um %02us"), total / 60, total % 60];
    return [NSString stringWithFormat:SAPL(@"%uч %02uм",@"%uh %02um"), total / 3600, (total / 60) % 60];
}
static NSString *bytesText(unsigned long long bytes) {
    if (bytes < 1024) return [NSString stringWithFormat:SAPL(@"%llu Б",@"%llu B"), bytes];
    if (bytes < 1024 * 1024) return [NSString stringWithFormat:SAPL(@"%.1f КБ",@"%.1f KB"), bytes / 1024.0];
    if (bytes < 1024ULL * 1024 * 1024) return [NSString stringWithFormat:SAPL(@"%.1f МБ",@"%.1f MB"), bytes / 1048576.0];
    return [NSString stringWithFormat:SAPL(@"%.2f ГБ",@"%.2f GB"), bytes / 1073741824.0];
}
NSString *SAPJournalSummaryText(void) {
    if(!SAPDiagnosticsEnabled())return SAPL(@"Диагностика выключена. Журнал не обновляется. Включи её в разделе «Диагностика», чтобы собрать состояние загрузок. Проверка текущего трека доступна отдельно.",@"Diagnostics are off. The log is not updated. Enable Diagnostics to collect download status. You can still check the current track separately.");
    return SAPJournalSummaryForReport(SAPJournalReport());
}
NSString *SAPJournalSummaryForReport(NSDictionary *report) {
    if(![report[@"diagnostics_enabled"] boolValue])return SAPL(@"Диагностика выключена. Журнал не обновляется. Включи её в разделе «Диагностика», чтобы собрать состояние загрузок. Проверка текущего трека доступна отдельно.",@"Diagnostics are off. The log is not updated. Enable Diagnostics to collect download status. You can still check the current track separately.");
    NSDictionary *counts = report[@"state_counts"], *progress = report[@"total_progress"];
    NSDictionary *license = report[@"snapshots"][@"license_status"], *preflight = report[@"snapshots"][@"bulk_preflight"];
    NSDictionary *quota = report[@"snapshots"][@"quota"], *playback = report[@"snapshots"][@"offline_playback"];
    NSMutableString *text = [NSMutableString string];
    NSDictionary *core=report[@"snapshots"][@"core_status"];
    if([core[@"code"]unsignedLongLongValue]) {
        [text appendFormat:@"Last offline-core response: %@ (%@), %@ ago. Source: in-process API; server origin unverified.\n",
            errorName([core[@"code"]unsignedLongLongValue]),core[@"code"],durationText([report[@"generated_at"]doubleValue]-[core[@"at"]doubleValue])];
    }
    if(playback.count && ![playback[@"allowed"]boolValue])
        [text appendFormat:@"Last Spotify offline playback response: NOT ALLOWED, %@ ago. Local quota changes do not confirm authorization.\n",
            durationText([report[@"generated_at"]doubleValue]-[playback[@"at"]doubleValue])];
    [text appendFormat:SAPL(@"Треков в журнале: %@ · запрошено: %@\n",@"Tracks in log: %@ · requested: %@\n"), report[@"tracked_tracks"], report[@"requested_tracks"]];
    [text appendFormat:@"✅ %@ · ⏬ %@ · ⌛ %@ · ⏸ %@\n",
        counts[@"downloaded"] ?: @0, counts[@"downloading"] ?: @0, counts[@"waiting"] ?: @0, counts[@"awaiting_redownload"] ?: @0];
    [text appendFormat:SAPL(@"❌ error: %@ · 🚫 лимит: %@ · ⚪️ не скачан: %@ · ⏱ истёк: %@\n",@"❌ error: %@ · 🚫 limit: %@ · ⚪️ not downloaded: %@ · ⏱ expired: %@\n"),
        counts[@"error"] ?: @0, counts[@"waiting_limit_exceeded"] ?: @0, counts[@"not_downloaded"] ?: @0, counts[@"expired"] ?: @0];
    if ([report[@"stalled_tracks"] count]) [text appendFormat:SAPL(@"Застряли без прогресса: %lu\n",@"Stalled without progress: %lu\n"), (unsigned long)[report[@"stalled_tracks"] count]];
    if ([report[@"add_errors"] unsignedIntegerValue]) [text appendFormat:SAPL(@"AddDownload с ошибкой: %@\n",@"AddDownload errors: %@\n"), report[@"add_errors"]];
    if (progress.count) {
        [text appendFormat:SAPL(@"Очередь ядра: %@/%@ треков, %@ из %@, %@/с, осталось %@\n",@"Core queue: %@/%@ tracks, %@ of %@, %@/s, %@ remaining\n"),
            progress[@"downloaded_tracks"], progress[@"total_tracks"],
            bytesText([progress[@"downloaded_bytes"] unsignedLongLongValue]),
            bytesText([progress[@"total_bytes"] unsignedLongLongValue]),
            bytesText([progress[@"download_speed"] unsignedLongLongValue]),
            durationText([progress[@"seconds_left"] doubleValue])];
    }
    if (license.count) [text appendFormat:SAPL(@"Лицензии: свободно %@ из %@%@\n",@"Device licenses (last response): %@ of %@ free%@\n"), license[@"free_licenses"], license[@"max_licenses"],
        [license[@"error"] unsignedLongLongValue] ? [NSString stringWithFormat:@" (%@)", license[@"error_name"]] : @""];
    if (preflight.count) [text appendFormat:SAPL(@"Места хватает: %@ · сотовая сеть: %@ · грузится сейчас: %@\n",@"Enough storage: %@ · cellular: %@ · downloading now: %@\n"),
        [preflight[@"has_sufficient_storage"] boolValue] ? SAPL(@"да",@"yes") : SAPL(@"НЕТ",@"NO"),
        [preflight[@"is_on_cellular"] boolValue] ? ([preflight[@"sync_over_cellular_allowed"] boolValue] ? SAPL(@"разрешена",@"allowed") : SAPL(@"ЗАПРЕЩЕНА",@"BLOCKED")) : SAPL(@"не используется",@"not in use"),
        preflight[@"downloads_in_progress"]];
    if (quota.count) [text appendFormat:SAPL(@"Квота менеджера: %@/%@ треков\n",@"Local manager quota: %@/%@ tracks (does not confirm device licensing)\n"), quota[@"current_tracks"] ?: @"?", quota[@"music_limit"] ?: @"?"];
    if (playback.count) [text appendFormat:SAPL(@"Офлайн-воспроизведение: %@\n",@"Offline playback: %@\n"), [playback[@"allowed"] boolValue] ? SAPL(@"разрешено",@"allowed") : SAPL(@"ЗАПРЕЩЕНО",@"BLOCKED")];
    NSDictionary *lastError = [report[@"core_errors"] lastObject];
    if (lastError) [text appendFormat:SAPL(@"Последняя ошибка ядра: %@ (%@), %@ назад\n",@"Last core error: %@ (%@), %@ ago\n"), lastError[@"name"], lastError[@"code"],
        durationText([report[@"generated_at"] doubleValue] - [lastError[@"at"] doubleValue])];
    for (NSDictionary *entity in [report[@"entities"] allValues]) {
        [text appendFormat:SAPL(@"Плейлист %@: %@ %@%%%@\n",@"Playlist %@: %@ %@%%%@\n"), shortIdentifier(entity[@"uri"]), entity[@"state"] ?: @"?",
            entity[@"percent_complete"] ?: @0,
            entity[@"requested_tracks"] ? [NSString stringWithFormat:SAPL(@", запрошено %@",@", requested %@"), entity[@"requested_tracks"]] : @""];
    }
    NSArray *problems = report[@"tracks"];
    NSUInteger shown = 0;
    for (NSDictionary *track in problems) {
        if (shown >= 6) break;
        NSString *state = track[@"state"];
        if (![state isEqual:@"error"] && ![state isEqual:@"waiting_limit_exceeded"] && ![track[@"stalled"] boolValue]) continue;
        if (!shown) [text appendString:SAPL(@"\nПроблемные треки:\n",@"\nTracks with issues:\n")];
        [text appendFormat:SAPL(@"• %@ — %@ %@%%, в состоянии %@%@\n",@"• %@ — %@ %@%%, in this state for %@%@\n"), track[@"id"], state, track[@"progress"],
            durationText([track[@"in_state_seconds"] doubleValue]),
            track[@"native_error"] ? [NSString stringWithFormat:@", %@ (%@)",track[@"native_error"][@"name"],track[@"native_error"][@"code"]?:@"code unavailable"] :
                track[@"add_response_name"] && ![track[@"add_response_name"] isEqual:@"SUCCESS"] ?
                [NSString stringWithFormat:@", AddDownload: %@", track[@"add_response_name"]] : @""];
        shown++;
    }
    if (!report[@"caller_available"] || ![report[@"caller_available"] boolValue])
        [text appendString:SAPL(@"\nКанал к ядру ещё не получен: запусти воспроизведение, чтобы журнал мог опрашивать состояние сам.\n",@"\nThe core transport is not available yet: start playback so the log can query the status.\n")];
    return text;
}
static NSString *tableText(NSDictionary *report) {
    NSMutableString *text = [NSMutableString string];
    [text appendFormat:SAPL(@"SpotifyAudioProbe — состояние офлайн-загрузки, %@\n",@"SpotifyAudioProbe — offline download status, %@\n"), [NSDate dateWithTimeIntervalSince1970:[report[@"generated_at"] doubleValue]]];
    [text appendString:SAPJournalSummaryForReport(report)];
    [text appendString:@"\n"];
    [text appendFormat:@"%-24s %-22s %5s %8s %6s %s\n", [SAPL(@"ТРЕК",@"TRACK") UTF8String], [SAPL(@"СОСТОЯНИЕ",@"STATE") UTF8String], "%", [SAPL(@"В СОСТ.",@"IN STATE") UTF8String], "UI", [SAPL(@"ПЕРЕХОДЫ",@"TRANSITIONS") UTF8String]];
    for (NSDictionary *track in report[@"tracks"]) {
        NSMutableArray *path = [NSMutableArray array];
        for (NSDictionary *step in track[@"transitions"]) [path addObject:step[@"to"]];
        NSString *chain = [path componentsJoinedByString:@" → "];
        if (!chain.length) chain = @"—";
        [text appendFormat:@"%-24s %-22s %5lu %8s %6s %@%@\n",
            [track[@"id"] UTF8String], [track[@"state"] UTF8String],
            (unsigned long)[track[@"progress"] unsignedIntegerValue],
            [durationText([track[@"in_state_seconds"] doubleValue]) UTF8String],
            [(track[@"ui_status"] ?: @"—") UTF8String], chain,
            track[@"add_response_name"] && ![track[@"add_response_name"] isEqual:@"SUCCESS"] ?
                [NSString stringWithFormat:@"  AddDownload=%@", track[@"add_response_name"]] : @""];
    }
    [text appendString:SAPL(@"\nПереходы (последние):\n",@"\nRecent transitions:\n")];
    for (NSDictionary *step in report[@"recent_transitions"])
        [text appendFormat:@"%@  %@  %@ → %@  %@%%  %@\n", step[@"at"], shortIdentifier(step[@"track_uri"]),
            step[@"from"], step[@"to"], step[@"progress"], step[@"source"]];
    [text appendString:SAPL(@"\nОшибки ядра:\n",@"\nCore errors:\n")];
    for (NSDictionary *event in report[@"core_errors"])
        [text appendFormat:@"%@  %@ (%@)\n", event[@"at"], event[@"name"], event[@"code"]];
    return text;
}
static NSURL *documentsURL(NSString *name) {
#ifdef SAP_TESTING
    // На хосте журнал не трогает ~/Documents пользователя.
    return [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
#else
    NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    return [documents URLByAppendingPathComponent:name];
#endif
}
NSURL *SAPJournalWriteReport(void) {return SAPJournalWriteReportSnapshot(SAPJournalReport());}
NSURL *SAPJournalWriteReportSnapshot(NSDictionary *report) {
    NSURL *url = documentsURL(@"SpotifyAudioProbeTracks.json");
    NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:NULL];
    return json && [json writeToURL:url atomically:YES] ? url : nil;
}
NSURL *SAPJournalWriteTable(void) {return SAPJournalWriteTableSnapshot(SAPJournalReport());}
NSURL *SAPJournalWriteTableSnapshot(NSDictionary *report) {
    NSURL *url = documentsURL(@"SpotifyAudioProbeTracks.txt");
    NSData *data = [tableText(report) dataUsingEncoding:NSUTF8StringEncoding];
    return data && [data writeToURL:url atomically:YES] ? url : nil;
}
#ifdef SAP_TESTING
void SAPJournalTimeoutsForTesting(void) {
    setup();dispatch_sync(journal,^{
        for(SAPJournalRead *operation in [outstanding.allValues copy])readTimedOut(operation,operation.attempt,@"test timeout");
    });
}
void SAPJournalDrainForTesting(void) { setup(); dispatch_sync(journal, ^{}); }
#endif
