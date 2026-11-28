#import <Foundation/Foundation.h>
#import "../Widget/NativeDescriptorLab.h"
int main(void) {
    @autoreleasepool {
        NSCAssert(CWLabStyleForKind(@"CWLabClear")==1,@"clear descriptor");
        NSCAssert(CWLabStyleForKind(@"CWLabBlur")==2,@"blur descriptor");
        for (NSString *kind in @[@"CWLabClearTint08",@"CWLabClearTint16",@"CWLabLightBlur50",@"CWLabLightBlur85"]) {
            NSCAssert(CWLabStyleForKind(kind)==1,@"variants must start from real Clear, not fixed host blur");
        }
        for (NSString *kind in @[@"CWLabSystem",@"CWLabGlass",@"CWLabNativeSDKSmall",@"CWLabNativeSDKMedium",@"CWLabHostGlassSmall",@"CWLabHostGlassMedium",@"ClearWidget",@"Other"]) {
            NSCAssert(CWLabStyleForKind(kind)==0,@"native and unrelated kinds must not enter legacy path");
        }
        NSCAssert(CWLabStyleForKind(nil)==0,@"nil ignored");
        NSCAssert(CWLabStyleForKind(@"CWLabExactGlass")==0,@"exact variant bypasses legacy copy");
        NSCAssert(CWLabUsesExactStyleForKind(@"CWLabExactGlass"),@"exact variant");
        for(NSString *kind in @[@"CWLabSystem",@"CWLabClear",@"CWLabBlur",@"CWLabGlass",@"Other"]) {
            NSCAssert(!CWLabUsesExactStyleForKind(kind),@"original encoder must not modify controls");
        }
        for(NSString *kind in @[@"CWLabExactGlassLight6",@"CWLabExactGlassLight12",@"CWLabExactGlassLight20",@"CWLabExactGlassLight30"]) {
            NSCAssert(CWLabUsesExactStyleForKind(kind),@"same exact native glass descriptor");
            NSCAssert(CWLabStyleForKind(kind)==0,@"no legacy Clear or Blur path");
        }
        NSCAssert(!CWLabUsesExactStyleForKind(nil),@"nil ignored");
        NSLog(@"Scope tests passed; exact variant isolated.");
    }
    return 0;
}
