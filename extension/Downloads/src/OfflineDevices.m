#import "OfflineDevices.h"
#import "DownloadCompatibility.h"
#import "TrackDownload.h"
#import "TrackJournal.h"
#import "WireProto.h"
#import "Deadline.h"
#import "DiagnosticTrace.h"
#import <dlfcn.h>

// Route fragments and POST are verified in the supplied Spotify 9.1.90:
// device path 0x105458100, /disable 0x101d0346c, caller 0x10224bd78.
// No local LicenseStatus response or device identifier is rewritten.
static NSDictionary *lastPlan;
static BOOL slotOperationActive;
#ifdef SAP_TESTING
static Class testProtocol;
static void (^testHeaders)(void (^)(NSDictionary *));
void SAPOfflineDevicesTestEnvironment(Class protocolClass,void (^provider)(void (^)(NSDictionary *))) {
    testProtocol=protocolClass;testHeaders=[provider copy];
}
#endif
@interface SAPSlotRequest : NSObject <NSURLSessionTaskDelegate>
@property(nonatomic,strong) NSURLSession *session;
@property(nonatomic,strong) NSDictionary *headers,*native,*plan;
@property(nonatomic,strong) dispatch_source_t deadline;
@property(nonatomic,copy) void (^completion)(NSDictionary *,NSString *);
@property(nonatomic) BOOL finished;
@property(nonatomic,strong) NSMutableArray *released;
@property(nonatomic,strong) NSArray *selected;
@property(nonatomic) NSUInteger index;
@property(nonatomic) SAPTraceID traceOperation;
- (void)finish:(NSDictionary *)result error:(NSString *)error;
- (void)request:(NSString *)path method:(NSString *)method completion:(void (^)(NSData *,NSInteger,NSString *))reply;
@end
static NSMutableSet<SAPSlotRequest *> *slotRequests;
@implementation SAPSlotRequest
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler {
    // These fixed account-management routes must not forward credentials or a
    // POST to an unreviewed redirect, even on another Spotify hostname.
    completionHandler(nil);
}
- (void)finish:(NSDictionary *)result error:(NSString *)error {
    if(self.finished)return;self.finished=YES;
    if(self.deadline){dispatch_source_cancel(self.deadline);self.deadline=nil;}
    [self.session invalidateAndCancel];self.session=nil;self.headers=nil;
    slotOperationActive=NO;
    SAP_TRACE("offline_devices","operation_finished",self.traceOperation,@{@"error":error?:@"",@"result":result?:@{},@"released_cache_ids":self.released?:@[]});
    SAPJournalNoteAction(@"offline_slot_operation_finished",@{@"error":error?:@"",@"result":result?:@{},@"released_cache_ids":self.released?:@[]});
    void (^done)(NSDictionary *,NSString *)=self.completion;self.completion=nil;
    [slotRequests removeObject:self];if(done)done(result,error);
}
- (void)request:(NSString *)path method:(NSString *)method completion:(void (^)(NSData *,NSInteger,NSString *))reply {
    if(self.finished)return;
    NSURL *url=[NSURL URLWithString:[@"https://spclient.wg.spotify.com/"stringByAppendingString:path]];
    if(![url.host isEqual:@"spclient.wg.spotify.com"] || ![url.scheme isEqual:@"https"]){reply(nil,0,@"Invalid management URL");return;}
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:12];
    request.HTTPMethod=method;
    [self.headers enumerateKeysAndObjectsUsingBlock:^(id key,id value,BOOL *stop){
        if([key isKindOfClass:NSString.class]&&[value isKindOfClass:NSString.class])[request setValue:value forHTTPHeaderField:key];
    }];
    [request setValue:@"application/x-protobuf" forHTTPHeaderField:@"Accept"];
    [request setValue:@"no-cache" forHTTPHeaderField:@"Cache-Control"];
    if([method isEqual:@"POST"]){request.HTTPBody=NSData.data;[request setValue:@"application/x-protobuf" forHTTPHeaderField:@"Content-Type"];}
    SAPJournalNoteAction(@"offline_slot_http_sent",@{@"method":method,@"path":path});
    __block SAPTraceID trace=0;
    SAPTraceWithOperation(self.traceOperation,^{if(SAPTraceIsActive())trace=SAPTraceBegin(@"management_https_request",@"pixie",@{@"method":method,@"host":@"spclient.wg.spotify.com",@"path":path,@"mutating":@([method isEqual:@"POST"]),@"automatic_replay":@NO});});
    __weak SAPSlotRequest *weakSelf=self;
    [[self.session dataTaskWithRequest:request completionHandler:^(NSData *data,NSURLResponse *response,NSError *error){
        dispatch_async(dispatch_get_main_queue(),^{
            SAPSlotRequest *self=weakSelf;if(!self||self.finished)return;
            NSInteger status=[response isKindOfClass:NSHTTPURLResponse.class]?[(NSHTTPURLResponse *)response statusCode]:0;
            SAPJournalNoteAction(@"offline_slot_http_reply",@{@"method":method,@"path":path,@"http_status":@(status),@"bytes":@(data.length),@"error_domain":error.domain?:@"",@"error_code":@(error.code)});
            SAP_TRACE("http","management_completion",trace,@{@"http_status":@(status),@"bytes":@(data.length),@"error_domain":error.domain?:@"",@"error_code":@(error.code),@"authenticated_headers_logged":@NO});
            if(error || status<200 || status>=300 || data.length>8*1024*1024) {
                reply(nil,status,[NSString stringWithFormat:@"Spotify management request %@ returned HTTP %ld (%@). No success inferred.",method,(long)status,error.localizedDescription?:@"no transport error"]);return;
            }
            reply(data?:NSData.data,status,nil);
        });
    }]resume];
}
@end

static SAPSlotRequest *beginSlots(void (^completion)(NSDictionary *,NSString *)) {
    if(slotOperationActive){if(completion)completion(nil,@"Another offline-device operation is in progress.");return nil;}
    slotOperationActive=YES;
    SAPSlotRequest *op=[SAPSlotRequest new];op.completion=completion;op.released=[NSMutableArray array];
    op.traceOperation=SAPTraceCurrentOperation();if(!op.traceOperation&&SAPTraceIsActive())op.traceOperation=SAPTraceBegin(@"offline_device_management",@"pixie_ui",@{});
    if(!slotRequests)slotRequests=[NSMutableSet set];[slotRequests addObject:op];
    NSURLSessionConfiguration *configuration=NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.URLCache=nil;configuration.HTTPCookieStorage=nil;configuration.HTTPShouldSetCookies=NO;
#ifdef SAP_TESTING
    if(testProtocol)configuration.protocolClasses=@[testProtocol];
#endif
    op.session=[NSURLSession sessionWithConfiguration:configuration delegate:op delegateQueue:nil];
    __weak SAPSlotRequest *weakOp=op;
    op.deadline=SAPScheduleDeadline(dispatch_get_main_queue(),60,^{
        SAPSlotRequest *op=weakOp;if(op)[op finish:@{@"released_cache_ids":op.released?:@[],@"status":@"unconfirmed"} error:@"Offline-device operation timed out. No command is automatically retried; refresh to see the actual state."];
    });
    return op;
}
static void withHeaders(SAPSlotRequest *op,void (^ready)(SAPSlotRequest *)) {
    SAP_TRACE("offline_devices","waiting_for_existing_authentication",op.traceOperation,@{@"credentials_logged":@NO});
    __weak SAPSlotRequest *weakOp=op;
    void (^received)(NSDictionary *)=^(NSDictionary *headers){
        dispatch_async(dispatch_get_main_queue(),^{
            SAPSlotRequest *op=weakOp;if(!op||op.finished||op.headers)return;
            NSMutableDictionary *allowed=[NSMutableDictionary dictionary];
            NSSet *names=[NSSet setWithArray:@[@"authorization",@"client-token",@"spotify-app-version",@"app-platform",@"user-agent"]];
            for(id key in headers)if([key isKindOfClass:NSString.class]&&[names containsObject:[key lowercaseString]]&&[headers[key]isKindOfClass:NSString.class])allowed[key]=headers[key];
            BOOL authenticated=NO;
            for(NSString *key in allowed)if([key caseInsensitiveCompare:@"Authorization"]==NSOrderedSame&&[allowed[key]hasPrefix:@"Bearer "])authenticated=YES;
            if(!authenticated){[op finish:nil error:@"Spotify's existing authenticated headers are not available. Play a track online and try again."];return;}
            SAP_TRACE("offline_devices","existing_authentication_available",op.traceOperation,@{@"credentials_logged":@NO});
            op.headers=allowed;ready(op);
        });
    };
#ifdef SAP_TESTING
    if(testHeaders){testHeaders(received);return;}
#endif
    void (*provider)(void (^)(NSDictionary *))=dlsym(RTLD_DEFAULT,"SGSpclientHeaders");
    if(!provider){[op finish:nil error:@"Vitrine's authenticated request provider is unavailable."];return;}
    provider(received);
}
static NSArray *activeDevices(NSArray *devices) {
    NSMutableArray *result=[NSMutableArray array];
    for(NSDictionary *device in devices)if([device[@"offline_enabled"]boolValue])[result addObject:device];
    return result;
}
static NSSet *deviceKeys(NSArray *devices) {
    NSMutableSet *keys=[NSMutableSet set];
    for(NSDictionary *device in devices)[keys addObject:[NSString stringWithFormat:@"%@/%@",device[@"device_id"],device[@"cache_id"]]];
    return keys;
}
static void readRegistry(SAPSlotRequest *op,void (^reply)(NSDictionary *,NSString *)) {
    [op request:@"offline/v1/licenseStatus" method:@"GET" completion:^(NSData *data,NSInteger status,NSString *error){
        if(error){reply(nil,error);return;}
        NSArray *fields=SAPProtoFields(data);int32_t maximum=(int32_t)SAPProtoNumber(fields,1,0),free=(int32_t)SAPProtoNumber(fields,2,0);
        if(!fields||maximum<=0||maximum>1000||free<0||free>maximum){reply(nil,@"The direct license response is not a valid LicenseStatus protobuf; the current state cannot be confirmed.");return;}
        [op request:@"offline/v1/devices" method:@"GET" completion:^(NSData *data,NSInteger status,NSString *error){
            if(error){reply(nil,error);return;}
            NSArray *fields=SAPProtoFields(data);if(!fields){reply(nil,@"The direct device response is not valid protobuf; the current state cannot be confirmed.");return;}
            NSMutableArray *devices=[NSMutableArray array];
            for(NSDictionary *field in fields)if([field[@"number"]unsignedIntValue]==1&&[field[@"wire"]unsignedIntValue]==2) {
                NSArray *f=SAPProtoFields(field[@"value"]);NSString *identifier=SAPProtoString(f,1),*cache=SAPProtoString(f,2);
                if(!identifier.length||!cache.length||identifier.length>512||cache.length>512){reply(nil,@"The direct device response has incomplete identifiers; the current state cannot be confirmed.");return;}
                NSArray *seen=SAPProtoFields(SAPProtoData(f,10));
                [devices addObject:@{@"device_id":identifier,@"cache_id":cache,@"name":SAPProtoString(f,3)?:@"Spotify device",
                    @"offline_enabled":@(SAPProtoNumber(f,6,0)!=0),@"last_seen_at":@(SAPProtoNumber(seen,1,0))}];
            }
            if(!devices.count){reply(nil,@"The direct API returned no identifiable devices; the current state cannot be confirmed.");return;}
            NSDictionary *value=@{@"max_licenses":@(maximum),@"free_licenses":@(free),@"devices":devices,@"observed_at":@(NSDate.date.timeIntervalSince1970),@"source":@"direct_https_response"};
            SAPJournalNoteAction(@"offline_slot_registry_read",value);SAP_TRACE("offline_devices","registry_readback",op.traceOperation,value);reply(value,nil);
        }];
    }];
}
static BOOL registryMatchesNative(NSDictionary *registry,NSDictionary *native) {
    NSDictionary *s=native[@"sources"],*local=s[@"local_device"][@"device"];
    if(![native[@"status"]isEqual:@"complete"] || ![s[@"devices"][@"read_status"]isEqual:@"received"])return NO;
    if(![registry[@"max_licenses"]isEqual:s[@"licenses"][@"max_licenses"]]||![registry[@"free_licenses"]isEqual:s[@"licenses"][@"free_licenses"]])return NO;
    if(![deviceKeys(activeDevices(registry[@"devices"]))isEqual:deviceKeys(activeDevices(s[@"devices"][@"devices"]))])return NO;
    return [deviceKeys(registry[@"devices"])containsObject:[NSString stringWithFormat:@"%@/%@",local[@"device_id"],local[@"cache_id"]]];
}
void SAPPreviewOfflineDeviceSlots(void (^completion)(NSDictionary *,NSString *)) {
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{SAPPreviewOfflineDeviceSlots(completion);});return;}
    lastPlan=nil;SAPSlotRequest *op=beginSlots(completion);if(!op)return;
    SAPRefreshDownloadCompatibility(^(NSDictionary *native){
        if(op.finished)return;op.native=native;
        withHeaders(op,^(SAPSlotRequest *request){readRegistry(request,^(NSDictionary *registry,NSString *error){
            if(error){[request finish:nil error:error];return;}
            if(!registryMatchesNative(registry,native)){[request finish:nil error:@"The authenticated direct API and this Spotify instance do not report the same registration state. Nothing was changed."];return;}
            NSArray *active=activeDevices(registry[@"devices"]);
            if(!active.count){[request finish:nil error:@"No occupied offline registrations were confirmed. Nothing was changed."];return;}
            NSDictionary *plan=@{@"id":NSUUID.UUID.UUIDString,@"created_at":@(NSDate.date.timeIntervalSince1970),
                @"free_licenses":registry[@"free_licenses"],@"max_licenses":registry[@"max_licenses"],@"active_devices":active,
                @"local_device":native[@"sources"][@"local_device"][@"device"]?:@{},@"source":@"native_and_direct_api_agree"};
            lastPlan=plan;[request finish:plan error:nil];
        });});
    });
}
static NSString *pathComponent(NSString *value) {
    return [value stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"]];
}
static void releaseNext(SAPSlotRequest *op,NSDictionary *before) {
    if(op.finished)return;
    if(op.index>=op.selected.count) {
        [op finish:@{@"status":@"verified",@"released_cache_ids":[op.released copy],@"free_licenses":before[@"free_licenses"],@"max_licenses":before[@"max_licenses"]} error:nil];return;
    }
    NSDictionary *device=op.selected[op.index];
    NSString *path=[NSString stringWithFormat:@"offline/v1/devices/%@/cache/%@/disable",pathComponent(device[@"device_id"]),pathComponent(device[@"cache_id"])];
    [op request:path method:@"POST" completion:^(NSData *data,NSInteger status,NSString *error){
        if(error){[op finish:@{@"status":@"unconfirmed",@"released_cache_ids":[op.released copy]} error:error];return;}
        readRegistry(op,^(NSDictionary *after,NSString *error){
            if(error){[op finish:nil error:error];return;}
            BOOL stillEnabled=[deviceKeys(activeDevices(after[@"devices"]))containsObject:[NSString stringWithFormat:@"%@/%@",device[@"device_id"],device[@"cache_id"]]];
            if(stillEnabled || ![after[@"max_licenses"]isEqual:before[@"max_licenses"]] || [after[@"free_licenses"]integerValue]<[before[@"free_licenses"]integerValue]+1) {
                [op finish:@{@"status":@"unconfirmed",@"released_cache_ids":[op.released copy],@"observed_registry":after} error:@"Spotify acknowledged the command, but a freed slot was not confirmed. No command will be repeated automatically; refresh the state before trying again."];return;
            }
            [op.released addObject:device[@"cache_id"]];op.index++;
            releaseNext(op,after);
        });
    }];
}
void SAPReleaseOfflineDeviceSlots(NSString *planID,NSArray<NSString *> *cacheIDs,void (^completion)(NSDictionary *,NSString *)) {
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{SAPReleaseOfflineDeviceSlots(planID,cacheIDs,completion);});return;}
    NSDictionary *plan=lastPlan;lastPlan=nil;
    if(![plan[@"id"]isEqual:planID] || !cacheIDs.count || [NSSet setWithArray:cacheIDs].count!=cacheIDs.count ||
       NSDate.date.timeIntervalSince1970-[plan[@"created_at"]doubleValue]>90) {
        if(completion)completion(nil,@"The reviewed device selection is missing, expired or invalid. Refresh it before changing registrations.");return;
    }
    NSMutableArray *selected=[NSMutableArray array];
    for(NSDictionary *device in plan[@"active_devices"])if([cacheIDs containsObject:device[@"cache_id"]])[selected addObject:device];
    if(selected.count!=cacheIDs.count){if(completion)completion(nil,@"The selected registrations were not in the reviewed list. Nothing was changed.");return;}
    SAPSlotRequest *op=beginSlots(completion);if(!op)return;op.plan=plan;op.selected=selected;
    SAPJournalNoteAction(@"offline_slot_release_confirmed",@{@"plan_id":planID,@"selected_cache_ids":cacheIDs});
    // Authenticate afresh and compare with the reviewed snapshot before any POST.
    withHeaders(op,^(SAPSlotRequest *request){readRegistry(request,^(NSDictionary *registry,NSString *error){
        if(error){[request finish:nil error:error];return;}
        if(![deviceKeys(activeDevices(registry[@"devices"]))isEqual:deviceKeys(plan[@"active_devices"])] ||
           ![registry[@"free_licenses"]isEqual:plan[@"free_licenses"]] || ![registry[@"max_licenses"]isEqual:plan[@"max_licenses"]]) {
            [request finish:nil error:@"The registration state changed after review. Nothing was changed; refresh the list."];return;
        }
        releaseNext(request,registry);
    });});
}
void SAPEnableOfflineOnCurrentDevice(void (^completion)(NSDictionary *,NSString *)) {
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{SAPEnableOfflineOnCurrentDevice(completion);});return;}
    if(slotOperationActive){if(completion)completion(nil,@"Another offline-device operation is in progress.");return;}
    slotOperationActive=YES;
    SAPRefreshDownloadCompatibility(^(NSDictionary *before){
        NSDictionary *sources=before[@"sources"],*local=sources[@"local_device"][@"device"];
        if(![before[@"status"]isEqual:@"complete"] || ![sources[@"local_device"][@"read_status"]isEqual:@"received"] || ![local[@"cache_id"]length]) {
            slotOperationActive=NO;if(completion)completion(nil,@"The current device and license state could not be read. No enable command was sent.");return;
        }
        if([local[@"offline_enabled"]boolValue]&&[sources[@"playback"][@"allowed"]boolValue]) {
            slotOperationActive=NO;if(completion)completion(before,nil);return;
        }
        if([sources[@"licenses"][@"error"]longLongValue] || [sources[@"licenses"][@"free_licenses"]integerValue]<=0) {
            slotOperationActive=NO;if(completion)completion(before,@"No free offline-device slot was reported. Release a reviewed old registration first. No enable command was sent.");return;
        }
        SAPCallOfflineCommandOnce(@"SetOfflinePlaybackAllowed",SAPProtoInteger(1,1),^(NSData *data,NSString *error){
            NSArray *fields=data?SAPProtoFields(data):nil;
            if(error || !fields || SAPProtoNumber(fields,1,0)!=1) {
                slotOperationActive=NO;if(completion)completion(nil,error?:@"Spotify did not confirm the enable command. It was sent once and will not be repeated automatically.");return;
            }
            SAPRefreshDownloadCompatibility(^(NSDictionary *after){
                slotOperationActive=NO;
                BOOL registered=[after[@"sources"][@"local_device"][@"device"][@"offline_enabled"]boolValue] && [after[@"sources"][@"playback"][@"allowed"]boolValue];
                SAPJournalNoteAction(@"offline_current_device_enable_result",@{@"registration_observed":@(registered),@"check":after,@"audio_playback_tested":@NO});
                if(completion)completion(after,registered?nil:@"Spotify acknowledged the command, but this copy's offline registration is not confirmed yet. Refresh the state; no enable command will be repeated automatically.");
            });
        });
    });
}
