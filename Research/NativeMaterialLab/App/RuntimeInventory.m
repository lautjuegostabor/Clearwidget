#import "RuntimeInventory.h"
#import <objc/runtime.h>
#import <dlfcn.h>
#import <stdlib.h>

static BOOL CWRelevant(NSString *name) {
    NSString *lower=name.lowercaseString;
    for (NSString *s in @[@"glass",@"background",@"transparent",@"texture",@"vibran",@"render",@"coating",@"descriptor",@"initwith",@"encodewith",@"copy"]) {
        if ([lower containsString:s]) return YES;
    }
    return NO;
}
static void CWListClass(NSMutableString *out, Class cls, BOOL all) {
    if (!cls) return;
    for(int meta=0;meta<2;meta++) {
        Class c=meta?object_getClass(cls):cls;
        unsigned count=0;
        Method *methods=class_copyMethodList(c,&count);
        NSMutableArray<NSString *> *lines=[NSMutableArray array];
        for(unsigned i=0;i<count;i++) {
            NSString *name=NSStringFromSelector(method_getName(methods[i]));
            if (all || CWRelevant(name)) {
                const char *encoding=method_getTypeEncoding(methods[i]);
                [lines addObject:[NSString stringWithFormat:@"%c %@ : %s",meta?'+':'-',name,encoding?encoding:"?"]];
            }
        }
        free(methods);
        for(NSString *line in [lines sortedArrayUsingSelector:@selector(compare:)]) [out appendFormat:@"%@\n",line];
    }
}
NSString *CWLabRuntimeInventory(void) {
    NSMutableString *out=[NSMutableString stringWithFormat:@"iOS %@\n",NSProcessInfo.processInfo.operatingSystemVersionString];
    static void *handle;
    if (!handle) handle=dlopen("/System/Library/PrivateFrameworks/ChronoServices.framework/ChronoServices",RTLD_LAZY|RTLD_LOCAL);
    [out appendFormat:@"ChronoServices: %@\n",handle?@"loaded":@"not loaded"];
    // No instances are created and no private method is invoked.
    for (NSString *name in @[@"CHSGlassOptions",@"CHSMutableGlassOptions",@"CHSWidgetDescriptor",@"CHSMutableWidgetDescriptor",@"CHSConfiguredWidgetDescriptor",@"CHSWidgetRenderScheme",@"CHSMutableWidgetRenderScheme",@"CHSChronoServicesConnection"]) {
        Class cls=NSClassFromString(name);
        [out appendFormat:@"\n%@ %@\n",name,cls?@"":@"(unavailable)"];
        CWListClass(out,cls,[name containsString:@"GlassOptions"]);
    }
    return out;
}
