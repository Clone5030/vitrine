#pragma once
#import <Foundation/Foundation.h>
NSDictionary *SAPNativeKeyTraceReport(void);
void SAPNativeKeyTraceResetSegment(void);
void SAPNativeKeyTraceObserveMetadata(NSString *service,NSString *method,NSString *requestURI,NSData *response);
#ifdef SAP_TESTING
void SAPTraceNativeBoundaryForTesting(unsigned kind,const uint64_t *registers);
#endif
