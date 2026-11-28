#import "NativeDescriptorLab.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/log.h>
#import <dispatch/dispatch.h>
#import <string.h>
#import <stdlib.h>

// Scope: only named Clear/Blur variants in this lab extension.
// No IPC, no changes to other widgets, no access to the renderer process.
NSInteger CWLabStyleForKind(NSString *kind) {
    if ([kind isEqualToString:@"CWLabClear"] ||
        [kind isEqualToString:@"CWLabClearTint08"] ||
        [kind isEqualToString:@"CWLabClearTint16"] ||
        [kind isEqualToString:@"CWLabLightBlur50"] ||
        [kind isEqualToString:@"CWLabLightBlur85"]) return 1;
    if ([kind isEqualToString:@"CWLabBlur"]) return 2;
    return 0;
}
static BOOL CWMethod(Method method, char result, unsigned n) {
    if (!method || method_getNumberOfArguments(method) != n) return NO;
    char *type = method_copyReturnType(method);
    BOOL matches = type && type[0] == result;
    free(type);
    return matches;
}
static char CWArg(id object, SEL sel) {
    Method method=class_getInstanceMethod(object_getClass(object),sel);
    if (!CWMethod(method,'v',3)) return 0;
    char *type=method_copyArgumentType(method,2);
    char c=type && type[0] && !type[1] ? type[0] : 0;
    free(type);
    return c;
}
static BOOL CWSetBool(id obj, SEL sel, BOOL value) {
    switch(CWArg(obj,sel)) {
        case 'B': ((void(*)(id,SEL,_Bool))objc_msgSend)(obj,sel,value != 0); return YES;
        case 'c': ((void(*)(id,SEL,signed char))objc_msgSend)(obj,sel,value != 0); return YES;
        default: return NO;
    }
}
static BOOL CWSetStyle(id obj, NSInteger value) {
    SEL s=NSSelectorFromString(@"setPreferredBackgroundStyle:");
    switch(CWArg(obj,s)) {
        case 'q': ((void(*)(id,SEL,long long))objc_msgSend)(obj,s,value); return YES;
        case 'Q': ((void(*)(id,SEL,unsigned long long))objc_msgSend)(obj,s,value); return YES;
        case 'i': ((void(*)(id,SEL,int))objc_msgSend)(obj,s,(int)value); return YES;
        case 'I': ((void(*)(id,SEL,unsigned int))objc_msgSend)(obj,s,(unsigned int)value); return YES;
        default: return NO;
    }
}
static NSInteger CWStyle(id descriptor) {
    Class desc=NSClassFromString(@"CHSWidgetDescriptor");
    Class control=NSClassFromString(@"CHSControlDescriptor");
    if (!desc || ![descriptor isKindOfClass:desc] || (control && [descriptor isKindOfClass:control])) return 0;
    SEL kind=NSSelectorFromString(@"kind");
    if (!CWMethod(class_getInstanceMethod(object_getClass(descriptor),kind),'@',2)) return 0;
    id name=((id(*)(id,SEL))objc_msgSend)(descriptor,kind);
    return [name isKindOfClass:NSString.class] ? CWLabStyleForKind(name) : 0;
}
static id CWStyledDescriptor(id descriptor, NSInteger style) {
    if (![descriptor respondsToSelector:@selector(mutableCopyWithZone:)]) return nil;
    id copy=[descriptor mutableCopy];
    if (!copy || copy == descriptor || ![copy isKindOfClass:NSClassFromString(@"CHSWidgetDescriptor")]) return nil;
    if (!CWSetBool(copy,NSSelectorFromString(@"setBackgroundRemovable:"),YES) ||
        !CWSetBool(copy,NSSelectorFromString(@"setTransparent:"),YES)) return nil;
    if (style==2 && !CWSetBool(copy,NSSelectorFromString(@"setSupportsVibrantContent:"),YES)) return nil;
    if (!CWSetStyle(copy,style)) return nil;
    NSNumber *value=[copy valueForKey:@"preferredBackgroundStyle"];
    if (![value isKindOfClass:NSNumber.class] || value.integerValue!=style) return nil;
    // Let the secure coder serialize the mutable descriptor, rather than
    // assuming that copy will preserve the new private attributes.
    return copy;
}

@interface CWLabCoder : NSKeyedArchiver
@property(nonatomic) BOOL encountered;
@property(nonatomic) BOOL failed;
@property(nonatomic) NSUInteger replacements;
@end
@implementation CWLabCoder
- (void)encodeObject:(id)object forKey:(NSString *)key {
    if (!self.encountered && [key isEqualToString:@"widgetDescriptors"] && [object isKindOfClass:NSArray.class]) {
        self.encountered=YES;
        NSMutableArray *descriptors=[NSMutableArray array];
        for (id descriptor in (NSArray *)object) {
            NSInteger style=CWStyle(descriptor);
            id next=style ? CWStyledDescriptor(descriptor,style) : descriptor;
            if (!next) { self.failed=YES; break; }
            if (style) self.replacements++;
            [descriptors addObject:next];
        }
        [super encodeObject:self.failed ? object : [descriptors copy] forKey:key];
        return;
    }
    [super encodeObject:object forKey:key];
}
@end

static id CWLabPatch(id result) {
    if (!result) return result;
    Class resultClass=object_getClass(result);
    if (![NSStringFromClass(resultClass) hasSuffix:@"DescriptorFetchResult"]) return result;
    @try {
        if (!CWMethod(class_getInstanceMethod(resultClass,@selector(encodeWithCoder:)),'v',3) ||
            !CWMethod(class_getInstanceMethod(resultClass,@selector(initWithCoder:)),'@',3)) return result;
        CWLabCoder *coder=[[CWLabCoder alloc] initRequiringSecureCoding:YES];
        [(id<NSCoding>)result encodeWithCoder:coder];
        [coder finishEncoding];
        if (!coder.encountered || coder.failed || !coder.replacements) {
            os_log_error(OS_LOG_DEFAULT,"CWLab: descriptor collection not patched (%{public}d/%{public}d)",coder.encountered,coder.failed);
            return result;
        }
        NSError *error=nil;
        NSKeyedUnarchiver *decoder=[[NSKeyedUnarchiver alloc] initForReadingFromData:coder.encodedData error:&error];
        if (!decoder || error) return result;
        decoder.requiresSecureCoding=YES;
        id updated=[(id<NSCoding>)[resultClass alloc] initWithCoder:decoder];
        [decoder finishDecoding];
        if (!updated || decoder.error || object_getClass(updated)!=resultClass) return result;
        os_log_info(OS_LOG_DEFAULT,"CWLab: returning %lu candidate descriptors; host acceptance unknown",(unsigned long)coder.replacements);
        return updated;
    } @catch (NSException *error) {
        os_log_error(OS_LOG_DEFAULT,"CWLab: archive rejected: %{public}@",error.name);
        return result;
    }
}
typedef void (^CWCompletion)(id);
typedef void (*CWFetch)(id,SEL,CWCompletion);
static CWFetch allOriginal=NULL, currentOriginal=NULL;
static void CWForward(CWFetch original,id self,SEL sel,CWCompletion completion) {
    if (!original) return;
    if (!completion) { original(self,sel,completion); return; }
    original(self,sel,^(id result){ completion(CWLabPatch(result)); });
}
static void CWAll(id self,SEL sel,CWCompletion cb){ CWForward(allOriginal,self,sel,cb); }
static void CWCurrent(id self,SEL sel,CWCompletion cb){ CWForward(currentOriginal,self,sel,cb); }
static void CWInstall(Class cls,SEL sel,IMP impl,CWFetch *original) {
    if (!cls || *original) return;
    unsigned n=0; Method *methods=class_copyMethodList(cls,&n); Method method=NULL;
    for(unsigned i=0;i<n;i++) if(method_getName(methods[i])==sel){method=methods[i];break;}
    free(methods);
    if (!CWMethod(method,'v',3)) return;
    char *arg=method_copyArgumentType(method,2);
    BOOL block=arg && !strcmp(arg,"@?");
    free(arg);
    if(!block) return;
    IMP previous=method_getImplementation(method);
    if(!previous || previous==impl) return;
    *original=(CWFetch)previous;
    method_setImplementation(method,impl);
}
static void CWAttempt(void) {
    @synchronized(NSObject.class) {
        Class cls=NSClassFromString(@"_TtCC9WidgetKit24WidgetExtensionXPCServer14ExportedObject");
        CWInstall(cls,NSSelectorFromString(@"getAllCurrentDescriptorsWithCompletion:"),(IMP)CWAll,&allOriginal);
        CWInstall(cls,NSSelectorFromString(@"getCurrentDescriptorsWithCompletion:"),(IMP)CWCurrent,&currentOriginal);
    }
}
void CWLabInstall(void) {
    CWAttempt();
    static dispatch_once_t once;
    dispatch_once(&once,^{ dispatch_async(dispatch_get_main_queue(),^{ CWAttempt(); }); });
}
#if !defined(CW_LAB_TEST)
__attribute__((constructor)) static void CWLabEarly(void) {
    @autoreleasepool { CWAttempt(); }
}
#endif
