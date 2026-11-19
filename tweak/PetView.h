#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, DSPetState) {
    DSPetStateIdle = 0,
    DSPetStateDragging,
    DSPetStateTapped,
};

// 桌宠视图：拖拽、点击、动画播放与序列帧资源读取。
// 行为参数来自 docs/pet-core-port-spec.md（逐行读 dsh-pet 源码得出）。
@interface PetView : UIView

@property (nonatomic, copy, nullable) void (^onTap)(PetView *petView);
@property (nonatomic, copy, nullable) void (^onDragStateChanged)(PetView *petView, DSPetState state);
@property (nonatomic, assign, readonly) DSPetState state;
@property (nonatomic, strong, readonly) UIImageView *frameImageView;

- (instancetype)initWithDefaultSize;

// 手势绑定（init 内已调用；重复调用幂等）。
- (void)bindPanGesture;
- (void)bindTapGesture;

// 动画：按名字从资源目录加载序列帧并循环/单次播放。
// name 为转码产物目录名（中文动画名，如「待机呼吸休闲」「点击回应-开心跃动」）。
- (void)playAnimationNamed:(NSString *)name;
- (void)playAnimationNamed:(NSString *)name once:(BOOL)once;
- (void)startAnimation;      // 进入 idle 随机链
- (void)stopAnimation;

// 枚举资源根目录下所有动画目录名（每个目录含 frames/ 与 anim.json）。
- (NSArray<NSString *> *)availableAnimationNames;

// 约束中心点，使宠物不被拖出屏幕（保留 24pt 可达余量）。
- (void)clampCenterToScreen;

// 释放序列帧缓存（收到内存警告时由 PetManager 调用）。
- (void)clearFrameCache;

@end

NS_ASSUME_NONNULL_END
