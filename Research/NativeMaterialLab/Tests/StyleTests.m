#import <Foundation/Foundation.h>
#import "../Widget/NativeDescriptorLab.h"
int main(void) {
    @autoreleasepool {
        NSCAssert(CWLabStyleForKind(@"CWLabClear")==1,@"clear descriptor");
        NSCAssert(CWLabStyleForKind(@"CWLabBlur")==2,@"blur descriptor");
        NSCAssert(CWLabStyleForKind(@"CWLabSystem")==0,@"unmodified system");
        NSCAssert(CWLabStyleForKind(@"CWLabGlass")==0,@"unmodified glass control");
        NSCAssert(CWLabStyleForKind(@"CWLabGlassOnClear")==1,@"native view on proven clear");
        NSCAssert(CWLabStyleForKind(@"CWLabGlassOnBlur")==2,@"native view on proven blur");
        NSCAssert(CWLabStyleForKind(@"ClearWidget")==0,@"production is untouched");
        NSCAssert(CWLabStyleForKind(@"Other")==0,@"unrelated is untouched");
        NSCAssert(CWLabStyleForKind(nil)==0,@"nil ignored");
        NSLog(@"Fixed kind scope checks passed; no device assertion.");
    }
    return 0;
}
