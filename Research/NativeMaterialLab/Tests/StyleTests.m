#import <Foundation/Foundation.h>
#import "../Widget/NativeDescriptorLab.h"
extern BOOL CWLabIsHostGlassKind(NSString *);
extern id CWLabTestHostGlassCopy(id, Class);
@interface CWTestGlass : NSObject <NSCopying, NSMutableCopying>
@property(nonatomic) NSInteger preferredBackgroundStyle;
@property(nonatomic) BOOL transparent;
@property(nonatomic) BOOL backgroundRemovable;
@property(nonatomic) BOOL supportsVibrantContent;
@end
@implementation CWTestGlass
- (id)copyWithZone:(NSZone *)zone {
    (void)zone; CWTestGlass *d=[CWTestGlass new];
    d.preferredBackgroundStyle=self.preferredBackgroundStyle;
    d.transparent=self.transparent;
    d.backgroundRemovable=self.backgroundRemovable;
    d.supportsVibrantContent=self.supportsVibrantContent;
    return d;
}
- (id)mutableCopyWithZone:(NSZone *)zone { return [self copyWithZone:zone]; }
@end
int main(void) {
    @autoreleasepool {
        NSCAssert(CWLabStyleForKind(@"CWLabClear")==1,@"clear descriptor");
        NSCAssert(CWLabStyleForKind(@"CWLabBlur")==2,@"blur descriptor");
        NSCAssert(CWLabStyleForKind(@"CWLabSystem")==0,@"unmodified system");
        NSCAssert(CWLabStyleForKind(@"CWLabGlass")==0,@"public glass only");
        NSCAssert(CWLabStyleForKind(@"ClearWidget")==0,@"production is untouched");
        NSCAssert(CWLabStyleForKind(@"Other")==0,@"unrelated is untouched");
        NSCAssert(CWLabStyleForKind(nil)==0,@"nil ignored");
        NSCAssert(CWLabIsHostGlassKind(@"CWLabHostGlassSmall") && CWLabIsHostGlassKind(@"CWLabHostGlassMedium"),@"new fixed sizes");
        NSCAssert(!CWLabIsHostGlassKind(@"CWLabBlur") && !CWLabIsHostGlassKind(@"ClearWidget"),@"existing controls and production excluded");
        NSCAssert(CWLabStyleForKind(@"CWLabHostGlassSmall")==0,@"host glass does not enter legacy blur path");
        CWTestGlass *original=[CWTestGlass new]; original.backgroundRemovable=YES;
        CWTestGlass *candidate=CWLabTestHostGlassCopy(original,CWTestGlass.class);
        NSCAssert(candidate && candidate!=original && candidate.preferredBackgroundStyle==2,@"style-only copy");
        NSCAssert(original.preferredBackgroundStyle==0,@"original untouched");
        NSCAssert(candidate.backgroundRemovable && !candidate.transparent && !candidate.supportsVibrantContent,@"original flags preserved");
        NSLog(@"Fixed kind and style-only copy checks passed; no device assertion.");
    }
    return 0;
}
