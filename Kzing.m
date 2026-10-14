#import <Foundation/Foundation.h>  
#import <UIKit/UIKit.h>  
#import <QuartzCore/QuartzCore.h>  
#import <objc/runtime.h>  
  
typedef NS_ENUM(NSInteger, KzigLockMode) {  
    KzigLockMode60Hz = 0,  
    KzigLockMode120Hz,  
    KzigLockModeUnlocked  
};  
  
static KzigLockMode gCurrentMode = KzigLockMode60Hz;  
static NSInteger gTargetFPS = 60;  
  
#pragma mark - CADisplayLink Swizzling for Global Frame Lock  
  
@implementation CADisplayLink (KzigFPSHook)  
  
+ (void)load {  
    static dispatch_once_t onceToken;  
    dispatch_once(&onceToken, ^{  
        Class cls = [self class];  
        SEL origSel = @selector(setPreferredFramesPerSecond:);  
        SEL swizSel = @selector(kzig_setPreferredFramesPerSecond:);  
  
        Method origMethod = class_getInstanceMethod(cls, origSel);  
        Method swizMethod = class_getInstanceMethod(cls, swizSel);  
  
        if (origMethod && swizMethod) {  
            method_exchangeImplementations(origMethod, swizMethod);  
        }  
    });  
}  
  
- (void)kzig_setPreferredFramesPerSecond:(NSInteger)fps {  
    if (gCurrentMode == KzigLockMode60Hz) {  
        [self kzig_setPreferredFramesPerSecond:60];  
    } else if (gCurrentMode == KzigLockMode120Hz) {  
        [self kzig_setPreferredFramesPerSecond:120];  
    } else {  
        [self kzig_setPreferredFramesPerSecond:fps];  
    }  
}  
  
@end  
  
#pragma mark - Floating Glass Overlay  
  
@interface KzigOverlay : NSObject  
+ (void)showOverlay;  
@end  
  
@implementation KzigOverlay  
  
static UIView *pillContainer = nil;  
static UILabel *fpsLabel = nil;  
static UILabel *modeBadge = nil;  
static CADisplayLink *fpsMonitorLink = nil;  
static CFTimeInterval lastTimestamp = 0;  
static NSInteger frameCounter = 0;  
  
+ (void)showOverlay {  
    dispatch_async(dispatch_get_main_queue(), ^{  
        UIWindow *window = nil;  
        if (@available(iOS 13.0, *)) {  
            for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {  
                if (scene.activationState == UISceneActivationStateForegroundActive && [scene isKindOfClass:[UIWindowScene class]]) {  
                    window = scene.windows.firstObject;  
                    break;  
                }  
            }  
        }  
        if (!window) {  
            window = [UIApplication sharedApplication].keyWindow;  
        }  
        if (!window && [UIApplication sharedApplication].windows.count > 0) {  
            window = [UIApplication sharedApplication].windows.firstObject;  
        }  
        if (!window || pillContainer) return;  
  
        // Glass Capsule Container  
        pillContainer = [[UIView alloc] initWithFrame:CGRectMake(20, 120, 110, 36)];  
        pillContainer.backgroundColor = [UIColor colorWithRed:0.05 green:0.12 blue:0.18 alpha:0.45];  
        pillContainer.layer.cornerRadius = 18;  
        pillContainer.layer.borderWidth = 1.2;  
        pillContainer.layer.borderColor = [UIColor colorWithRed:0.0 green:0.9 blue:0.5 alpha:0.65].CGColor;  
        pillContainer.clipsToBounds = YES;  
  
        // Blur effect  
        UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];  
        UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blur];  
        blurView.frame = pillContainer.bounds;  
        blurView.userInteractionEnabled = NO;  
        [pillContainer addSubview:blurView];  
  
        // FPS Readout  
        fpsLabel = [[UILabel alloc] initWithFrame:CGRectMake(8, 0, 50, 36)];  
        fpsLabel.text = @"-- FPS";  
        fpsLabel.textColor = [UIColor whiteColor];  
        fpsLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];  
        fpsLabel.textAlignment = NSTextAlignmentLeft;  
        fpsLabel.userInteractionEnabled = NO;  
        [pillContainer addSubview:fpsLabel];  
  
        // Mode Badge  
        modeBadge = [[UILabel alloc] initWithFrame:CGRectMake(58, 6, 44, 24)];  
        modeBadge.text = @"60Hz";  
        modeBadge.textColor = [UIColor colorWithRed:0.0 green:1.0 blue:0.5 alpha:1.0];  
        modeBadge.backgroundColor = [UIColor colorWithRed:0.0 green:1.0 blue:0.5 alpha:0.15];  
        modeBadge.layer.cornerRadius = 12;  
        modeBadge.layer.borderWidth = 0.8;  
        modeBadge.layer.borderColor = [UIColor colorWithRed:0.0 green:1.0 blue:0.5 alpha:0.4].CGColor;  
        modeBadge.clipsToBounds = YES;  
        modeBadge.font = [UIFont systemFontOfSize:10 weight:UIFontWeightHeavy];  
        modeBadge.textAlignment = NSTextAlignmentCenter;  
        modeBadge.userInteractionEnabled = NO;  
        [pillContainer addSubview:modeBadge];  
  
        // Tap to Switch Mode  
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap)];  
        [pillContainer addGestureRecognizer:tap];  
  
        // Pan to Drag  
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];  
        [pillContainer addGestureRecognizer:pan];  
  
        [window addSubview:pillContainer];  
  
        // Monitor Display Link  
        fpsMonitorLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];  
        [fpsMonitorLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];  
    });  
}  
  
+ (void)handleTap {  
    // Cycle modes: 60Hz -> 120Hz -> Unlocked -> 60Hz  
    if (gCurrentMode == KzigLockMode60Hz) {  
        gCurrentMode = KzigLockMode120Hz;  
        gTargetFPS = 120;  
        modeBadge.text = @"120Hz";  
        modeBadge.textColor = [UIColor colorWithRed:0.2 green:0.8 blue:1.0 alpha:1.0];  
        modeBadge.backgroundColor = [UIColor colorWithRed:0.2 green:0.8 blue:1.0 alpha:0.18];  
        modeBadge.layer.borderColor = [UIColor colorWithRed:0.2 green:0.8 blue:1.0 alpha:0.5].CGColor;  
        pillContainer.layer.borderColor = [UIColor colorWithRed:0.2 green:0.8 blue:1.0 alpha:0.7].CGColor;  
    } else if (gCurrentMode == KzigLockMode120Hz) {  
        gCurrentMode = KzigLockModeUnlocked;  
        gTargetFPS = 0;  
        modeBadge.text = @"AUTO";  
        modeBadge.textColor = [UIColor colorWithRed:1.0 green:0.75 blue:0.2 alpha:1.0];  
        modeBadge.backgroundColor = [UIColor colorWithRed:1.0 green:0.75 blue:0.2 alpha:0.18];  
        modeBadge.layer.borderColor = [UIColor colorWithRed:1.0 green:0.75 blue:0.2 alpha:0.5].CGColor;  
        pillContainer.layer.borderColor = [UIColor colorWithRed:1.0 green:0.75 blue:0.2 alpha:0.7].CGColor;  
    } else {  
        gCurrentMode = KzigLockMode60Hz;  
        gTargetFPS = 60;  
        modeBadge.text = @"60Hz";  
        modeBadge.textColor = [UIColor colorWithRed:0.0 green:1.0 blue:0.5 alpha:1.0];  
        modeBadge.backgroundColor = [UIColor colorWithRed:0.0 green:1.0 blue:0.5 alpha:0.15];  
        modeBadge.layer.borderColor = [UIColor colorWithRed:0.0 green:1.0 blue:0.5 alpha:0.4].CGColor;  
        pillContainer.layer.borderColor = [UIColor colorWithRed:0.0 green:0.9 blue:0.5 alpha:0.65].CGColor;  
    }  
}  
  
+ (void)handlePan:(UIPanGestureRecognizer *)pan {  
    UIView *view = pan.view;  
    CGPoint translation = [pan translationInView:view.superview];  
    view.center = CGPointMake(view.center.x + translation.x, view.center.y + translation.y);  
    [pan setTranslation:CGPointZero inView:view.superview];  
}  
  
+ (void)tick:(CADisplayLink *)link {  
    if (lastTimestamp == 0) {  
        lastTimestamp = link.timestamp;  
        return;  
    }  
    frameCounter++;  
    CFTimeInterval delta = link.timestamp - lastTimestamp;  
    if (delta >= 1.0) {  
        double currentFPS = frameCounter / delta;  
        frameCounter = 0;  
        lastTimestamp = link.timestamp;  
        fpsLabel.text = [NSString stringWithFormat:@"%.0f FPS", currentFPS];  
    }  
}  
  
@end  
  
#pragma mark - Constructor Entry Point  
  
__attribute__((constructor))  
static void kzig_init(void) {  
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification  
                                                      object:nil  
                                                       queue:[NSOperationQueue mainQueue]  
                                                  usingBlock:^(NSNotification * _Nonnull note) {  
        [KzigOverlay showOverlay];  
    }];  
}
