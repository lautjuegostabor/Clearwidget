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
void CWReloadOwnDescriptors(NSInteger expectedStyle, void (^completion)(NSString *)) {
    (void)expectedStyle; // Only a correlated extension receipt can establish style.
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
        Class connectionClass=object_getClass(connection);
        if (!connection || !CWCheckMethod(class_getInstanceMethod(connectionClass,reload),4,NO)) {
            finish(@"Firma de API privada no reconocida; no se invocó."); return;
        }
        // Independently traced ARM64 caller declares v8@?0 (void (^)(void)).
        // Do not invent an NSError or a success result from extra registers.
        // No speculative fetch ABI; the extension's receipt is independent.
        void (^reloaded)(void)=^{
            finish(@"ChronoServices devolvió el callback. Aceptación y estilo aún no confirmados.");
        };
        ((void(*)(id,SEL,id,id))objc_msgSend)(connection,reload,identifier,[reloaded copy]);
    } @catch (NSException *exception) { finish([NSString stringWithFormat:@"Recarga no disponible: %@.",exception.name]); }
}
