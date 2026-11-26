#import <Foundation/Foundation.h>
#import "../../extension/Downloads/src/OfflineConfig.m"
#import "../../tweak/Sources/Shared/AdBlock/AdBlock.h"

bool SAPTraceIsActive(void) { return false; }
uint64_t SAPTraceGeneration(void) { return 0; }
SAPTraceID SAPTraceBegin(NSString *kind, NSString *source, NSDictionary *facts) { return 0; }
SAPTraceID SAPTraceCurrentOperation(void) { return 0; }
void SAPTraceWithOperation(SAPTraceID operation, dispatch_block_t block) { block(); }
void SAPTraceEvent(const char *category, const char *stage, SAPTraceID operation, NSDictionary *facts) {}
void SAPTraceRegisterHook(Class cls, SEL selector, IMP installed, IMP original) {}
void SAPTraceHookCalled(Class cls, SEL selector) {}

@interface HTTPTaskFixture : NSObject
@property(nonatomic,strong) NSURLRequest *currentRequest, *originalRequest;
@property(nonatomic,strong) NSURLResponse *response;
@end
@implementation HTTPTaskFixture @end

static NSUInteger unsupportedReads;
@interface AVAggregateAssetDownloadTask : HTTPTaskFixture @end
@implementation AVAggregateAssetDownloadTask
- (NSURLRequest *)currentRequest { unsupportedReads++; [NSException raise:NSInvalidArgumentException format:@"aggregate task has no HTTP request"]; return nil; }
@end
@interface UnsupportedTaskFixture : HTTPTaskFixture @end
@implementation UnsupportedTaskFixture
- (NSURLRequest *)currentRequest { [NSException raise:NSInvalidArgumentException format:@"no request getter"]; return nil; }
@end

@interface SPTDataLoaderService : NSObject
@property(nonatomic,strong) NSMutableData *received;
@property(nonatomic,strong) NSData *replayBody;
@property(nonatomic) NSUInteger completed;
@end
@implementation SPTDataLoaderService
- (instancetype)init { if ((self=[super init])) _received=[NSMutableData data]; return self; }
- (void)URLSession:(id)session dataTask:(id)task didReceiveData:(NSData *)data { [_received appendData:data]; }
- (void)URLSession:(id)session task:(id)task didCompleteWithError:(id)error {
    if (_replayBody) [self URLSession:session dataTask:task didReceiveData:_replayBody];
    _completed++;
}
@end

static NSData *join(NSArray<NSData *> *parts) { NSMutableData *out=[NSMutableData data]; for (NSData *part in parts) [out appendData:part]; return out; }
static NSData *stringField(unsigned field, NSString *value) { return SAPProtoBytes(field,[value dataUsingEncoding:NSUTF8StringEncoding]); }
static NSData *attribute(NSString *key, NSData *value) { return SAPProtoBytes(1,join(@[stringField(1,key),SAPProtoBytes(2,value)])); }
static NSData *fixture(BOOL bootstrap) {
    NSData *attributes=join(@[attribute(@"offline",SAPProtoInteger(2,0)),
        attribute(@"can-use-offline",SAPProtoInteger(2,0)),
        attribute(@"max-offline-tracks",SAPProtoInteger(3,10)),
        attribute(@"unrelated",stringField(4,@"keep me"))]);
    NSData *ucs=join(@[SAPProtoBytes(3,attributes),stringField(17,@"unknown field")]);
    NSData *customize=SAPProtoBytes(1,ucs);
    return bootstrap?SAPProtoBytes(2,SAPProtoBytes(1,SAPProtoBytes(1,customize))):customize;
}
static void assertAttributes(NSData *data, BOOL bootstrap, BOOL premium) {
    for (NSNumber *field in bootstrap?@[@2,@1,@1,@1,@3]:@[@1,@3]) data=SAPProtoData(SAPProtoFields(data),field.unsignedIntValue);
    NSMutableDictionary *attributes=[NSMutableDictionary dictionary];
    for (NSDictionary *field in SAPProtoFields(data)) {
        NSArray *entry=SAPProtoFields(field[@"value"]);
        attributes[SAPProtoString(entry,1)]=SAPProtoFields(SAPProtoData(entry,2));
    }
    NSCAssert(SAPProtoNumber(attributes[@"offline"],2,0)==1,@"offline retained");
    NSCAssert(SAPProtoNumber(attributes[@"can-use-offline"],2,0)==1,@"offline permission retained");
    NSCAssert(SAPProtoNumber(attributes[@"max-offline-tracks"],3,0)==SAPMinimumTrackLimit,@"offline quota retained");
    NSCAssert([SAPProtoString(attributes[@"unrelated"],4)isEqual:@"keep me"],@"unknown attributes retained");
    if (premium) NSCAssert([SAPProtoString(attributes[@"type"],4)isEqual:@"premium"],@"premium retained");
}
int main(void) { @autoreleasepool {
    SAPInstallOfflineConfig();
    SPTDataLoaderService *delegate=[SPTDataLoaderService new];
    AVAggregateAssetDownloadTask *aggregate=[AVAggregateAssetDownloadTask new];
    [delegate URLSession:nil task:aggregate didCompleteWithError:nil];
    NSCAssert(delegate.completed==1 && unsupportedReads==0,@"aggregate completion forwarded without request access");
    [delegate URLSession:nil task:[UnsupportedTaskFixture new] didCompleteWithError:nil];
    NSCAssert(delegate.completed==2,@"unsupported custom task completion forwarded");
    for (NSNumber *flag in @[@NO,@YES]) {
        BOOL bootstrap=flag.boolValue;
        NSData *raw=fixture(bootstrap);
        NSData *(^premiumPatch)(NSData *)=^NSData *(NSData *body){return bootstrap?SGPatchBootstrap(body):SGPatchCustomize(body);};
        assertAttributes(SAPRewriteOfflineConfig(premiumPatch(raw),bootstrap),bootstrap,YES);
        assertAttributes(premiumPatch(SAPRewriteOfflineConfig(raw,bootstrap)),bootstrap,YES);
        HTTPTaskFixture *task=[HTTPTaskFixture new];
        task.originalRequest=[NSURLRequest requestWithURL:[NSURL URLWithString:bootstrap?@"https://spclient.spotify.com/v1/bootstrap":@"https://spclient.spotify.com/v1/customize"]];
        task.response=[[NSHTTPURLResponse alloc]initWithURL:task.originalRequest.URL statusCode:200 HTTPVersion:@"HTTP/2" headerFields:@{}];
        SPTDataLoaderService *reader=[SPTDataLoaderService new];
        [reader URLSession:nil dataTask:task didReceiveData:[raw subdataWithRange:NSMakeRange(0,raw.length/2)]];
        [reader URLSession:nil dataTask:task didReceiveData:[raw subdataWithRange:NSMakeRange(raw.length/2,raw.length-raw.length/2)]];
        NSCAssert(reader.received.length==0,@"config buffered until complete");
        [reader URLSession:nil task:task didCompleteWithError:nil];
        NSCAssert(reader.completed==1,@"HTTP completion forwarded exactly once");
        assertAttributes(reader.received,bootstrap,NO);
        reader=[SPTDataLoaderService new];
        reader.replayBody=premiumPatch(raw);
        [reader URLSession:nil task:task didCompleteWithError:nil];
        NSCAssert(reader.completed==1,@"synthetic cached response completion forwarded once");
        assertAttributes(reader.received,bootstrap,YES);
    }
    NSData *invalid=[NSData dataWithBytes:"\xff" length:1];
    NSCAssert([SAPRewriteOfflineConfig(invalid,NO)isEqual:invalid],@"unrecognized data passed through");
    puts("PASS: aggregate/custom task completion, split and reentrant bootstrap/customize delivery, premium/offline composition, unknown data passthrough");
} return 0; }
