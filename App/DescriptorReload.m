#import "DescriptorReload.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <string.h>
#import <stdlib.h>

// Private API limited to querying/reloading this application's own descriptors.
// Never alter system-host settings, entitlements, other apps or account state.
static BOOL CWCheckMethod(Method m, unsigned count, BOOL objectReturn) {
    if (!m || method_getNumberOfArguments(m)!=count) return NO;
    char *r=method_copyReturnType(m);
    const char *p=r;
    while (p && *p && strchr("rnNoORV",*p)) p++;
    BOOL ok=p && *p==(objectReturn?'@':'v');
    free(r);
    if (!ok || count==2) return ok;
    char *a=method_copyArgumentType(m,2), *b=method_copyArgumentType(m,3);
    ok=a && a[0]=='@' && a[1]!='?' && b && b[0]=='@' && b[1]=='?';
    free(a);free(b);
    return ok;
}
static NSString *CWDescribeOwn(id result, NSInteger expectedStyle, NSString *identifier) {
    @try {
        id collection=result;
        Class box=NSClassFromString(@"CHSWidgetDescriptorsBox");
        if (box && [result isKindOfClass:box]) collection=[result valueForKey:@"descriptors"];
        if ([collection isKindOfClass:NSDictionary.class]) collection=[collection allValues];
        if (![collection isKindOfClass:NSArray.class] && ![collection isKindOfClass:NSSet.class])
            return @"Respuesta recibida; formato del descriptor no reconocido.";
        Class desc=NSClassFromString(@"CHSWidgetDescriptor");
        Class control=NSClassFromString(@"CHSControlDescriptor");
        NSUInteger matches=0, correct=0;
        NSMutableSet<NSNumber *> *styles=[NSMutableSet set];
        for (id item in collection) {
            if (!desc || ![item isKindOfClass:desc] || (control && [item isKindOfClass:control])) continue;
            if (![[item valueForKey:@"kind"] isEqual:@"ClearWidget"]) continue;
            NSString *owner=[item valueForKey:@"containerBundleIdentifier"];
            if (![owner isKindOfClass:NSString.class] || ![owner isEqualToString:identifier]) continue;
            NSNumber *style=[item valueForKey:@"preferredBackgroundStyle"];
            if (![style isKindOfClass:NSNumber.class]) continue;
            matches++; [styles addObject:style];
            if (style.integerValue==expectedStyle) correct++;
        }
        if (!matches) return @"iOS respondió; no se identificó el descriptor propio.";
        NSMutableArray<NSString *> *strings=[NSMutableArray array];
        for (NSNumber *style in [[styles allObjects] sortedArrayUsingSelector:@selector(compare:)]) [strings addObject:style.stringValue];
        NSString *values=[strings componentsJoinedByString:@", "];
        if (expectedStyle<0) return [NSString stringWithFormat:@"Descriptor leído: estilo %@. Sistema no impone un valor.",values];
        return [NSString stringWithFormat:@"Descriptor leído: estilo %@; esperado %ld. %@ No confirma el material visual.", values,(long)expectedStyle,correct==matches?@"Coincide.":@"No coincide."];
    } @catch (NSException *exception) {
        return [NSString stringWithFormat:@"No se pudo interpretar el descriptor: %@.",exception.name];
    }
}
void CWReloadOwnDescriptors(NSInteger expectedStyle, void (^completion)(NSString *)) {
    NSObject *gate=[NSObject new];
    __block BOOL finished=NO;
    void (^finish)(NSString *)=^(NSString *message) {
        @synchronized(gate) { if (finished) return; finished=YES; }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(message); });
    };
    // A bounded timeout; no persistent observer or timer.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,8*NSEC_PER_SEC),dispatch_get_main_queue(), ^{
        finish(@"ChronoServices no respondió en 8 s.");
    });
    @try {
        NSString *identifier=NSBundle.mainBundle.bundleIdentifier;
        if (!identifier.length) { finish(@"Identificador efectivo no disponible."); return; }
        Class cls=NSClassFromString(@"CHSChronoServicesConnection");
        if (!cls) {
            static void *handle;
            static dispatch_once_t once;
            dispatch_once(&once, ^{ handle=dlopen("/System/Library/PrivateFrameworks/ChronoServices.framework/ChronoServices",RTLD_LAZY|RTLD_LOCAL); });
            (void)handle;
            cls=NSClassFromString(@"CHSChronoServicesConnection");
        }
        SEL shared=NSSelectorFromString(@"sharedInstance");
        if (!cls || !CWCheckMethod(class_getClassMethod(cls,shared),2,YES)) { finish(@"ChronoServices no disponible."); return; }
        id connection=((id(*)(id,SEL))objc_msgSend)(cls,shared);
        SEL reload=NSSelectorFromString(@"reloadDescriptorsForContainerBundleIdentifier:completion:");
        SEL fetch=NSSelectorFromString(@"fetchDescriptorsForContainerBundleIdentifier:completion:");
        Class connectionClass=object_getClass(connection);
        if (!connection || !CWCheckMethod(class_getInstanceMethod(connectionClass,reload),4,NO) ||
            !CWCheckMethod(class_getInstanceMethod(connectionClass,fetch),4,NO)) {
            finish(@"Firma de API privada no reconocida; no se invocó."); return;
        }
        // Observed ChronoServices error callback passes two register arguments.
        // The first reload result is not interpreted; the independent fetch is
        // the actual readback. The exact iOS 27 callback ABI is a device test.
        void (^reloaded)(__unsafe_unretained id,NSError *)=^(__unsafe_unretained id unused,NSError *error) {
            (void)unused;
            @synchronized(gate) { if (finished) return; }
            if (error) { finish([NSString stringWithFormat:@"Recarga rechazada: %@ (%ld).",error.domain,(long)error.code]); return; }
            @try {
                void (^fetched)(id,NSError *)=^(id result,NSError *fetchError) {
                    if (fetchError) { finish([NSString stringWithFormat:@"Recarga respondió; lectura rechazada: %@ (%ld).",fetchError.domain,(long)fetchError.code]); return; }
                    finish(CWDescribeOwn(result,expectedStyle,identifier));
                };
                ((void(*)(id,SEL,id,id))objc_msgSend)(connection,fetch,identifier,[fetched copy]);
            } @catch (NSException *exception) { finish([NSString stringWithFormat:@"Lectura no disponible: %@.",exception.name]); }
        };
        ((void(*)(id,SEL,id,id))objc_msgSend)(connection,reload,identifier,[reloaded copy]);
    } @catch (NSException *exception) { finish([NSString stringWithFormat:@"Recarga no disponible: %@.",exception.name]); }
}
