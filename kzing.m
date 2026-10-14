#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

typedef NS_ENUM(NSInteger, KzigLockMode) {
    KzigLockMode60Hz = 0,
    KzigLockMode120Hz,
    KzigLockModeUnlocked
};

static volatile KzigLockMode gCurrentMode = KzigLockMode60Hz;
static volatile NSInteger gTargetFPS = 60;

#pragma mark - CADisplayLink Swizzling for Global Frame Lock

@implementation CADisplayLink (KzigFPSHook)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = [self class];
        
        // Swizzle setPreferredFramesPerSecond:
        SEL origSel = @selector(setPreferredFramesPerSecond:);
        SEL swizSel = @selector(kzig_setPreferredFramesPerSecond:);
        Method origMethod = class_getInstanceMethod(cls, origSel);
        Method swizMethod = class_getInstanceMethod(cls, swizSel);
        if (origMethod && swizMethod) {
            method_exchangeImplementations(origMethod, swizMethod);
        }
        
        // Also swizzle preferredFrameRateRange for iOS 15+ ProMotion support if available
        SEL rangeOrigSel = NSSelectorFromString(@"setPreferredFrameRateRange:");
        SEL rangeSwizSel = @selector(kzig_setPreferredFrameRateRange:);
        Method rangeOrigMethod = class_getInstanceMethod(cls, rangeOrigSel);
        Method rangeSwizMethod = class_getInstanceMethod(cls, rangeSwizSel);
        if (rangeOrigMethod && rangeSwizMethod) {
            method_exchangeImplementations(rangeOrigMethod, rangeSwizMethod);
        }
    });
}

- (void)kzig_setPreferredFramesPerSecond:(NSInteger)fps {
    KzigLockMode mode = gCurrentMode;
    if (mode == KzigLockMode60Hz) {
        [self kzig_setPreferredFramesPerSecond:60];
    } else if (mode == KzigLockMode120Hz) {
        [self kzig_setPreferredFramesPerSecond:120];
    } else {
        [self kzig_setPreferredFramesPerSecond:fps];
    }
}

- (void)kzig_setPreferredFrameRateRange:(CMFrameRateRange)range {
    KzigLockMode mode = gCurrentMode;
    if (mode == KzigLockMode60Hz) {
        range.minimum = 60.0; range.maximum = 60.0; range.preferred = 60.0;
        [self kzig_setPreferredFrameRateRange:range];
    } else if (mode == KzigLockMode120Hz) {
        range.minimum = 120.0; range.maximum = 120.0; range.preferred = 120.0;
        [self kzig_setPreferredFrameRateRange:range];
    } else {
        [self kzig_setPreferredFrameRateRange:range];
    }
}

@end

#pragma mark - Floating Glass Overlay (Instance-based)

@interface KzigOverlayManager : NSObject
+ (instancetype)sharedInstance;
- (void)showOverlay;
@end

@implementation KzigOverlayManager {
    UIView *pillContainer;
    UILabel *fpsLabel;
    UILabel *modeBadge;
    CADisplayLink *fpsMonitorLink;
    CFTimeInterval lastTimestamp;
    NSInteger frameCounter;
}

+ (instancetype)sharedInstance {
    static KzigOverlayManager *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[KzigOverlayManager alloc] init];
    });
    return sharedInstance;
}

- (void)showOverlay {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->pillContainer) return;

        UIWindow *window = nil;
        if (@available(iOS 13.0, *)) {
            for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if (scene.activationState == UISceneActivationStateForegroundActive) {
                    for (UIWindow *w in scene.windows) {
                        if (w.isKeyWindow) {
                            window = w;
                            break;
                        }
                    }
                    if (!window) {
                        window = scene.windows.firstObject;
                    }
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
        if (!window) return;

        // Glass Capsule Container
        self->pillContainer = [[UIView alloc] initWithFrame:CGRectMake(20, 120, 110, 36)];
        self->pillContainer.backgroundColor = [UIColor colorWithRed:0.05 green:0.12 blue:0.18 alpha:0.45];
        self->pillContainer.layer.cornerRadius = 18;
        self->pillContainer.layer.borderWidth = 1.2;
        self->pillContainer.layer.borderColor = [UIColor colorWithRed:0.0 green:0.9 blue:0.5 alpha:0.65].CGColor;
        self->pillContainer.clipsToBounds = YES;

        // Blur effect
        UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
        UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
        blurView.frame = self->pillContainer.bounds;
        blurView.userInteractionEnabled = NO;
        [self->pillContainer addSubview:blurView];

        // FPS Readout
        self->fpsLabel = [[UILabel alloc] initWithFrame:CGRectMake(8, 0, 50, 36)];
        self->fpsLabel.text = @"-- FPS";
        self->fpsLabel.textColor = [UIColor whiteColor];
        self->fpsLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
        self->fpsLabel.textAlignment = NSTextAlignmentLeft;
        self->fpsLabel.userInteractionEnabled = NO;
        [self->pillContainer addSubview:self->fpsLabel];

        // Mode Badge
        self->modeBadge = [[UILabel alloc] initWithFrame:CGRectMake(58, 6, 44, 24)];
        self->modeBadge.text = @"60Hz";
        self->modeBadge.textColor = [UIColor colorWithRed:0.0 green:1.0 blue:0.5 alpha:1.0];
        self->modeBadge.backgroundColor = [UIColor colorWithRed:0.0 green:1.0 blue:0.5 alpha:0.15];
        self->modeBadge.layer.cornerRadius = 12;
        self->modeBadge.layer.borderWidth = 0.8;
        self->modeBadge.layer.borderColor = [UIColor colorWithRed:0.0 green:1.0 blue:0.5 alpha:0.4].CGColor;
        self->modeBadge.clipsToBounds = YES;
        self->modeBadge.font = [UIFont systemFontOfSize:10 weight:UIFontWeightHeavy];
        self->modeBadge.textAlignment = NSTextAlignmentCenter;
        self->modeBadge.userInteractionEnabled = NO;
        [self->pillContainer addSubview:self->modeBadge];

        // Gestures targeting instance safely
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
        [self->pillContainer addGestureRecognizer:tap];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self->pillContainer addGestureRecognizer:pan];

        [window addSubview:self->pillContainer];

        // Monitor Display Link
        self->fpsMonitorLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
        [self->fpsMonitorLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    });
}

- (void)handleTap:(UITapGestureRecognizer *)tap {
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

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    UIView *view = pan.view;
    CGPoint translation = [pan translationInView:view.superview];
    view.center = CGPointMake(view.center.x + translation.x, view.center.y + translation.y);
    [pan setTranslation:CGPointZero inView:view.superview];
}

- (void)tick:(CADisplayLink *)link {
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
        [[KzigOverlayManager sharedInstance] showOverlay];
    }];
}
