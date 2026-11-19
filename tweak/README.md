# dsh-pet SpringBoard tweak 工程骨架

> 依据 `docs/springboard-re.md`（方案 A：独立 passthrough UIWindow）、`docs/build-env-setup.md`（rootless Theos 配置）、`docs/pet-core-port-spec.md`（行为规格）整合而成。
> 状态：**核心功能已落地**。桌面悬浮、拖拽、点击回应、序列帧动画播放均为可用实现；私有 API 已标注「需真机验证」，构建产物尚未在越狱真机验证。
> 目标机：**iPhone 12（A14 / arm64e 新 ABI）+ 无根越狱**；本机 Windows 无法直编 → 用 GitHub Actions `macos-14` 云编译（见 `.github/workflows/build-tweak.yml`）。

## 1. 文件清单

| 文件 | 作用 |
|---|---|
| `Makefile` | Theos 构建配置：`THEOS_PACKAGE_SCHEME=rootless`、`ARCHS=arm64 arm64e`（A14）、`TARGET=iphone:clang:16.5:15.0`、`ROOT_PATH_NS` 资源路径宏注入、frameworks |
| `control` | 包元数据：`Architecture: iphoneos-arm64`、rootless `Depends` |
| `com.yourid.dshpet.plist` | 规范命名的 filter：`Filter → Bundles → com.apple.springboard` |
| `dshpet.plist` | Theos 实际查找的 filter 副本，由 Makefile 从上面同步；两文件内容一致 |
| `PetCompat.h` | `rootless.h` 兼容层：有则引入，无则 `ROOT_PATH`/`ROOT_PATH_NS` 退化为恒等宏 |
| `Tweak.xm` | Logos 入口：`%hook SpringBoard` `-applicationDidFinishLaunching:` → `[[PetManager sharedInstance] start]`，并 hook active/resign 做恢复/隐藏；备选方案 B 以注释保留 |
| `PetManager.h/.xm` | 单例、window 创建/销毁、show/hide、旋转/内存警告通知、`attachToView:` 备选入口 |
| `PetOverlayWindow.h/.xm` | `UIWindow` 子类：透明、`windowLevel = UIWindowLevelNormal + 1`、`hitTest:withEvent:` 非宠物区返回 nil 实现穿透 |
| `PetView.h/.xm` | 桌宠 UIView（**已实现**）：拖拽阈值 5pt + 24pt 边界 clamp + 过阻尼回弹、`hitRect` 透明命中区、点击 100ms 拖拽抑制、5 选 1 点击回应、序列帧动画（generation 防旧帧、24fps、帧缓存/内存警告）、`ROOT_PATH_NS` 读资源 |
| `README.md` | 本文件 |

## 2. 构建（GitHub Actions 云编译，本机 Windows 不直编）

目标机 iPhone 12 = A14 arm64e 新 ABI，SpringBoard 为系统二进制，Linux/WSL 无法产出可注入的新 ABI tweak。唯一可靠路径：GitHub Actions `macos-14`（Xcode clang 原生产出 arm64e）。工作流 `.github/workflows/build-tweak.yml` 已配置 `THEOS_PACKAGE_SCHEME=rootless ARCHS="arm64 arm64e" TARGET=iphone:clang:16.5:15.0`，push 或手动触发即出 .deb 产物。

（下方命令仅为「若本机已装 Theos 自测」参考，正式产物以云编译为准。）

```bash
# [WSL] 进入本目录
cd ~/dsh-pet/tweak

# rootless 打包（每次都要带环境变量）
THEOS_PACKAGE_SCHEME=rootless make package

# 验包
dpkg-deb -I packages/*.deb | grep -E 'Package|Version|Architecture'
dpkg-deb -c  packages/*.deb | head       # 路径应含 /var/jb/Library/MobileSubstrate/DynamicLibraries/
```

要点：

- **切换 rootful/rootless 前必须 `make clean`**，否则产物混杂。
- `ARCHS` 默认只有 `arm64`：WSL2 无法原生编译 arm64e 新 ABI（build-env-setup.md §7.5）。若测试机是 A12+（arm64e），需用 GitHub Actions / macOS 构建：`make ARCHS="arm64 arm64e" package`，或先用 A11 及以下设备（palera1n）验证功能。
- `TARGET` 格式是 `iphone:clang:<SDK>:<最低iOS>`，rootless 最低 15.0；任务描述里的 “arm64” 由 `ARCHS` 表达。
- Makefile 会在打包前把 `com.yourid.dshpet.plist` 同步为 Theos 需要的 `dshpet.plist`；改 filter 只改前者。

## 3. 安装到越狱 iPhone

方式 A（Theos 远程安装）：

```bash
export THEOS_DEVICE_IP=<iPhone_IP>
export THEOS_DEVICE_USER=root
THEOS_PACKAGE_SCHEME=rootless make install
```

方式 B（手动）：

```bash
scp packages/*.deb root@<iPhone_IP>:/var/tmp/
ssh root@<iPhone_IP> "dpkg -i /var/tmp/*.deb; killall -9 SpringBoard"
```

rootless 下包管理器识别 `iphoneos-arm64`；安装后 respring 生效。

### 3.1 动画素材打包（重要：deb 需带素材）

转码产物放在本工程 `layout/Library/Application Support/dsh-pet/`（Theos 会把 `layout/` 内容按原路径装入越狱根，rootless 自动加 `/var/jb`）：

```bash
# [WSL / Git Bash] 用 transcode-webm 转码首版最小素材集
SRC_DIR=<dsh-pet>/assets/webm \
OUT_ROOT="$PWD/tweak/layout/Library/Application Support/dsh-pet" \
bash tools/transcode-webm/transcode.sh

# 目录结构：<动画名>/frames/frame_00001.webp + anim.json
# 然后打包，素材随 deb 一起安装：
THEOS_PACKAGE_SCHEME=rootless make package
```

Makefile 的 `before-package` 会检查素材目录并在为空时给出警告。代码通过 `ROOT_PATH_NS` 读取，roothide 随机化 jbroot 时也能工作。首版最小清单见 `layout/.../dsh-pet/README.txt` 与 `docs/pet-core-port-spec.md` §3.4。

> 注意：dsh-pet 素材为**非商用授权**，衍生作品需署名 78673180 / 蓝毛小女仆 大佬（见 `docs/OVERALL-PLAN.md` §7）。

## 4. 真机必测假设清单（逐项勾选）

依据 `docs/springboard-re.md` §8，下列均为**未在真机验证**的假设：

- [ ] SpringBoard 实际实现的启动方法名：`-applicationDidFinishLaunching:` 还是 `-_applicationDidFinishLaunching`（必要时追加 hook，Tweak.xm 已注释提示）。
- [ ] `-applicationDidBecomeActive:` / `-applicationWillResignActive:` 是否存在且被调用；若否，改用 UIApplication 通知。
- [ ] `SBHomeScreenViewController` / `SBIconContentView` / `SBWindowScene` / `FBWindowScene` 在目标 iOS 版本的确切类名与签名（方案 B 回退依赖）。
- [ ] `windowLevel = UIWindowLevelNormal + 1` 相对桌面/状态栏的实际层级，是否被遮挡。
- [ ] passthrough `hitTest:` 穿透在目标 iOS 是否成立；**iOS 18+ window isolation 变化需重点验证**。
- [ ] 锁屏/前后台私有通知名（`SBLockScreenDidUnlockNotification`、`SBApplicationDidActivateNotification` 等）需 dump 后补充。
- [ ] rootless 下 tweak 实际注入目录（MobileSubstrate vs TweakInject）与 ElleKit 读取路径。
- [ ] A12+ 的 arm64e 新 ABI 构建方案（与 task-5 协同）。
- [ ] asset-pipeline（task-3）最终素材目录/格式与 `ROOT_PATH_NS`（`PET_RESOURCE_DIR`）一致。
- [ ] 安全区数值（顶部 60 / 底部 40）在目标机型的实际表现。

验证命令见 `docs/springboard-re.md` §6.2（class-dump / Frida / 窗口层级遍历）。

## 5. 实现状态与后续接口

- **core-spec（task-2，已接入）**：`PetView` 实现了拖拽阈值、点击抑制、回弹、5 选 1 点击回应、A/B 双缓冲思想（只增 generation 防旧帧）。下一步可选：完整决策树（work-rotate/work-replay/turn/random 权重）、长按 500ms、点击音效节流、翻面镜像——首版按用户选定范围暂未纳入。
- **asset-pipeline（task-3，已对接）**：`PetView` 从 `[PetManager resourceDirectory]` 下的 `<动画名>/frames/` 加载 webp 序列帧；素材经 `layout/` 打进 deb，目录宏为 `PET_RESOURCE_DIR`。
- **build-env（task-5）**：arm64e 构建与 SDK 版本由 `ARCHS`/`TARGET` 控制，见第 2 节；**当前 WSL2 默认只编 arm64**，A12+ 设备需 GitHub Actions / oldabi 方案。
- **待真机验证**：第 4 节假设清单逐项确认；blocking 决策——目标机是 A11 及以下（arm64，可直接 WSL 编译）还是 A12+（arm64e，需额外构建路径）。
