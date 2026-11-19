#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@class PetOverlayWindow;
@class PetView;

NS_ASSUME_NONNULL_BEGIN

// 单例：负责悬浮 window 的创建/销毁、前后台与旋转生命周期。
// 所有公开方法都可重复调用（内部做了状态保护）。
@interface PetManager : NSObject

+ (instancetype)sharedInstance;

// 方案 A：创建并显示 PetOverlayWindow（幂等）。
- (void)start;
- (void)stop;

// 显式显示/隐藏（不改 window 是否存在的状态）。
- (void)show;
- (void)hide;

// 由 SpringBoard 生命周期 hook 调用：回桌面 / 离开桌面。
- (void)resume;
- (void)suspend;

// 方案 B（备选、需真机验证）：把宠物 view 直接挂到桌面 VC 的 view 上。
- (void)attachToView:(UIView *)hostView;

// 资源根目录（ROOT_PATH_NS 包装，rootless 下自动指向 /var/jb）。
+ (NSString *)resourceDirectory;

@property (nonatomic, strong, readonly, nullable) PetOverlayWindow *overlayWindow;
@property (nonatomic, strong, readonly, nullable) PetView *petView;

@end

NS_ASSUME_NONNULL_END
