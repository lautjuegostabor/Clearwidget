// Original ClearWidget implementation. No third-party executable or source is embedded.
// Private WidgetKit descriptor API: optional at runtime, confined to this extension.
#import "GlassDescriptorHook.h"
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>
#import <stdbool.h>
#import <string.h>
#import <stdlib.h>

static NSString * const CWKind = @"ClearWidget";
static const NSInteger CWBlurStyle = 2;

static BOOL CWMethodMatches(Method m, char result, unsigned int count) {
    if (!m || method_getNumberOfArguments(m) != count) return NO;
    char *type = method_copyReturnType(m);
    BOOL ok = type && type[0] == result && !(result == '@' && type[1] == '?');
    free(type);
    return ok;
}
static BOOL CWObjectArg(Method m, unsigned int index, BOOL block) {
    if (!m || method_getNumberOfArguments(m) <= index) return NO;
    char *type = method_copyArgumentType(m,index);
    BOOL ok = type && type[0] == '@' && ((type[1] == '?') == block);
    free(type);
    return ok;
}
static char CWScalarArg(id object, SEL selector, BOOL booleanOnly) {
    Method m = class_getInstanceMethod(object_getClass(object),selector);
    if (!CWMethodMatches(m,'v',3)) return 0;
    char *type = method_copyArgumentType(m,2);
    char c = type && type[0] && !type[1] ? type[0] : 0;
    free(type);
    if (booleanOnly) return c == 'B' || c == 'c' ? c : 0;
    return c && strchr("cCsSiIlLqQ",c) ? c : 0;
}
static void CWSetScalar(id object, SEL selector, char encoding, NSInteger value) {
    // Respect the actual ObjC scalar ABI, including BOOL and NSInteger encodings.
    switch (encoding) {
        case 'B': ((void(*)(id,SEL,bool))objc_msgSend)(object,selector,value != 0); break;
        case 'c': ((void(*)(id,SEL,signed char))objc_msgSend)(object,selector,(signed char)value); break;
        case 'C': ((void(*)(id,SEL,unsigned char))objc_msgSend)(object,selector,(unsigned char)value); break;
        case 's': ((void(*)(id,SEL,short))objc_msgSend)(object,selector,(short)value); break;
        case 'S': ((void(*)(id,SEL,unsigned short))objc_msgSend)(object,selector,(unsigned short)value); break;
        case 'i': ((void(*)(id,SEL,int))objc_msgSend)(object,selector,(int)value); break;
        case 'I': ((void(*)(id,SEL,unsigned int))objc_msgSend)(object,selector,(unsigned int)value); break;
        case 'l': ((void(*)(id,SEL,long))objc_msgSend)(object,selector,(long)value); break;
        case 'L': ((void(*)(id,SEL,unsigned long))objc_msgSend)(object,selector,(unsigned long)value); break;
        case 'q': ((void(*)(id,SEL,long long))objc_msgSend)(object,selector,(long long)value); break;
        case 'Q': ((void(*)(id,SEL,unsigned long long))objc_msgSend)(object,selector,(unsigned long long)value); break;
    }
}

static BOOL CWIsOwnDescriptor(id obj, Class descriptorClass, Class controlClass) {
    if (!obj || !descriptorClass || ![obj isKindOfClass:descriptorClass]) return NO;
    if (controlClass && [obj isKindOfClass:controlClass]) return NO;
    SEL kind = NSSelectorFromString(@"kind");
    if (!CWMethodMatches(class_getInstanceMethod(object_getClass(obj),kind),'@',2)) return NO;
    id value = ((id(*)(id,SEL))objc_msgSend)(obj,kind);
    return [value isKindOfClass:NSString.class] && [value isEqualToString:CWKind];
}

// Always style an independent copy. Never leave a partially modified original on error.
static id CWStyledCopy(id descriptor) {
    if (![descriptor respondsToSelector:@selector(copyWithZone:)]) return nil;
    id copy = [descriptor copy];
    if (!copy || copy == descriptor || object_getClass(copy) != object_getClass(descriptor)) return nil;
    SEL setters[] = {NSSelectorFromString(@"setBackgroundRemovable:"),
                     NSSelectorFromString(@"setTransparent:"),
                     NSSelectorFromString(@"setSupportsVibrantContent:"),
                     NSSelectorFromString(@"setPreferredBackgroundStyle:")};
    char encodings[4];
    for (NSUInteger i=0;i<4;i++) {
        encodings[i]=CWScalarArg(copy,setters[i],i<3);
        if (!encodings[i]) return nil;
    }
    for (NSUInteger i=0;i<4;i++) CWSetScalar(copy,setters[i],encodings[i],i<3 ? 1 : CWBlurStyle);
    return copy;
}

@interface CWGlassArchiveDelegate : NSObject <NSKeyedArchiverDelegate>
@property(nonatomic,assign) Class descriptorClass;
@property(nonatomic,assign) Class controlClass;
@property(nonatomic) BOOL failed;
@property(nonatomic) NSUInteger replacements;
@property(nonatomic,strong) NSMapTable *copies;
@property(nonatomic,strong) NSHashTable *replacementObjects;
@end
@implementation CWGlassArchiveDelegate
- (id)archiver:(NSKeyedArchiver *)archiver willEncodeObject:(id)object {
    (void)archiver;
    if (!object || self.failed) return object;
    @try {
        if ([self.replacementObjects containsObject:object]) return object;
        if (!CWIsOwnDescriptor(object,self.descriptorClass,self.controlClass)) return object;
        id existing=[self.copies objectForKey:object];
        if (existing) return existing;
        id copy=CWStyledCopy(object);
        if (!copy) {self.failed=YES;return object;}
        [self.copies setObject:copy forKey:object];
        [self.replacementObjects addObject:copy];
        self.replacements++;
        return copy;
    } @catch (NSException *exception) {
        (void)exception;
        self.failed=YES;
        return object;
    }
}
@end

// Preserve the complete original result schema by letting its own coder serialize
// all fields; replace only matching widget descriptors with independent copies.
// No file, wallpaper image, network request, entitlement, or background timer.
static id CWPatchResult(id original, Class resultClass, Class descriptorClass, Class controlClass) {
    if (!original || !resultClass || !descriptorClass ||
        object_getClass(original) != resultClass) return original;
    @try {
        Method encoder=class_getInstanceMethod(resultClass,@selector(encodeWithCoder:));
        Method decoder=class_getInstanceMethod(resultClass,@selector(initWithCoder:));
        if (!CWMethodMatches(encoder,'v',3) || !CWObjectArg(encoder,2,NO) ||
            !CWMethodMatches(decoder,'@',3) || !CWObjectArg(decoder,2,NO)) return original;
        CWGlassArchiveDelegate *delegate=[CWGlassArchiveDelegate new];
        delegate.descriptorClass=descriptorClass;
        delegate.controlClass=controlClass;
        NSPointerFunctionsOptions identity=NSPointerFunctionsStrongMemory|NSPointerFunctionsObjectPointerPersonality;
        delegate.copies=[[NSMapTable alloc] initWithKeyOptions:identity valueOptions:identity capacity:2];
        delegate.replacementObjects=[[NSHashTable alloc] initWithOptions:identity capacity:2];
        NSKeyedArchiver *archive=[[NSKeyedArchiver alloc] initRequiringSecureCoding:YES];
        archive.delegate=delegate;
        [(id<NSCoding>)original encodeWithCoder:archive];
        [archive finishEncoding];
        if (delegate.failed || delegate.replacements==0) return original;
        NSError *error=nil;
        NSKeyedUnarchiver *reader=[[NSKeyedUnarchiver alloc] initForReadingFromData:archive.encodedData error:&error];
        if (!reader || error) return original;
        reader.requiresSecureCoding=YES;
        id patched=[(id<NSCoding>)[resultClass alloc] initWithCoder:reader];
        [reader finishDecoding];
        if (!patched || reader.error || object_getClass(patched)!=resultClass) return original;
        return patched;
    } @catch (NSException *exception) {
        (void)exception;
        return original;
    }
}

typedef void (^CWCompletion)(id);
typedef void (*CWFetchIMP)(id,SEL,CWCompletion);
static CWFetchIMP CWOriginalAll=NULL;
static CWFetchIMP CWOriginalCurrent=NULL;

// Each private method is v@:@? and the observed completion takes one object.
// Do not install if WidgetKit changes the method's visible runtime signature.
static BOOL CWFetchSignature(Method method) {
    return CWMethodMatches(method,'v',3) && CWObjectArg(method,2,YES);
}
static void CWForward(CWFetchIMP original,id self,SEL command,CWCompletion completion) {
    if (!original) return; // impossible after successful installation
    if (!completion) {original(self,command,completion);return;}
    NSObject *gate=[NSObject new];
    __block BOOL completed=NO;
    original(self,command,^(id result){
        @synchronized(gate) {
            if (completed) return;
            completed=YES;
        }
        id patched=result;
        @try {
            patched=CWPatchResult(result,
                NSClassFromString(@"_TtC9WidgetKit21DescriptorFetchResult"),
                NSClassFromString(@"CHSBaseDescriptor"),
                NSClassFromString(@"CHSControlDescriptor"));
        } @catch (NSException *exception) { (void)exception; patched=result; }
        completion(patched);
    });
}
static void CWAll(id self,SEL cmd,CWCompletion completion) {CWForward(CWOriginalAll,self,cmd,completion);}
static void CWCurrent(id self,SEL cmd,CWCompletion completion) {CWForward(CWOriginalCurrent,self,cmd,completion);}

static BOOL CWInstall(Class cls,SEL selector,IMP replacement,CWFetchIMP *saved) {
    if (!cls) return NO;
    if (*saved) return YES;
    // Do not modify an inherited implementation or any other class.
    unsigned int count=0; Method *methods=class_copyMethodList(cls,&count);
    Method found=NULL;
    for (unsigned int i=0;i<count;i++) if (method_getName(methods[i])==selector) {found=methods[i];break;}
    free(methods);
    if (!CWFetchSignature(found)) return NO;
    IMP previous=method_getImplementation(found);
    if (!previous || previous==replacement) return NO;
    *saved=(CWFetchIMP)previous;
    method_setImplementation(found,replacement);
    return YES;
}

void CWInstallGlassDescriptorHook(void) {
    if (@available(iOS 27.0,*)) {
        @synchronized(CWGlassArchiveDelegate.class) {
            Class server=NSClassFromString(@"_TtCC9WidgetKit24WidgetExtensionXPCServer14ExportedObject");
            CWInstall(server,NSSelectorFromString(@"getAllCurrentDescriptorsWithCompletion:"),(IMP)CWAll,&CWOriginalAll);
            CWInstall(server,NSSelectorFromString(@"getCurrentDescriptorsWithCompletion:"),(IMP)CWCurrent,&CWOriginalCurrent);
        }
    }
}

#if defined(CW_GLASS_TESTING)
id CWTestPatch(id original,Class result,Class desc,Class control) {return CWPatchResult(original,result,desc,control);}
BOOL CWTestFetchSignature(Method method) {return CWFetchSignature(method);}
BOOL CWTestInstall(Class cls,SEL sel,IMP replacement,IMP *saved) {
    CWFetchIMP previous=(CWFetchIMP)*saved;
    BOOL installed=CWInstall(cls,sel,replacement,&previous);
    *saved=(IMP)previous;
    return installed;
}
#endif
