#pragma once
#import <Foundation/Foundation.h>
// Bounded protobuf wire reader. Unknown fields retain their original bytes.
NSArray<NSDictionary *> *SAPProtoFields(NSData *data);
NSData *SAPProtoBytes(unsigned number, NSData *value);
NSData *SAPProtoInteger(unsigned number, uint64_t value);
uint64_t SAPProtoNumber(NSArray<NSDictionary *> *fields, unsigned number, uint64_t fallback);
NSData *SAPProtoData(NSArray<NSDictionary *> *fields, unsigned number);
NSString *SAPProtoString(NSArray<NSDictionary *> *fields, unsigned number);
