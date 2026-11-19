# iOS SpringBoard 桌面注入方案（dsh-pet 越狱 tweak）

> 作者：springboard-re（team task-1）
> 状态：**调研草案**。本文所有涉及 SpringBoard 私有类/方法/窗口数值的结论均来自公开越狱开发资料、dumped header 索引与通用 UIKit 机制整理；**本机（Windows + 无 Mac、无真机在旁即时调试）无法实测**，凡标注「需真机验证」的条目必须在越狱 iPhone 上用 class-dump / Frida / 实际注入验证后再落地。
> 目标环境：iOS 15–17（首版建议先锁定一台具体越狱机的 iOS 版本，例如 Dopamine 2 / iOS 16.x），rootless（Dopamine、palera1n）。
> 首版功能范围：桌面悬浮 + 动画 + 拖拽 + 点击。

---

## 0. 结论先行（推荐方案）

**推荐方案**：在 SpringBoard 进程内，hook `SpringBoard` 的 `-applicationDidFinishLaunching:`（以及 `-applicationDidBecomeActive:` 做恢复），在回调里创建一个**独立的、透明的、可穿透的 UIWindow `PetOverlayWindow`**，`windowLevel` 设为高于主屏图标层但低于状态栏/告警层（建议起点：`UIWindowLevelNormal + 1` 起调，见 §3.1），作为桌宠视图的宿主张口。桌宠UIView挂在该 window 的 rootViewController 上；通过覆写 window 的 `-hitTest:withEvent:` 实现「点不到宠物的区域事件穿透给 SpringBoard」，在宠物视图上挂 `UIPanGestureRecognizer` + `UITapGestureRecognizer` 实现拖拽/点击。前后台与锁屏通过监听 UIApplication/SpringBoard 私有通知隐藏/恢复窗口。

**为什么选它**：
- 挂载点稳定（SpringBoard 生命周期方法多年变化小），与根视图控制器结构解耦；
- 独立 window 不依赖 `SBHomeScreenViewController` 的 view 层级，进入文件夹/上滑开 App 时宠物视图不会被系统回收；
- 事件穿透方案成熟（passthrough window 是越狱社区常用的悬浮球/悬浮窗做法）。

**备选方案**（见 §7）：hook `SBHomeScreenViewController -viewDidLoad` 把宠物 view 直接 `addSubview:` 到 `SBIconContentView` 之上——更贴近桌面、随桌面旋转，但生命周期跟随桌面 VC，进入文件夹/搜索页可能消失，且图标布局变动时容易错位。

---

## 1. SpringBoard 窗口层级基础

### 1.1 UIKit 层（确定事实）
- `UIWindow` 是UIView子类，`windowLevel` 类型为 `UIWindow.Level`（`CGFloat`）。公开常量（Apple 文档，确定）：
  - `UIWindowLevelNormal = 0`
  - `UIWindowLevelStatusBar = 1000`
  - `UIWindowLevelAlert = 2000`
- 同一 `UIWindow` 按 `windowLevel` 从低到高叠放；同层级按加入顺序。`makeKeyAndVisible` 会把它设为 keyWindow 并置 hidden=NO；**在 SpringBoard 中不要随意抢占 keyWindow**，否则会破坏系统输入焦点。
- 命中测试链：UIKit 向 window 发送 `-hitTest:withEvent:` → 递归 `-pointInside:withEvent:`。覆写 `-hitTest:` 返回 nil 可让该点事件落到下层 window（事件穿透的核心）。

### 1.2 SpringBoard 私有层（需真机验证类名/方法签名，iOS 版本差异大）
SpringBoard 是 `UIApplication`（或其子类）运行在 `com.apple.springboard` 进程的主对象；桌面由 SpringBoard.framework / SpringBoardUI.framework / BaseBoard.framework（FB 系列）构建。与本项目相关的关键角色：

| 角色 | 说明 | 备注 |
|---|---|---|
| `SpringBoard` | 主 application 对象；`UIApplicationDelegate` 角色。hook `-applicationDidFinishLaunching:` 是最早的稳定时机 | 确定存在；方法签名需 dump 验证 |
| `SBWindow` | SpringBoard 自建 UIWindow 子类，桌面/状态栏/浮层多为其实例 | 私有，需验证 |
| `SBHomeScreenWindow` | 主屏窗口（部分版本） | 命名随版本变化 |
| `SBHomeScreenViewController` | 主屏（桌面）根视图控制器，管理图标页 | 备选注入点 |
| `SBIconContentView` | 承载图标网格的视图，位于主屏 view 层级中 | 备选方案里 addView 的参照物 |
| `SBFolderController` / `SBFolderIconListView` | 文件夹打开时的控制器/视图；进入文件夹会切换层级 | 说明为何 hook 桌面 VC 的方案会「丢宠物」 |
| `FBScene` / `FBWindowScene` / `SBWindowScene` | iOS 13+ 基于 scene 的窗口模型：`FBScene` 描述一个场景，`FBWindowScene` 是其 UIWindow 封装，`SBWindowScene` 是 SpringBoard 特化子类，持有 `keyWindow`/`screen`/`window` | 私有；iOS 15–17 具体实现变化大，**必须 dump 验证** |
| `SBWindowLevel` (enum) | SpringBoard 内部窗口层级枚举（含 `SBWindowLevelHomeScreen`、`SBWindowLevelStatusBar`、`SBWindowLevelAlert` 等） | 数值/枚举名需从 dumped header 确认，**不要硬编码猜测值** |

> ⚠️ 重要假设：iOS 15+ SpringBoard 大量转向 scene 架构，旧教程里「`[[UIApplication sharedApplication] keyWindow] addSubview:`」的直接子视图做法在桌面旋转/进入 App 后可能失效。因此推荐独立 UIWindow 方案而非挂到既有 view。

---

## 2. 注入点分析

### 2.1 推荐：`%hook SpringBoard` `-applicationDidFinishLaunching:`
```objc
%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    // 在这里创建并显示 PetOverlayWindow（见 §3）
    [PetManager sharedInstance]; // 单例内部完成 window 初始化
}
%end
```
- 优点：时机早、稳定、与桌面 VC 生命周期解耦。
- 注意：某些 iOS 版本该方法名可能是 `-applicationDidFinishLaunching:` 或 SpringBoard 私有的 `-_applicationDidFinishLaunching`；**需 dump 确认实际调用哪一个**（见 §6 Frida 观察）。首版可两个都 hook，内部加 dispatch_once 防重复初始化。

### 2.2 备选：`%hook SBHomeScreenViewController` `-viewDidLoad` / `-viewDidAppear:`
```objc
%hook SBHomeScreenViewController
- (void)viewDidLoad {
    %orig;
    [[PetManager sharedInstance] attachToView:self.view];
}
%end
```
- 优点：宠物天然位于桌面坐标系，随桌面旋转。
- 缺点：进入文件夹、搜索页、上滑打开 App 时桌面 VC 的 view 可能被移出层级，宠物会消失；需要额外在 `SBFolderController` 等场景重建。首版不推荐作为主方案。

### 2.3 其它候选（记录供后续研究，首版不用）
- `%hook SBUIController`（桌面/状态栏总控）相关 `-init` 或窗口初始化方法。
- `%hook SBWindowScene` / `FBWindowScene` 的窗口创建方法——可拿到精准的 scene，但需要处理 scene 的创建/销毁通知，复杂度高。
- `%ctor` + `%init` 里直接注册通知，延迟到 SpringBoard 就绪再建 window（避免 applicationDidFinishLaunching 时序差异）。

---

## 3. 悬浮透明窗口实现

### 3.1 windowLevel 取值策略
- 起点建议：`petWindow.windowLevel = UIWindowLevelNormal + 1;`（=1.0），确保盖在桌面图标层（通常 level≈0）之上。
- 若被状态栏遮挡，上调到 `UIWindowLevelStatusBar - 1`（<1000）；若需盖住状态栏用 `UIWindowLevelStatusBar + 1`，但首版不建议（会挡信号/时间）。
- **不要**用 `UIWindowLevelAlert`（2000）+，那会盖住系统弹窗/来电。
- SpringBoard 内部 `SBWindowLevel` 的具体数值**需真机 dump 后确定**；上面用公开 UIWindowLevel 做相对定位，风险最低。

### 3.2 透明与尺寸
```objc
PetOverlayWindow *w = [[PetOverlayWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
w.backgroundColor = [UIColor clearColor];
w.windowLevel = UIWindowLevelNormal + 1;
w.userInteractionEnabled = YES;
w.hidden = NO;                 // 不要 makeKeyAndVisible，避免抢 keyWindow
w.rootViewController = petHostVC; // petHostVC.view 透明，onTop 放宠物 UIView
```
- rootViewController 的 view 背景必须 clearColor，且 `userInteractionEnabled = YES`（否则手势收不到）。
- 保留一个全局强引用（单例），防止 window 被释放。

### 3.3 命中测试 / 事件穿透（passthrough window）
核心：非宠物区域让事件穿透给 SpringBoard（图标仍可点），宠物区域消费事件。
```objc
@implementation PetOverlayWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    // 只有命中宠物视图（或它的子视图）才响应，其余返回 nil 穿透
    if (hit != nil && [self.petRootView isDescendantOfViewOrSelf:hit]) {
        return hit;
    }
    return nil;
}
@end
```
- 辅助判断可用 `CGRectContainsPoint(self.petView.frame, point)`（注意 coordinate 转换到 window）。
- iOS 18 起 UIKit 对窗口隔离更严格，`hitTest:` 行为可能有差异（公开文章提到 iOS 18 的 window isolation 变化）——**若目标机是 iOS 18，需真机验证穿透是否仍成立**，必要时改用「宠物专用小 window（frame=宠物 frame）+ 透明大 window 仅做占位」或 `UITouch` 转发方案。

### 3.4 手势 / 拖拽 / 点击
- 拖拽：`UIPanGestureRecognizer` 绑在宠物 UIView；`translationInView` 累加修改 `center`，`gestureRecognizer.view.center += delta`，`[pan setTranslation:CGPointZero inView:...]`；`UIGestureRecognizerStateBegan/Changed/Ended` 里可驱动不同动画状态（见 task-2 状态机规格）。
- 点击：`UITapGestureRecognizer`，`numberOfTapsRequired = 1`，触发点击回应动画。
- 边界约束：clamp 到 `[[UIScreen mainScreen] bounds]`，留出安全区（顶部状态栏、底部 Home Indicator）。
- 多指/长按按需加 `UILongPressGestureRecognizer`（首版可省）。

---

## 4. 生命周期与前后台

| 事件 | 处理 | 依据 |
|---|---|---|
| SpringBoard 启动完成 | 初始化 window（§2.1） | `-applicationDidFinishLaunching:` |
| App 打开、SpringBoard 退到后台 | 隐藏/降低宠物 window | 监听 `UIApplicationWillResignActiveNotification` / `UIApplicationDidEnterBackgroundNotification`；SpringBoard 特有通知如 `SBApplicationDidActivateNotification`（**需 dump 验证通知名**） |
| 回到桌面 | 恢复显示 | `UIApplicationDidBecomeActiveNotification` / hook `-applicationDidBecomeActive:` |
| 锁屏 / 解锁 | 隐藏/恢复 | SpringBoard 锁屏通知（如 `SBDisplayDidChangeNotification`、`SBLockScreenDidUnlockNotification` 等，**需验证**）；或检测锁屏 window（`SBLockScreenViewController`）存在 |
| 横竖屏旋转 | 重新布局 pet window frame | `UIDeviceOrientationDidChangeNotification` 或 `UIApplicationDidChangeStatusBarOrientationNotification`；重新取 `[[UIScreen mainScreen] bounds]` |
| 内存警告 | 释放可重建资源（动画帧缓存） | `UIApplicationDidReceiveMemoryWarningNotification` |

> 说明：SpringBoard 与前台 App 的「前后台」语义跟普通 App 不同——SpringBoard 进程一直存活，但当用户打开 App 时其 window 会被系统压到下面。首版最省事的判定：hook `-applicationWillResignActive:` / `-applicationDidBecomeActive:`（若被调用）或监听上述 UIApplication 通知即可；更精确判定需用 `SBWorkspace` / `SBSceneManagerCoordinator` 查询 frontmost app（**需验证 API**）。

---

## 5. rootless（Dopamine / palera1n）路径注意事项

1. **根路径是 `/var/jb`**：rootless 把越狱文件系统移到 `/var/jb`。所有「原本写 `/Library/...` 或 `/usr/lib/...`」的地方都要变成 `/var/jb/Library/...`、`/var/jb/usr/lib/...`。
2. **Theos 构建**：Makefile 里设 `THEOS_PACKAGE_SCHEME = rootless`。Theos 会自动：
   - 把 deb 内容加上 `/var/jb` 安装前缀（`THEOS_PACKAGE_INSTALL_PREFIX=/var/jb`）；
   - 用 `@rpath` 替代绝对 install_name，并注入 rpath（rootless v2 同时含 `/var/jb` 与 `@loader_path/.jbroot/`，兼容 roothide 重定位后的 jbroots）；
   - 目标架构设为 `iphoneos-arm64`。
3. **路径宏**：`#import <rootless.h>`，用 `ROOT_PATH` / `ROOT_PATH_NS` 包装路径，例如：
   ```objc
   NSString *res = ROOT_PATH_NS(@"/Library/Application Support/dsh-pet/frames/");
   ```
   这样同一份源码在 rootful / rootless / roothide 下都能得到正确前缀；底层由 libroot 决定真实 jbroot（roothide 会随机化 `/var/jb`，硬编码路径必崩）。
4. **tweak 安装位置**：rootless + ElleKit 下 dylib/plist 经 Theos 打包落在 `/var/jb/Library/MobileSubstrate/DynamicLibraries/`（部分环境也识别 `/var/jb/Library/TweakInject/`）；plist 用 `Filter` → `Bundles` = `com.apple.springboard`。**具体以所用越狱的注入器为准，需真机确认**。
5. **arm64e ABI**：iOS 14+ arm64e 设备（A12+）系统二进制用新 arm64e ABI，构建 tweak 需要新版 ld64（Xcode 自带，未开源）；纯 Windows/WSL 无法原生产出新 ABI——可用 GitHub Actions、macOS VM，或 `allemande`（静态转换旧 ABI），或临时依赖 `oldabi`（仅测试，勿随发布）。此点与 WSL2 构建环境任务（task-5）强相关，需协同。
6. **切换 rootful/rootless 必须 `make clean`**（Theos 官方明确要求）。
7. **Dopamine 与 palera1n 差异**：两者都是 rootless、都用 `/var/jb`、通常用 ElleKit；roothide（Dopamine-roothide）会随机化 `/var/jb`，务必用 `ROOT_PATH_NS`+libroot，勿硬编码。

> 资源落地建议：宠物帧素材（PNG 序列/webp）放到 `ROOT_PATH_NS(@"/Library/Application Support/dsh-pet/")`，由 asset-pipeline 任务（task-3）约定具体目录；代码里只通过 rootless 宏读取，不写死绝对路径。

---

## 6. Hook 类 / 方法清单与验证命令

### 6.1 关键 hook 清单（首版）

| 优先级 | Hook 类 | 方法 | 目的 |
|---|---|---|---|
| P0 | `SpringBoard` | `-applicationDidFinishLaunching:` | 创建悬浮 window（推荐挂载点） |
| P0 | `SpringBoard` | `-applicationDidBecomeActive:` / `-applicationWillResignActive:`（若存在） | 前后台恢复/隐藏 |
| P0 | 自定义 `PetOverlayWindow : UIWindow` | `-hitTest:withEvent:` | 事件穿透 |
| P0 | 自定义 `PetView : UIView` | `UIPanGestureRecognizer` / `UITapGestureRecognizer` | 拖拽/点击 |
| P1 | `SBHomeScreenViewController` | `-viewDidLoad` / `-viewDidAppear:` | 备选挂载点 |
| P1 | `UIDevice` / UIApplication 通知 | 旋转、内存警告、前后台通知 | 生命周期 |
| P2 | `SBWindowScene` / `FBWindowScene` | 窗口创建相关（**待 dump 确认**） | 精准 scene 级挂载（进阶） |
| P2 | `SBLockScreenViewController` / 锁屏通知 | 锁屏/解锁 | 锁屏隐藏（待验证） |

### 6.2 验证命令（在越狱 iPhone 上执行，本机仅记录）

> 以下命令为在**真机/越狱环境**运行的验证手段；本机无法执行，仅作为落地步骤清单。

**A. class-dump 拿到 SpringBoard 头文件**（系统二进制未加密，可从设备 pull 后 dump）：
```bash
# 从越狱 iPhone 拉取 SpringBoard 二进制（路径随版本不同，需确认）
scp root@<iphone-ip>:/System/Library/CoreServices/SpringBoard.app/SpringBoard ./SpringBoard
# 用 class-dump（rootless 下通常在 /var/jb/usr/bin/class-dump）导出头
class-dump -H SpringBoard -o SpringBoardHeaders
# 也可用 ktool（跨平台） dump
ktool dump -o SpringBoardHeaders SpringBoard
# 在导出的头里检索目标类
grep -R "SBHomeScreenViewController\\|SBWindowScene\\|applicationDidFinishLaunching" SpringBoardHeaders | head -50
```

**B. Frida 动态观察（确认方法是否被调用、class 是否存在）**：
```bash
# 列出设备进程，确认 SpringBoard 进程名
frida-ps -U | grep -i spring
# 附着到 SpringBoard（注意：spawn 会 respring，优先 attach）
frida -U SpringBoard
# 在 frida REPL 里检查类与方法：
#   ObjC.classes.SBHomeScreenViewController
#   ObjC.classes.SpringBoard.$ownMethods  // 查看实际方法列表
#   ObjC.classes.SBWindowScene
# 追踪方法调用：
#   var m = ObjC.classes.SpringBoard['- applicationDidFinishLaunching:'];
#   Interceptor.attach(m.implementation, { onEnter: function(args){ console.log('called!'); }});
```

**C. 确认 windowLevel / 窗口层级**（Frida 脚本片段）：
```js
// 遍历 UIApplication.windows，打印每层的 class 与 windowLevel
ObjC.schedule(ObjC.mainQueue, function(){
  var app = ObjC.classes.UIApplication.sharedApplication();
  var wins = app.windows();
  for (var i=0;i<wins.count();i++){
    var w = wins.objectAtIndex_(i);
    console.log(w.$className, w.windowLevel());
  }
});
```

**D. 注入自检**：安装 tweak 后 respring，观察 `PetOverlayWindow` 是否出现在 C 的窗口列表里；点空白区域确认 SpringBoard 图标仍可点（穿透生效）。

> 验证重点（对应「需真机验证」假设）：① SpringBoard 实际实现的 didFinishLaunching 方法名；② `SBHomeScreenViewController`/`SBIconContentView`/`SBWindowScene` 在目标 iOS 版本的确切存在与签名；③ windowLevel 相对桌面/状态栏的实际数值；④ passthrough hitTest 在目标 iOS（尤其 iOS 18）是否成立；⑤ 锁屏/前后台通知名。

---

## 7. 推荐方案与备选对比

| 方案 | 注入点 | 稳定性 | 与桌面耦合 | 事件穿透 | 首版采用 |
|---|---|---|---|---|---|
| A（推荐）独立 passthrough window | `SpringBoard -applicationDidFinishLaunching:` | 高（生命周期方法稳定） | 低（独立 window） | 需覆写 hitTest | ✅ |
| B 挂到桌面 VC | `SBHomeScreenViewController -viewDidLoad` | 中（VC 结构随版本变） | 高（进文件夹/切 App 会丢） | 天然在桌面层，穿透简单 | ❌（备选） |
| C scene 级 window | `SBWindowScene`/`FBWindowScene` | 中高但复杂（scene 创建/销毁需处理） | 中 | 可控 | ❌（进阶） |

**决策**：首版用 A；若真机发现 A 的穿透在目标 iOS 上失效，退到 B 并补 `SBFolderController` 重建逻辑；C 留作后续多屏/横竖屏增强。

---

## 8. 风险与未决项（需真机验证的假设汇总）

1. SpringBoard `applicationDidFinishLaunching` 的确切签名与调用时机——假设存在且被调用。
2. `SBHomeScreenViewController`、`SBIconContentView`、`SBWindowScene`、`FBWindowScene` 在目标 iOS 版本的确切类名/方法——基于公开 dumped header 索引，未在本机验证。
3. windowLevel 相对层级——用公开 UIWindowLevel 做相对定位，实际被状态栏/其它浮层遮挡情况需真机观察。
4. passthrough `hitTest:` 的穿透在 iOS 18+ 的 window isolation 下是否仍有效——公开资料提示有变化，需验证。
5. 前后台/锁屏通知名（`SBApplicationDidActivateNotification`、`SBLockScreen...` 等）——私有通知名未确认。
6. rootless 下 tweak 实际安装目录（MobileSubstrate vs TweakInject）与 ElleKit 读取路径——以真机越狱环境为准。
7. arm64e 新 ABI 构建——Windows/WSL 无法原生产出，需 GitHub Actions/allemande/oldabi 方案（与 task-5 协同）。
8. 素材路径与转码产物（task-3）的最终目录约定，需与本方案的 `ROOT_PATH_NS` 读取路径对齐。

---

## 9. 给下游任务（task-4 Theos 骨架）的接口建议

- 暴露单例 `PetManager`（`sharedInstance`），提供 `installOverlayWindow`、`show`/`hide`、`attachToView:`（备选方案用）。
- 自定义 `PetOverlayWindow : UIWindow`，属性 `petRootView` 供 hitTest 判定。
- 自定义 `PetView : UIView`，对外 `-bindPanGesture` / `-bindTapGesture`，动画帧加载走 `ROOT_PATH_NS` 路径。
- plist Filter：`{ Filter = { Bundles = ("com.apple.springboard"); }; }`。
- Makefile：`THEOS_PACKAGE_SCHEME = rootless`，`TARGET = springboard`。