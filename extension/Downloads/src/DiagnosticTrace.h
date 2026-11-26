#pragma once
#import <Foundation/Foundation.h>
#include <stdbool.h>
#include <stdint.h>

typedef uint64_t SAPTraceID;
bool SAPTraceIsActive(void);
uint64_t SAPTraceGeneration(void);
void SAPTraceSetEnabled(bool enabled,const char *reason);
SAPTraceID SAPTraceBegin(NSString *kind,NSString *source,NSDictionary *facts);
SAPTraceID SAPTraceCurrentOperation(void);
void SAPTraceWithOperation(SAPTraceID operation,dispatch_block_t block);
void SAPTraceEvent(const char *category,const char *stage,SAPTraceID operation,NSDictionary *facts);
NSDictionary *SAPTraceReport(void);
NSDictionary *SAPTraceExport(void);
void SAPTraceFlush(void);

// Registration retains only fixed hook metadata, even while tracing is off.
// No diagnostic queue, file, callback wrapper or timer is created in that state.
void SAPTraceRegisterHook(Class cls,SEL selector,IMP installed,IMP original);
void SAPTraceHookCalled(Class cls,SEL selector);
NSDictionary *SAPTraceHookManifest(void);

@interface SAPTraceRPC : NSObject
@property(nonatomic,readonly) SAPTraceID identifier;
@end
SAPTraceRPC *SAPTraceRPCBegin(NSString *service,NSString *method,NSData *payload,
                             NSString *source,id endpoint,BOOL stream);
void SAPTraceRPCReturned(SAPTraceRPC *call,id lifetime);
void SAPTraceRPCReply(SAPTraceRPC *call,id response);
void SAPTraceRPCException(SAPTraceRPC *call,NSException *exception);
void SAPTraceRPCStreamEnd(SAPTraceRPC *call,NSString *reason);
NSDictionary *SAPTraceWireSummary(NSString *service,NSString *method,NSData *data,BOOL response);

#define SAP_TRACE(category,stage,operation,...) do { \
    if(SAPTraceIsActive())SAPTraceEvent(category,stage,operation,(__VA_ARGS__)); \
} while(0)

#ifdef SAP_TESTING
void SAPTraceTestConfigure(NSURL *directory,NSUInteger maximumBytes,NSUInteger pendingLimit,double rpcTimeout);
void SAPTraceTestDrain(void);
#endif
