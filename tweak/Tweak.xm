#import <UIKit/UIKit.h>
#import "PetManager.h"

// ---------------------------------------------------------------------
// SpringBoard 私有类声明（仅用于让 Logos 编译通过）
// 【需真机验证】以下方法名/签名来自 docs/springboard-re.md §2.1 §6，
// 基于公开资料整理，尚未在本机/真机 dump 确认。
// 若目标 iOS 实际调用 -_applicationDidFinishLaunching，请追加对应 hook。
// ---------------------------------------------------------------------
@interface SpringBoard : UIApplication
- (void)applicationDidFinishLaunching:(id)application;           // 需真机验证
- (void)applicationDidBecomeActive:(id)application;              // 需真机验证
- (void)applicationWillResignActive:(id)application;             // 需真机验证
@end

%ctor {
    NSLog(@"[dshpet] tweak loaded (方案A:独立 passthrough window)");
    // 可靠性兜底：不依赖猜测 SpringBoard 私有方法名，直接监听 UIKit
    // 的 DidFinishLaunching 通知（SpringBoard 作为 UIApplication 会发出）。
    // PetManager.start 内部有 started 保护，重复触发安全。
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
        object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        NSLog(@"[dshpet] didFinishLaunching notification received");
        [[PetManager sharedInstance] start];
    }];
    // 再兜一次：延迟 2s 强制 start，覆盖通知在 tweak 加载前已发出的情况。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0*NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [[PetManager sharedInstance] start];
        [[PetManager sharedInstance] show];
        NSLog(@"[dshpet] delayed start fallback fired");
    });
}

// ---------------------------------------------------------------------
// 推荐方案 A：在 SpringBoard 启动完成时创建独立透明 passthrough window。
// 挂载点稳定，与 SBHomeScreenViewController 的 view 层级解耦。
// ---------------------------------------------------------------------
%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {          // 需真机验证
    %orig;
    // dispatch_once 在 PetManager 内部，重复 hook 也不会建多个 window。
    [[PetManager sharedInstance] start];
}

- (void)applicationDidBecomeActive:(id)application {             // 需真机验证
    %orig;
    [[PetManager sharedInstance] resume];   // 回桌面：恢复显示
}

- (void)applicationWillResignActive:(id)application {            // 需真机验证
    %orig;
    [[PetManager sharedInstance] suspend];  // 进 App：隐藏窗口，不抢焦点
}

%end

// ---------------------------------------------------------------------
// 备选方案 B（首版不启用）：hook SBHomeScreenViewController -viewDidLoad，
// 调 [[PetManager sharedInstance] attachToView:self.view]。
// 【需真机验证】SBHomeScreenViewController 类名与方法是否存在。
// 进入文件夹 / 搜索页可能丢失宠物视图，故仅作为 A 失效时的回退。
// ---------------------------------------------------------------------
/*
@interface SBHomeScreenViewController : UIViewController @end   // 需真机验证
%hook SBHomeScreenViewController
- (void)viewDidLoad {                                            // 需真机验证
    %orig;
    [[PetManager sharedInstance] attachToView:self.view];
}
%end
*/
