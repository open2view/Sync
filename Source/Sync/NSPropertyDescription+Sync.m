#import "NSPropertyDescription+Sync.h"

#import "NSEntityDescription+PrimaryKey.h"
#import "NSManagedObject+PropertyMapperHelpers.h"

static NSString * const SyncCustomLocalPrimaryKey = @"sync.isPrimaryKey";
static NSString * const SyncCustomLocalPrimaryKeyValue = @"true";
static NSString * const SyncCustomRemoteKey = @"sync.remoteKey";
static NSString * const PropertyMapperNonExportableKey = @"sync.nonExportable";
static NSString * const PropertyMapperCustomValueTransformerKey = @"sync.valueTransformer";

@implementation NSPropertyDescription (Sync)

- (BOOL)isCustomPrimaryKey {
    NSString *keyName = self.userInfo[SyncCustomLocalPrimaryKey];
    BOOL hasCustomPrimaryKey = keyName && [keyName isEqualToString:SyncCustomLocalPrimaryKeyValue];
    return hasCustomPrimaryKey;
}

- (NSString *)customKey {
    return self.userInfo[SyncCustomRemoteKey];
}

- (BOOL)shouldExportAttribute {
    NSString *nonExportableKey = self.userInfo[PropertyMapperNonExportableKey];
    BOOL shouldExportAttribute = (nonExportableKey == nil);
    return shouldExportAttribute;
}

- (NSString *)customTransformerName {
    return self.userInfo[PropertyMapperCustomValueTransformerKey];
}

@end
