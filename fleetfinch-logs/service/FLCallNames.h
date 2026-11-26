#import <Foundation/Foundation.h>

extern const uint32_t FLSystemCallsMost;
extern const uint32_t FLKernelTrapsMost;

NSString *FLSystemCallName(uint32_t number);
NSString *FLKernelTrapName(uint32_t number);
NSArray<NSString *> *FLSystemCallNames(void);
