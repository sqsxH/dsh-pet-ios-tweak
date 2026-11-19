#import "PetView.h"
#import "PetManager.h"
#import "PetCompat.h"
#include <math.h>   // hypot()

// =====================================================================
// 行为常量——来自 docs/pet-core-port-spec.md（源码逐行核对）
// 来自 shared/constants.ts / motion/drag.ts / shared/physics/constants.ts
// =====================================================================
static const CGFloat kDragThresholdPt   = 5.0;    // 位移≥5pt 才算拖拽
static const NSTimeInterval kJustDraggedSec = 0.1; // 松手后 100ms 内抑制点击
static const CGFloat kMinReachablePt    = 24.0;   // 拖到边界仍保留 24pt 可见
static const CGFloat kSpringK           = 200.0;  // 松手回弹（过阻尼）
static const CGFloat kSpringC           = 30.0;   // ζ≈1.06
static const NSTimeInterval kClickHoldSec = 0.22; // 点击态 Q 弹时长（220ms）

// 640×360 画布上的命中盒 → 换算到实际画框
// hitRect = {x:0.3125*size, y:bottomPad+0.1389*height, w:0.375*size, h:0.7917*height}
static const CGFloat kHitX = 0.3125, kHitW = 0.375, kHitY = 0.1389, kHitH = 0.7917;
static const CGFloat kBodyAspect = 9.0 / 16.0;    // height = size * 9/16

@interface PetView ()
@property (nonatomic, assign, readwrite) DSPetState state;
@property (nonatomic, strong, readwrite) UIImageView *frameImageView;
@property (nonatomic, strong) UIPanGestureRecognizer *panGesture;
@property (nonatomic, strong) UITapGestureRecognizer *tapGesture;
@property (nonatomic, strong) UIView *hitAreaView;    // 命中区透明 view（收点击）
@property (nonatomic, assign) BOOL animationEnabled;
@property (nonatomic, assign) BOOL dragging;
@property (nonatomic, assign) CFTimeInterval lastDragEndTime;
@property (nonatomic, strong) NSString *currentAnimation;
@property (nonatomic, assign) NSUInteger generation;  // 防旧帧：只增
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSArray<UIImage *> *> *frameCache;
@property (nonatomic, strong) NSOperationQueue *loadQueue;
@end

@implementation PetView

- (instancetype)initWithDefaultSize {
    // 首版画框：按 PET_REF_WIDTH=462 的 9/16 比例 ≈ 462×260；展示缩到 160 宽。
    // 【需真机验证】实际展示尺寸与位置随目标机屏幕微调。
    CGFloat displayW = 160.0, displayH = displayW * kBodyAspect;
    self = [super initWithFrame:CGRectMake(0, 0, displayW, displayH)];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = YES;
        self.state = DSPetStateIdle;
        self.frameCache = [NSMutableDictionary dictionary];
        self.loadQueue = [[NSOperationQueue alloc] init];
        self.loadQueue.maxConcurrentOperationCount = 1;

        UIImageView *iv = [[UIImageView alloc] initWithFrame:self.bounds];
        iv.contentMode = UIViewContentModeScaleAspectFit;
        iv.backgroundColor = [UIColor clearColor];
        iv.userInteractionEnabled = NO;   // 视频/帧 layer 的 alpha 不参与 hitTest
        [self addSubview:iv];
        self.frameImageView = iv;

        // 命中区透明 view：仅它响应点击，避免整块透明画框都可点。
        CGFloat bw = CGRectGetWidth(self.bounds), bh = CGRectGetHeight(self.bounds);
        CGFloat bottomPad = bh * (30.0 / 360.0);
        self.hitAreaView = [[UIView alloc] initWithFrame:CGRectMake(kHitX*bw, bottomPad+kHitY*bh, kHitW*bw, kHitH*bh)];
        self.hitAreaView.backgroundColor = [UIColor clearColor];
        self.hitAreaView.userInteractionEnabled = YES;
        [self addSubview:self.hitAreaView];

        [self bindPanGesture];
        [self bindTapGesture];
    }
    return self;
}

#pragma mark - 手势

- (void)bindPanGesture {
    if (self.panGesture) { return; }
    self.panGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(_handlePan:)];
    self.panGesture.minimumNumberOfTouches = 1;
    [self addGestureRecognizer:self.panGesture];
}

- (void)bindTapGesture {
    if (self.tapGesture) { return; }
    self.tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(_handleTap:)];
    self.tapGesture.numberOfTapsRequired = 1;
    [self.hitAreaView addGestureRecognizer:self.tapGesture];
}

- (void)_handlePan:(UIPanGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        self.dragging = YES;
        self.state = DSPetStateDragging;
        [self playAnimationNamed:@"被鼠标拖拽悬空反馈"];
        if (self.onDragStateChanged) { self.onDragStateChanged(self, self.state); }
        return;
    }

    CGPoint delta = [gesture translationInView:self.superview];
    // 阈值：位移不足不移动（避免点击误触发拖拽）
    if (gesture.state == UIGestureRecognizerStateChanged &&
        hypot(delta.x, delta.y) < kDragThresholdPt) {
        return;
    }
    CGPoint center = self.center;
    center.x += delta.x; center.y += delta.y;
    self.center = center;
    [gesture setTranslation:CGPointZero inView:self.superview];
    [self clampCenterToScreen];

    if (gesture.state == UIGestureRecognizerStateEnded ||
        gesture.state == UIGestureRecognizerStateCancelled) {
        self.dragging = NO;
        self.lastDragEndTime = CACurrentMediaTime();
        // 过阻尼弹簧回弹到安全区（首版用 UIView 动画近似；精确 SPRING_K/C 见 core-spec §5）
        [UIView animateWithDuration:0.25 delay:0
             usingSpringWithDamping:1.0 initialSpringVelocity:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{ [self clampCenterToScreen]; }
                     completion:nil];
        self.state = DSPetStateIdle;
        [self playAnimationNamed:@"待机呼吸休闲"];
        if (self.onDragStateChanged) { self.onDragStateChanged(self, self.state); }
    }
}

- (void)_handleTap:(UIGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded) { return; }
    // 松手后 100ms 内视为拖拽尾巴，抑制点击
    if (CACurrentMediaTime() - self.lastDragEndTime < kJustDraggedSec) { return; }
    self.state = DSPetStateTapped;
    if (self.onTap) { self.onTap(self); }

    // 5 选 1 点击回应（core-spec §3.4），播完回 idle
    NSArray *clicks = @[@"点击回应-开心跃动", @"点击回应-害羞惊讶", @"点击回应-傲娇生气",
                        @"点击回应-挠痒咯咯笑", @"点击回应-元气挥手"];
    NSString *pick = clicks[arc4random_uniform((uint32_t)clicks.count)];
    [self playAnimationNamed:pick once:YES];

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kClickHoldSec*NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (self && self.state == DSPetStateTapped) {
            self.state = DSPetStateIdle;
            [self playAnimationNamed:@"待机呼吸休闲"];
        }
    });
}

#pragma mark - 边界约束

- (void)clampCenterToScreen {
    CGRect screen = [[UIScreen mainScreen] bounds];
    // 【需真机验证】安全区随机型变化；留 24pt 可达余量
    UIEdgeInsets safe = UIEdgeInsetsMake(60.0, kMinReachablePt, 40.0, kMinReachablePt);
    CGFloat halfW = CGRectGetWidth(self.bounds)/2.0, halfH = CGRectGetHeight(self.bounds)/2.0;
    CGFloat minX = screen.origin.x + safe.left + halfW;
    CGFloat maxX = CGRectGetMaxX(screen) - safe.right - halfW;
    CGFloat minY = screen.origin.y + safe.top + halfH;
    CGFloat maxY = CGRectGetMaxY(screen) - safe.bottom - halfH;
    CGPoint c = self.center;
    c.x = MIN(MAX(c.x, minX), maxX);
    c.y = MIN(MAX(c.y, minY), maxY);
    self.center = c;
}

#pragma mark - 动画播放（序列帧；借鉴 A/B 双缓冲的「只增 generation 防旧帧」）

- (void)playAnimationNamed:(NSString *)name {
    [self playAnimationNamed:name once:NO];
}

- (void)playAnimationNamed:(NSString *)name once:(BOOL)once {
    if (name.length == 0) { return; }
    if ([self.currentAnimation isEqualToString:name] && !once) { return; } // 防重

    self.currentAnimation = name;
    NSUInteger gen = ++self.generation;                 // 只增：旧异步加载回调一律作废

    NSArray<UIImage *> *cached = self.frameCache[name];
    if (cached.count > 0) {
        [self _applyFrames:cached once:once gen:gen name:name];
        return;
    }

    // 异步加载 <资源根>/<动画名>/frames/frame_%05d.webp（或 png）
    NSString *root = [PetManager resourceDirectory];
    NSString *framesDir = [[root stringByAppendingPathComponent:name] stringByAppendingPathComponent:@"frames"];
    [self.loadQueue addOperationWithBlock:^{
        NSMutableArray<UIImage *> *frames = [NSMutableArray array];
        NSFileManager *fm = [NSFileManager defaultManager];
        NSArray<NSString *> *files = [[fm contentsOfDirectoryAtPath:framesDir error:nil] sortedArrayUsingSelector:@selector(compare:)];
        for (NSString *f in files) {
            if ([[f pathExtension] isEqualToString:@"webp"] || [[f pathExtension] isEqualToString:@"png"]) {
                UIImage *img = [UIImage imageWithContentsOfFile:[framesDir stringByAppendingPathComponent:f]];
                if (img) { [frames addObject:img]; }
            }
        }
        [[NSOperationQueue mainQueue] addOperationWithBlock:^{
            if (gen != self.generation) { return; }      // 旧帧丢弃
            if (frames.count == 0) {
                NSLog(@"[dshpet] 无帧：%@（目录：%@）", name, framesDir);
                return;
            }
            self.frameCache[name] = frames;
            [self _applyFrames:frames once:once gen:gen name:name];
        }];
    }];
}

- (void)_applyFrames:(NSArray<UIImage *> *)frames once:(BOOL)once gen:(NSUInteger)gen name:(NSString *)name {
    if (gen != self.generation) { return; }
    UIImageView *iv = self.frameImageView;
    iv.animationImages = frames;
    iv.animationDuration = MAX(frames.count/24.0, 0.04); // fps=24（转码默认）
    iv.animationRepeatCount = once ? 1 : 0;
    [iv startAnimating];
    NSLog(@"[dshpet] 播放 %@（%lu 帧，%@）", name, (unsigned long)frames.count, once ? @"单次" : @"循环");
}

- (void)startAnimation {
    self.animationEnabled = YES;
    [self playAnimationNamed:@"待机呼吸休闲"];
}

- (void)stopAnimation {
    self.animationEnabled = NO;
    self.generation++;                      // 作废在途加载
    [self.frameImageView stopAnimating];
}

#pragma mark - 资源读取

- (NSArray<NSString *> *)availableAnimationNames {
    NSString *dir = [PetManager resourceDirectory];   // ROOT_PATH_NS 已处理 rootless 前缀
    NSArray<NSString *> *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    BOOL isDir = NO;
    for (NSString *item in items ?: @[]) {
        NSString *p = [dir stringByAppendingPathComponent:item];
        if ([[NSFileManager defaultManager] fileExistsAtPath:p isDirectory:&isDir] && isDir) {
            [names addObject:item];
        }
    }
    return names;
}

- (void)clearFrameCache {
    [self.frameCache removeAllObjects];     // 释放帧缓存
    self.frameImageView.animationImages = nil;
    self.currentAnimation = nil;            // 允许下次同名调用重新加载
}

@end
