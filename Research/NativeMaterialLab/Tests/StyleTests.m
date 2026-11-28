#import <Foundation/Foundation.h>
#import "../Widget/NativeDescriptorLab.h"
int main(void) {
    @autoreleasepool {
        NSCAssert(CWLabStyleForKind(@"CWLabClear")==1,@"clear descriptor");
        NSCAssert(CWLabStyleForKind(@"CWLabBlur")==2,@"blur descriptor");
        for (NSString *kind in @[@"CWLabSystem",@"CWLabGlass",@"CWLabNativeSDKSmall",@"CWLabNativeSDKMedium",@"CWLabHostGlassSmall",@"CWLabHostGlassMedium",@"ClearWidget",@"Other"]) {
            NSCAssert(CWLabStyleForKind(kind)==0,@"native and unrelated kinds must not enter legacy path");
        }
        NSCAssert(CWLabStyleForKind(nil)==0,@"nil ignored");
        NSLog(@"Scope tests passed; no native descriptor mutation.");
    }
    return 0;
}
