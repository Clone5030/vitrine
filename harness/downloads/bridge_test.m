#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "../../tweak/Sources/Shared/Downloads/Downloads.h"
#import "../../tweak/Sources/Shared/Downloads/DownloadsBridge.h"

int main(void) { @autoreleasepool {
    __block NSString *version=@"9.1.90";
    Class bundleClass=object_getClass(NSBundle.mainBundle);
    SEL selector=@selector(objectForInfoDictionaryKey:);
    Method method=class_getInstanceMethod(bundleClass,selector);
    IMP original=method_getImplementation(method);
    class_replaceMethod(bundleClass,selector,imp_implementationWithBlock(^id(id self,NSString *key){
        return [key isEqual:@"CFBundleShortVersionString"]?version:((id (*)(id,SEL,id))original)(self,selector,key);
    }),method_getTypeEncoding(method));
    NSCAssert(!SGDownloadsAvailable(),@"missing companion reported unavailable");
    NSCAssert([SGDownloadsSummary()containsString:@"isn't loaded"],@"supported version is not blamed for missing engine");
    NSCAssert([SGDownloadsUnavailableReason()containsString:@"missing or could not load"],@"missing engine explained");
    version=@"9.1.91";
    NSCAssert([SGDownloadsSummary()containsString:@"9.1.91"],@"unsupported version identified accurately");
    NSCAssert([SGDownloadsUnavailableReason()containsString:@"exact Spotify 9.1.90 build"],@"exact verified build required");
    Class companion=objc_allocateClassPair(NSObject.class,"SAPTaurusBridge",0);
    __block NSInteger interfaceVersion=0;
    class_addMethod(object_getClass(companion),@selector(interfaceVersion),imp_implementationWithBlock(^NSInteger(id self){return interfaceVersion;}),"q@:");
    class_addMethod(object_getClass(companion),@selector(downloadSummary),imp_implementationWithBlock(^NSString *(id self){return @"Download ready";}),"@@:");
    class_addMethod(object_getClass(companion),@selector(downloadActive),imp_implementationWithBlock(^BOOL(id self){return NO;}),"B@:");
    objc_registerClassPair(companion);
    NSCAssert(!SGDownloadsAvailable(),@"incompatible bridge rejected");
    interfaceVersion=1;
    NSCAssert(SGDownloadsAvailable(),@"late-loaded compatible companion detected after earlier failed lookup");
    NSCAssert([SGDownloadsSummary()isEqual:@"Download ready"],@"companion status used");
    NSCAssert([SGDownloadsRowSummary()isEqual:@"Ready"],@"settings row recovers");
    class_replaceMethod(bundleClass,selector,original,method_getTypeEncoding(method));
    puts("PASS: missing engine versus unsupported version, incompatible bridge rejection, late companion lookup recovery");
} return 0; }
