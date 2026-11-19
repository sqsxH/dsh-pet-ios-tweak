#import <UIKit/UIKit.h>

@class PetView;

NS_ASSUME_NONNULL_BEGIN

// 透明、可穿透的悬浮窗口（方案 A 核心）。
// 非宠物区域的触摸通过 hitTest 返回 nil 穿透给 SpringBoard 桌面。
@interface PetOverlayWindow : UIWindow

// 用于 hitTest 判定的根视图（通常是 PetView 或其容器）。weak 避免循环引用。
@property (nonatomic, weak, nullable) UIView *petRootView;

+ (instancetype)windowWithPetView:(PetView *)petView;

@end

NS_ASSUME_NONNULL_END
