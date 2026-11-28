#import "RuntimeInventory.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <string.h>
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
// Only inspect metadata and temporary local objects. No XPC or host mutation.
static BOOL CWSignature(Class cls, SEL selector, const char *ret, const char **args, unsigned count) {
    Method method=class_getInstanceMethod(cls,selector);
    if (!method || method_getNumberOfArguments(method)!=count+2) return NO;
    char *r=method_copyReturnType(method);
    BOOL ok=r && !strcmp(r,ret);
    free(r);
    for(unsigned i=0;ok && i<count;i++) {
        char *a=method_copyArgumentType(method,i+2);
        ok=a && !strcmp(a,args[i]);
        free(a);
    }
    return ok;
}
static NSString *CWReadBool(id obj, NSString *name) {
    SEL sel=NSSelectorFromString(name);
    if (!obj || !CWSignature(object_getClass(obj),sel,"B",NULL,0)) return @"?";
    return ((BOOL(*)(id,SEL))objc_msgSend)(obj,sel)?@"1":@"0";
}
static NSString *CWReadInteger(id obj, NSString *name, const char *type) {
    SEL sel=NSSelectorFromString(name);
    if (!obj || !CWSignature(object_getClass(obj),sel,type,NULL,0)) return @"?";
    if (!strcmp(type,"q")) return [NSString stringWithFormat:@"%lld",((long long(*)(id,SEL))objc_msgSend)(obj,sel)];
    if (!strcmp(type,"Q")) return [NSString stringWithFormat:@"%llu",((unsigned long long(*)(id,SEL))objc_msgSend)(obj,sel)];
    return @"?";
}
static id CWReadObject(id obj, NSString *name) {
    SEL s=NSSelectorFromString(name);
    if (!obj || !CWSignature(object_getClass(obj),s,"@",NULL,0)) return nil;
    return ((id(*)(id,SEL))objc_msgSend)(obj,s);
}
static void CWGlassValues(NSMutableString *out) {
    [out appendString:@"\n--- Local tint objects (not sent to WidgetKit) ---\n"];
    Class cls=NSClassFromString(@"CHSWidgetTintParameters");
    SEL init=NSSelectorFromString(@"initWithFilterStyle:");
    const char *types[]={"q"};
    if (!cls || !CWSignature(cls,init,"@",types,1)) {
        [out appendString:@"Initializer unavailable or incompatible.\n"]; return;
    }
    // Small bounded set of local enum candidates. Unknown values may be rejected.
    // None of these are written to the system or to the existing widgets.
    for (long long style=0;style<=12;style++) {
        @try {
            id obj=((id(*)(id,SEL,long long))objc_msgSend)([cls alloc],init,style);
            if (!obj) { [out appendFormat:@"%lld: nil\n",style]; continue; }
            id options=CWReadObject(obj,@"glassOptions");
            [out appendFormat:@"requested=%lld actual=%@ glass=%@ clear=%@ accented=%@ subdued=%@ mode=%@ options=%@\n",
             style,CWReadInteger(obj,@"filterStyle","q"),CWReadBool(obj,@"wantsGlassMaterial"),
             CWReadBool(obj,@"isClearGlass"),CWReadBool(obj,@"isAccentedGlass"),
             CWReadBool(obj,@"wantsSubduedGlass"),CWReadInteger(obj,@"effectiveRenderingMode","Q"),
             options ? NSStringFromClass(object_getClass(options)) : @"nil"];
        } @catch(NSException *e) { [out appendFormat:@"%lld: rejected (%@)\n",style,e.name]; }
    }
}
static void CWFindGlassOwners(NSMutableString *out) {
    [out appendString:@"\n--- Local class metadata: glass/tint ownership ---\n"];
    const char *images[]={
        "/System/Library/PrivateFrameworks/ChronoServices.framework/ChronoServices",
        "/System/Library/Frameworks/WidgetKit.framework/WidgetKit"
    };
    NSArray<NSString *> *tokens=@[@"glassoptions",@"tintparameters",@"wantsglassmaterial",@"isclearglass",@"isaccentedglass",@"preferredbackgroundstyle"];
    for(unsigned image=0;image<2;image++) {
        unsigned count=0;
        const char **names=objc_copyClassNamesForImage(images[image],&count);
        [out appendFormat:@"image %s : %u classes\n",images[image],count];
        unsigned printed=0;
        for(unsigned i=0;names && i<count && printed<100;i++) {
            Class cls=objc_lookUpClass(names[i]);
            if (!cls) continue;
            for(int meta=0;meta<2;meta++){
                unsigned n=0; Method *methods=class_copyMethodList(meta?object_getClass(cls):cls,&n);
                for(unsigned j=0;j<n && printed<100;j++){
                    SEL sel=method_getName(methods[j]);
                    NSString *name=NSStringFromSelector(sel);
                    for(NSString *token in tokens) if([name.lowercaseString containsString:token]) {
                        [out appendFormat:@"%s %c %@ : %s\n",names[i],meta?'+':'-',name,method_getTypeEncoding(methods[j]) ?: "?"];
                        printed++;break;
                    }
                }
                free(methods);
            }
        }
        free(names);
    }
}

NSString *CWLabRuntimeInventory(void) {
    NSMutableString *out=[NSMutableString stringWithFormat:@"iOS %@\n",NSProcessInfo.processInfo.operatingSystemVersionString];
    static void *handle;
    if (!handle) handle=dlopen("/System/Library/PrivateFrameworks/ChronoServices.framework/ChronoServices",RTLD_LAZY|RTLD_LOCAL);
    [out appendFormat:@"ChronoServices: %@\n",handle?@"loaded":@"not loaded"];
    // First inspect declarations; then test local tint value objects only.
    for (NSString *name in @[@"CHSGlassOptions",@"CHSMutableGlassOptions",@"CHSWidgetTintParameters",@"CHSMutableWidgetTintParameters",@"CHSBaseDescriptor",@"CHSWidgetDescriptor",@"CHSMutableWidgetDescriptor",@"CHSConfiguredWidgetDescriptor",@"CHSMutableConfiguredWidgetDescriptor",@"CHSWidgetRenderScheme",@"CHSMutableWidgetRenderScheme",@"CHSScreenshotPresentationAttributes",@"CHSMutableScreenshotPresentationAttributes",@"CHSChronoServicesConnection"]) {
        Class cls=NSClassFromString(name);
        [out appendFormat:@"\n%@ %@\n",name,cls?@"":@"(unavailable)"];
        CWListClass(out,cls,[name containsString:@"GlassOptions"] || [name containsString:@"TintParameters"]);
    }
    CWGlassValues(out);
    CWFindGlassOwners(out);
    return out;
}
