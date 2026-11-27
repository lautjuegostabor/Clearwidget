#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import <stdint.h>
int32_t CWReadAppearance(uint64_t *revision) { if (revision) *revision=0; return 0; }
void CWReportAppearance(int32_t mode,uint64_t revision,int32_t outcome) { (void)mode;(void)revision;(void)outcome; }
extern id CWTestPatchMode(id,Class,Class,Class,NSInteger);
extern id CWTestPatch(id,Class,Class,Class);
extern BOOL CWTestFetchSignature(Method);
extern BOOL CWTestInstall(Class,SEL,IMP,IMP *);
static void check(BOOL ok,NSString *message) {
    if (!ok) {NSLog(@"FAIL: %@",message);exit(1);}
}

@interface CWTestDescriptor : NSObject <NSSecureCoding,NSCopying,NSMutableCopying>
@property(copy) NSString *kind;
@property BOOL backgroundRemovable;
@property BOOL transparent;
@property BOOL supportsVibrantContent;
@property NSInteger preferredBackgroundStyle;
@end
@interface CWTestMutableDescriptor : CWTestDescriptor @end
@implementation CWTestDescriptor
+ (BOOL)supportsSecureCoding{return YES;}
- (void)encodeWithCoder:(NSCoder *)c {
    [c encodeObject:self.kind forKey:@"kind"];
    [c encodeBool:self.backgroundRemovable forKey:@"remove"];
    [c encodeBool:self.transparent forKey:@"transparent"];
    [c encodeBool:self.supportsVibrantContent forKey:@"vibrant"];
    [c encodeInteger:self.preferredBackgroundStyle forKey:@"style"];
}
- (instancetype)initWithCoder:(NSCoder *)c {
    if ((self=[super init])) {
        _kind=[c decodeObjectOfClass:NSString.class forKey:@"kind"];
        _backgroundRemovable=[c decodeBoolForKey:@"remove"];
        _transparent=[c decodeBoolForKey:@"transparent"];
        _supportsVibrantContent=[c decodeBoolForKey:@"vibrant"];
        _preferredBackgroundStyle=[c decodeIntegerForKey:@"style"];
    }
    return self;
}
- (id)copyWithZone:(NSZone *)zone {
    CWTestDescriptor *d=[[[self class] allocWithZone:zone] init];
    d.kind=self.kind;d.backgroundRemovable=self.backgroundRemovable;
    d.transparent=self.transparent;d.supportsVibrantContent=self.supportsVibrantContent;
    d.preferredBackgroundStyle=self.preferredBackgroundStyle;return d;
}
- (id)mutableCopyWithZone:(NSZone *)zone {
    CWTestDescriptor *d=[[CWTestMutableDescriptor allocWithZone:zone] init];
    d.kind=self.kind;d.backgroundRemovable=self.backgroundRemovable;
    d.transparent=self.transparent;d.supportsVibrantContent=self.supportsVibrantContent;
    d.preferredBackgroundStyle=self.preferredBackgroundStyle;return d;
}
@end
@implementation CWTestMutableDescriptor
- (id)copyWithZone:(NSZone *)zone {
    CWTestDescriptor *d=[[CWTestDescriptor allocWithZone:zone] init];
    d.kind=self.kind;d.backgroundRemovable=self.backgroundRemovable;
    d.transparent=self.transparent;d.supportsVibrantContent=self.supportsVibrantContent;
    d.preferredBackgroundStyle=self.preferredBackgroundStyle;return d;
}
@end
@interface CWTestControl : CWTestDescriptor @end
@implementation CWTestControl @end
@interface CWTestNoCopy : CWTestDescriptor @end
@implementation CWTestNoCopy
- (id)mutableCopyWithZone:(NSZone *)zone {(void)zone;return self;}
@end
@interface CWTestThrow : CWTestDescriptor @end
@implementation CWTestThrow
- (id)mutableCopyWithZone:(NSZone *)zone { CWTestThrow *d=[[CWTestThrow allocWithZone:zone] init];d.kind=self.kind;return d; }
- (void)setPreferredBackgroundStyle:(NSInteger)style {(void)style;[NSException raise:@"Test" format:@"setter refused"];}
@end
@interface CWTestResult : NSObject <NSSecureCoding>
@property(copy) NSArray *widgetDescriptors;
@property(copy) NSArray *activityDescriptors;
@property(copy) NSArray *controlDescriptors;
@property(copy) NSString *futureField;
@end
@implementation CWTestResult
+ (BOOL)supportsSecureCoding{return YES;}
- (void)encodeWithCoder:(NSCoder *)c{
    [c encodeObject:self.widgetDescriptors forKey:@"widgetDescriptors"];
    [c encodeObject:self.activityDescriptors forKey:@"activityDescriptors"];
    [c encodeObject:self.controlDescriptors forKey:@"controlDescriptors"];
    [c encodeObject:self.futureField forKey:@"futureField"];
}
- (instancetype)initWithCoder:(NSCoder *)c{
    if((self=[super init])){
        NSSet *allowed=[NSSet setWithArray:@[NSArray.class,CWTestDescriptor.class,CWTestControl.class,CWTestNoCopy.class,CWTestThrow.class,NSString.class]];
        _widgetDescriptors=[c decodeObjectOfClasses:allowed forKey:@"widgetDescriptors"];
        _activityDescriptors=[c decodeObjectOfClasses:allowed forKey:@"activityDescriptors"];
        _controlDescriptors=[c decodeObjectOfClasses:allowed forKey:@"controlDescriptors"];
        _futureField=[c decodeObjectOfClass:NSString.class forKey:@"futureField"];
    }return self;
}
@end
@interface CWTestServer : NSObject
- (void)fetch:(void(^)(id))completion;
- (void)bad:(id)object;
@end
@implementation CWTestServer
- (void)fetch:(void(^)(id))completion {completion(@"ok");}
- (void)bad:(id)object {(void)object;}
@end
@interface CWTestInherited : CWTestServer @end
@implementation CWTestInherited @end
static void replacement(id self,SEL cmd,void(^cb)(id)){(void)self;(void)cmd;cb(@"replacement");}
static CWTestDescriptor *descriptor(Class cls,NSString *kind){CWTestDescriptor*d=[cls new];d.kind=kind;return d;}
static CWTestResult *result(NSArray *widgets,NSArray *controls) {
    CWTestResult*r=[CWTestResult new];r.widgetDescriptors=widgets;r.controlDescriptors=controls;
    r.activityDescriptors=@[];r.futureField=@"keep this field";return r;
}
static id patch(CWTestResult *r){return CWTestPatch(r,CWTestResult.class,CWTestDescriptor.class,CWTestControl.class);}
int main(void){@autoreleasepool{
    CWTestDescriptor *own=descriptor(CWTestDescriptor.class,@"ClearWidget");
    CWTestDescriptor *other=descriptor(CWTestDescriptor.class,@"OtherWidget");
    CWTestDescriptor *control=descriptor(CWTestControl.class,@"ClearWidget");
    CWTestResult *original=result(@[own,other],@[control]);
    check(CWTestPatchMode(original,CWTestResult.class,CWTestDescriptor.class,CWTestControl.class,0)==original,@"system returns identical result");
    check(CWTestPatchMode(original,CWTestResult.class,CWTestDescriptor.class,CWTestControl.class,99)==original,@"unknown mode returns identical result");
    CWTestResult *clear=CWTestPatchMode(original,CWTestResult.class,CWTestDescriptor.class,CWTestControl.class,1);
    CWTestDescriptor *c=clear.widgetDescriptors[0];
    check(c.transparent && c.backgroundRemovable && !c.supportsVibrantContent && c.preferredBackgroundStyle==1,@"clear style");
    CWTestResult *glass=CWTestPatchMode(original,CWTestResult.class,CWTestDescriptor.class,CWTestControl.class,3);
    CWTestDescriptor *g=glass.widgetDescriptors[0];
    check(g.transparent && g.backgroundRemovable && g.supportsVibrantContent && g.preferredBackgroundStyle==2,@"glass candidate requests native material");
    check([g class]==CWTestDescriptor.class,@"mutable subclass converted back to immutable class");
    CWTestResult *changed=patch(original);
    check(changed!=original,@"new result");
    CWTestDescriptor *d=changed.widgetDescriptors[0];
    check(d.backgroundRemovable && d.transparent && d.supportsVibrantContent && d.preferredBackgroundStyle==2,@"blur style");
    check(!own.transparent && own.preferredBackgroundStyle==0,@"original unchanged");
    check(!((CWTestDescriptor*)changed.widgetDescriptors[1]).transparent,@"unrelated widget");
    check(!((CWTestDescriptor*)changed.controlDescriptors[0]).transparent,@"control unchanged");
    check([changed.futureField isEqualToString:original.futureField],@"unknown field preserved");
    CWTestResult *noTarget=result(@[other],@[control]);
    check(patch(noTarget)==noTarget,@"no matching widget");
    CWTestResult *noCopy=result(@[own,descriptor(CWTestNoCopy.class,@"ClearWidget")],@[]);
    check(patch(noCopy)==noCopy && !own.transparent,@"no independent copy; atomic fallback");
    CWTestResult *throws=result(@[own,descriptor(CWTestThrow.class,@"ClearWidget")],@[]);
    check(patch(throws)==throws && !own.transparent,@"exception; atomic fallback");
    check(CWTestPatch(original,NSObject.class,CWTestDescriptor.class,CWTestControl.class)==original,@"unknown result class");
    check(CWTestPatch(original,CWTestResult.class,Nil,CWTestControl.class)==original,@"missing descriptor class");
    check(CWTestFetchSignature(class_getInstanceMethod(CWTestServer.class,@selector(fetch:))),@"block ABI accepted");
    check(!CWTestFetchSignature(class_getInstanceMethod(CWTestServer.class,@selector(bad:))),@"object ABI refused");
    IMP saved=NULL;
    check(!CWTestInstall(CWTestInherited.class,@selector(fetch:),(IMP)replacement,&saved) && !saved,@"no superclass patch");
    check(!CWTestInstall(CWTestServer.class,@selector(bad:),(IMP)replacement,&saved) && !saved,@"invalid hook refused");
    check(CWTestInstall(CWTestServer.class,@selector(fetch:),(IMP)replacement,&saved) && saved,@"valid hook installed");
    __block int calls=0;
    [[CWTestServer new] fetch:^(id v){check([v isEqual:@"replacement"],@"replacement callback");calls++;}];
    check(calls==1,@"one callback");
    check(CWTestInstall(CWTestServer.class,@selector(fetch:),(IMP)replacement,&saved),@"idempotent");
    method_setImplementation(class_getInstanceMethod(CWTestServer.class,@selector(fetch:)),saved);
    NSLog(@"Glass descriptor checks passed: copy, style, unrelated widgets, controls, preservation, fallback and ABI.");
}return 0;}
