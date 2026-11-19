#import "PetManager.h"
#import "PetOverlayWindow.h"
#import "PetView.h"
#import "PetCompat.h"

@interface PetManager ()
@property (nonatomic, strong, readwrite) PetOverlayWindow *overlayWindow;
@property (nonatomic, strong, readwrite) PetView *petView;
@property (nonatomic, assign) BOOL started;
@property (nonatomic, assign) BOOL suspended;
@property (nonatomic, weak) UIView *attachedHostView;   // 方案 B 用
@end

@implementation PetManager

+ (instancetype)sharedInstance {
    static PetManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

+ (NSString *)resourceDirectory {
    // PET_RESOURCE_DIR 由 Makefile 注入；ROOT_PATH_NS 处理 rootless / roothide 前缀。
    // 与 tools/transcode-webm 的 OUT_ROOT 一致：<资源根>/<动画名>/frames/frame_%05d.webp。
#ifndef PET_RESOURCE_DIR
#define PET_RESOURCE_DIR "/Library/Application Support/dsh-pet/"
#endif
    return ROOT_PATH_NS(@PET_RESOURCE_DIR);
}

#pragma mark - 生命周期

- (void)start {
    if (self.started) { return; }
    self.started = YES;

    // UI 操作必须回主线程；SpringBoard 回调通常已在主线程，这里仍做保护。
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _createOverlayIfNeeded];
        });
    } else {
        [self _createOverlayIfNeeded];
    }

    [self _registerNotifications];
    NSLog(@"[dshpet] started, resource dir = %@", [[self class] resourceDirectory]);
}

- (void)stop {
    if (!self.started) { return; }
    self.started = NO;
    [self _unregisterNotifications];
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.overlayWindow.hidden = YES;
            self.overlayWindow = nil;
            self.petView = nil;
        });
    } else {
        self.overlayWindow.hidden = YES;
        self.overlayWindow = nil;
        self.petView = nil;
    }
}

- (void)_createOverlayIfNeeded {
    if (self.overlayWindow) { return; }

    PetView *pet = [[PetView alloc] initWithDefaultSize];
    self.petView = pet;

    __weak typeof(self) weakSelf = self;
    pet.onTap = ^(PetView *view) {
        // 点击回应动画已由 PetView._handleTap 内部触发（5 选 1 + Q 弹回 idle，
        // 见 docs/pet-core-port-spec.md §3.4），此处只做通知，不重复换源。
        NSLog(@"[dshpet] tap on pet");
        (void)weakSelf;
    };
    pet.onDragStateChanged = ^(PetView *view, DSPetState state) {
        NSLog(@"[dshpet] drag state = %ld", (long)state);
    };

    // 方案 A：独立 window。不要 makeKeyAndVisible，避免抢 SpringBoard 的 keyWindow。
    PetOverlayWindow *window = [PetOverlayWindow windowWithPetView:pet];
    self.overlayWindow = window;
}

#pragma mark - 显示控制

- (void)show {
    self.suspended = NO;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ self.overlayWindow.hidden = NO; });
    } else {
        self.overlayWindow.hidden = NO;
    }
}

- (void)hide {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ self.overlayWindow.hidden = YES; });
    } else {
        self.overlayWindow.hidden = YES;
    }
}

- (void)resume { [self show]; }
- (void)suspend { [self hide]; }

#pragma mark - 备选方案 B

- (void)attachToView:(UIView *)hostView {
    // 【需真机验证】SBHomeScreenViewController/SBIconContentView 的存在与层级。
    // 仅当方案 A 的 passthrough 在目标 iOS 失效时启用。
    if (!hostView) { return; }
    self.attachedHostView = hostView;
    if (!self.petView) {
        self.petView = [[PetView alloc] initWithDefaultSize];
    }
    self.overlayWindow.hidden = YES;             // 关掉独立 window，避免重复显示
    [hostView addSubview:self.petView];
    NSLog(@"[dshpet] attached to host view (方案B，需真机验证)");
}

#pragma mark - 系统通知

- (void)_registerNotifications {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(_onOrientationChange:)
               name:UIDeviceOrientationDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(_onMemoryWarning:)
               name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
    // 【需真机验证】SpringBoard 私有通知（如 SBLockScreenDidUnlockNotification /
    // SBApplicationDidActivateNotification）需 dump 后再补充锁屏/前台精确判定。
}

- (void)_unregisterNotifications {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)_onOrientationChange:(NSNotification *)note {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self _onOrientationChange:note]; });
        return;
    }
    // 重新取屏幕 bounds，并约束宠物不出界。
    self.overlayWindow.frame = [[UIScreen mainScreen] bounds];
    [self.petView clampCenterToScreen];
}

- (void)_onMemoryWarning:(NSNotification *)note {
    // PetView 实现 clearFrameCache 释放 frameCache；RC 通知不自动转发给
    // 非 root 的 UIView，这里主动清空一次。
    [self.petView clearFrameCache];
    NSLog(@"[dshpet] memory warning, frame cache released");
}

@end
