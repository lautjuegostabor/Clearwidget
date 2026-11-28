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
#import <stdint.h>

static NSString * const CWKind = @"ClearWidget";
// Blur requests the host material (style 2). Glass is a separate native SwiftUI
// composition probe over the transparent descriptor (style 1). No wallpaper image.
extern int32_t CWReadAppearance(uint64_t *revision);
extern void CWReportAppearance(int32_t mode,uint64_t revision,int32_t outcome);
typedef NS_ENUM(NSInteger, CWAppearance) {
    CWAppearanceSystem=0, CWAppearanceClear=1, CWAppearanceBlur=2, CWAppearanceGlass=3
};
static BOOL CWActiveMode(NSInteger mode) { return mode>=CWAppearanceClear && mode<=CWAppearanceGlass; }

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
static id CWStyledCopy(id descriptor, Class descriptorClass, NSInteger mode) {
    if (!CWActiveMode(mode) || ![descriptor respondsToSelector:@selector(mutableCopyWithZone:)]) return nil;
    id copy = [descriptor mutableCopy];
    if (!copy || copy == descriptor || ![copy isKindOfClass:descriptorClass]) return nil;
    SEL setters[] = {NSSelectorFromString(@"setBackgroundRemovable:"),
                     NSSelectorFromString(@"setTransparent:"),
                     NSSelectorFromString(@"setSupportsVibrantContent:"),
                     NSSelectorFromString(@"setPreferredBackgroundStyle:")};
    char encodings[4];
    for (NSUInteger i=0;i<4;i++) {
        encodings[i]=CWScalarArg(copy,setters[i],i<3);
        if (!encodings[i] && (i!=2 || mode==CWAppearanceBlur)) return nil;
    }
    // setTransparent: can reset style/vibrancy. Match the observed Clear path:
    // leave vibrancy untouched for Clear and the independent SwiftUI glass probe.
    NSInteger style = mode==CWAppearanceBlur ? 2 : 1;
    CWSetScalar(copy,setters[0],encodings[0],1);
    CWSetScalar(copy,setters[1],encodings[1],1);
    if (mode==CWAppearanceBlur) CWSetScalar(copy,setters[2],encodings[2],1);
    CWSetScalar(copy,setters[3],encodings[3],style);
    NSNumber *readback=[copy valueForKey:@"preferredBackgroundStyle"];
    if (![readback isKindOfClass:NSNumber.class] || readback.integerValue!=style) return nil;
    // ChronoServices mutable descriptors copy back to their immutable class.
    // This preserves the expected secure coding class on the XPC boundary.
    id frozen=[copy copy];
    if (!frozen || frozen==descriptor || ![frozen isKindOfClass:descriptorClass]) return nil;
    NSNumber *frozenStyle=[frozen valueForKey:@"preferredBackgroundStyle"];
    if (![frozenStyle isKindOfClass:NSNumber.class] || frozenStyle.integerValue!=style) return nil;
    return frozen;
}

@interface CWGlassArchiveDelegate : NSObject <NSKeyedArchiverDelegate>
@property(nonatomic,assign) Class descriptorClass;
@property(nonatomic,assign) Class controlClass;
@property(nonatomic) BOOL failed;
@property(nonatomic) NSInteger mode;
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
        id copy=CWStyledCopy(object,self.descriptorClass,self.mode);
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


 // Reconstruct the widget descriptor collection explicitly using the original result
 // coder. Preserve other keys (including controls, activities and future fields).
 // Keep the previous object-substitution path only for unrecognized schemas.
@interface CWGlassResultArchiver : NSKeyedArchiver
@property(nonatomic,assign) Class descriptorClass;
@property(nonatomic,assign) Class controlClass;
@property(nonatomic) NSInteger mode;
@property(nonatomic) BOOL foundCollection;
@property(nonatomic) BOOL failed;
@property(nonatomic) NSUInteger replacements;
@end
@implementation CWGlassResultArchiver
- (void)encodeObject:(id)object forKey:(NSString *)key {
    if (!self.foundCollection && [key isEqualToString:@"widgetDescriptors"] &&
        [object isKindOfClass:NSArray.class]) {
        self.foundCollection=YES;
        NSMutableArray *widgets=[NSMutableArray arrayWithCapacity:[object count]];
        for (id descriptor in (NSArray *)object) {
            id next=descriptor;
            if (CWIsOwnDescriptor(descriptor,self.descriptorClass,self.controlClass)) {
                next=CWStyledCopy(descriptor,self.descriptorClass,self.mode);
                if (!next) { self.failed=YES; break; }
                self.replacements++;
            }
            [widgets addObject:next];
        }
        [super encodeObject:self.failed ? object : [widgets copy] forKey:key];
        return;
    }
    [super encodeObject:object forKey:key];
}
@end

static id CWDecodeResult(NSData *bytes, Class resultClass) {
    NSError *error=nil;
    NSKeyedUnarchiver *reader=[[NSKeyedUnarchiver alloc] initForReadingFromData:bytes error:&error];
    if (!reader || error) return nil;
    reader.requiresSecureCoding=YES;
    id patched=[(id<NSCoding>)[resultClass alloc] initWithCoder:reader];
    [reader finishDecoding];
    return patched && !reader.error && object_getClass(patched)==resultClass ? patched : nil;
}

// Preserve the complete original result schema by letting its own coder serialize
// all fields; replace only matching widget descriptors with independent copies.
// No file, wallpaper image, network request, entitlement, or background timer.
static id CWPatchResult(id original, Class resultClass, Class descriptorClass, Class controlClass, NSInteger mode) {
    if (!CWActiveMode(mode) || !original || !resultClass || !descriptorClass ||
        object_getClass(original) != resultClass) return original;
    @try {
        Method encoder=class_getInstanceMethod(resultClass,@selector(encodeWithCoder:));
        Method decoder=class_getInstanceMethod(resultClass,@selector(initWithCoder:));
        if (!CWMethodMatches(encoder,'v',3) || !CWObjectArg(encoder,2,NO) ||
            !CWMethodMatches(decoder,'@',3) || !CWObjectArg(decoder,2,NO)) return original;
        CWGlassResultArchiver *direct=[[CWGlassResultArchiver alloc] initRequiringSecureCoding:YES];
        direct.descriptorClass=descriptorClass;
        direct.controlClass=controlClass;
        direct.mode=mode;
        [(id<NSCoding>)original encodeWithCoder:direct];
        [direct finishEncoding];
        if (direct.foundCollection) {
            if (direct.failed || !direct.replacements) return original;
            return CWDecodeResult(direct.encodedData,resultClass) ?: original;
        }
        CWGlassArchiveDelegate *delegate=[CWGlassArchiveDelegate new];
        delegate.descriptorClass=descriptorClass;
        delegate.controlClass=controlClass;
        delegate.mode=mode;
        NSPointerFunctionsOptions identity=NSPointerFunctionsStrongMemory|NSPointerFunctionsObjectPointerPersonality;
        delegate.copies=[[NSMapTable alloc] initWithKeyOptions:identity valueOptions:identity capacity:2];
        delegate.replacementObjects=[[NSHashTable alloc] initWithOptions:identity capacity:2];
        NSKeyedArchiver *archive=[[NSKeyedArchiver alloc] initRequiringSecureCoding:YES];
        archive.delegate=delegate;
        [(id<NSCoding>)original encodeWithCoder:archive];
        [archive finishEncoding];
        if (delegate.failed || delegate.replacements==0) return original;
        return CWDecodeResult(archive.encodedData,resultClass) ?: original;
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
        uint64_t revision=0;
        int32_t mode=CWReadAppearance(&revision);
        @try {
            patched=CWPatchResult(result,
                NSClassFromString(@"_TtC9WidgetKit21DescriptorFetchResult"),
                NSClassFromString(@"CHSWidgetDescriptor"),
                NSClassFromString(@"CHSControlDescriptor"),mode);
        } @catch (NSException *exception) { (void)exception; patched=result; }
        CWReportAppearance(mode,revision,mode==CWAppearanceSystem ? 0 : (patched!=result ? 1 : 2));
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

int CWGlassDescriptorHookAvailable(void) {
    @synchronized(CWGlassArchiveDelegate.class) { return CWOriginalAll != NULL || CWOriginalCurrent != NULL; }
}
static void CWAttemptInstall(void) {
    if (@available(iOS 27.0,*)) {
        @synchronized(CWGlassArchiveDelegate.class) {
            Class server=NSClassFromString(@"_TtCC9WidgetKit24WidgetExtensionXPCServer14ExportedObject");
            CWInstall(server,NSSelectorFromString(@"getAllCurrentDescriptorsWithCompletion:"),(IMP)CWAll,&CWOriginalAll);
            CWInstall(server,NSSelectorFromString(@"getCurrentDescriptorsWithCompletion:"),(IMP)CWCurrent,&CWOriginalCurrent);
        }
    }
}
#if !defined(CW_GLASS_TESTING)
__attribute__((constructor)) static void CWEarlyInstall(void) {
    // No Swift preference access or IPC before the extension initializes.
    @autoreleasepool { CWAttemptInstall(); }
}
#endif
void CWInstallGlassDescriptorHook(void) {
    CWAttemptInstall();
    static dispatch_once_t once;
    dispatch_once(&once, ^{ dispatch_async(dispatch_get_main_queue(), ^{ CWAttemptInstall(); }); });
}

#if defined(CW_GLASS_TESTING)
id CWTestPatch(id original,Class result,Class desc,Class control) {return CWPatchResult(original,result,desc,control,CWAppearanceBlur);}
id CWTestPatchMode(id original,Class result,Class desc,Class control,NSInteger mode) {return CWPatchResult(original,result,desc,control,mode);}
BOOL CWTestFetchSignature(Method method) {return CWFetchSignature(method);}
BOOL CWTestInstall(Class cls,SEL sel,IMP replacement,IMP *saved) {
    CWFetchIMP previous=(CWFetchIMP)*saved;
    BOOL installed=CWInstall(cls,sel,replacement,&previous);
    *saved=(IMP)previous;
    return installed;
}
#endif
