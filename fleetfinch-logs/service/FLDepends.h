#import <Foundation/Foundation.h>

NSDictionary *FLGatherDependencies(NSDictionary *inventory, NSDictionary *usage);
BOOL FLSaveDependencies(NSDictionary *dependencies);
NSString *FLDependenciesSummary(NSDictionary *dependencies);
NSString *FLDependenciesText(NSDictionary *dependencies, NSDictionary *inventory);
NSString *FLDependsText(NSDictionary *dependencies, NSDictionary *inventory, NSString *name,
                        NSDictionary *usage);
