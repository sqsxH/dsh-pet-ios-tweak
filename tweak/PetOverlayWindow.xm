#import "PetOverlayWindow.h"
#import "PetView.h"

// 判断 view 是否是 ancestor 本身或其后代。
static BOOL DSPViewIsDescendantOfViewOrSelf(UIView *view, UIView *ancestor) {
    for (UIView *v = view; v != nil; v = v.superview) {
        if (v == ancestor) { return YES; }
    }
    return NO;
}

@implementation PetOverlayWindow

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = YES;
        self.opaque = NO;

        // windowLevel 起点：UIWindowLevelNormal + 1，盖在图标层之上。
        // 【需真机验证】若被状态栏遮挡，上调到 UIWindowLevelStatusBar - 1；
        // 不要用 UIWindowLevelAlert，会盖住系统弹窗/来电。
        self.windowLevel = UIWindowLevelNormal + 1;
    }
    return self;
}

+ (instancetype)windowWithPetView:(PetView *)petView {
    PetOverlayWindow *window = [[self alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    window.petRootView = petView;

    // 透明宿主 VC：rootViewController.view 必须 clearColor 且可交互。
    UIViewController *hostVC = [[UIViewController alloc] init];
    hostVC.view.backgroundColor = [UIColor clearColor];
    hostVC.view.userInteractionEnabled = YES;
    [hostVC.view addSubview:petView];
    window.rootViewController = hostVC;

    // 只置 hidden = NO，不调用 makeKeyAndVisible，避免抢 SpringBoard keyWindow。
    window.hidden = NO;
    return window;
}

#pragma mark - 事件穿透

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    UIView *pet = self.petRootView;
    if (hit != nil && pet != nil && DSPViewIsDescendantOfViewOrSelf(hit, pet)) {
        return hit;                 // 命中宠物：消费事件
    }
    return nil;                     // 其余区域穿透给 SpringBoard 桌面
}

// 【需真机验证】iOS 18+ UIKit 加强了 window isolation，hitTest 穿透行为
// 可能变化。若目标机是 iOS 18 且穿透失效，退到方案 B 或改用
// 「宠物尺寸的小 window + 透明占位大 window」/ UITouch 转发。
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return [super pointInside:point withEvent:event];
}

@end
