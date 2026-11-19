# dsh-pet → iOS 越狱 tweak 移植总体方案

## 1. 对象认知（已确认）

- `dsh-pet` 是开源项目 **dsh-pet v0.4.9**（github.com/PC2005-cloud/dsh-pet），不是加固二进制。
- 形态：DSH 的 Cordis 插件（宿主侧 `lib/index.js`）+ 浏览器侧 `lib/client.js` + Electron 桌面悬浮窗 helper（`runtime/electron-helper`）。
- 源码完整：`C:\Users\ASUS\.dsh\profiles\desktop\node_modules\dsh-pet\`（src 数百个 TS 模块、lib 编译产物、runtime、assets）。
- 素材：`assets/webm` 100+ 个 VP9-alpha 透明动画、`assets/memes` 表情包、`assets/sound` 音效、中文字体。
- 结论：**无需逆向 dsh-pet 本身**（开源），真正需要逆向的是 **iOS SpringBoard 桌面**。

## 2. 用户决策（已确认）

| 项 | 决定 |
|---|---|
| 目标形态 | iOS 越狱 tweak（注入 SpringBoard，桌面悬浮） |
| 构建环境 | 无 Mac、不用 Mac；本机 Windows 不直编 → GitHub Actions `macos-14` 云端编译 Theos |
| 越狱设备 | iPhone 12（A14 → arm64e 新 ABI）、无根（rootless，Dopamine / palera1n），可装 .deb 测试 |
| 首版范围 | 核心：桌面悬浮 + 动画 + 拖拽 + 点击 |

## 3. 技术路线

GitHub Actions `macos-14`（arm64 macOS）→ Theos + Xcode clang（原生产出 arm64e 新 ABI）+ dpkg-deb → rootless .deb → iPhone 12 无根越狱。

**为何不走本机 WSL2**：iPhone 12 是 A14（arm64e 新 ABI），SpringBoard 是系统二进制；Linux 上的 ld64/ldid 不支持新 ABI 签名，无法产出可注入系统进程的 tweak。本机实测 WSL 安装也失败。故编译全部放到云 macOS。iOS SDK（16.5）在 CI 里用 theos/sdks；rootless 走 /var/jb 路径，Dopamine / palera1n 兼容。工作流：`.github/workflows/build-tweak.yml`。

## 4. 架构映射（dsh-pet → iOS）

| dsh-pet 组件 | iOS 对应实现 |
|---|---|
| Electron 透明 BrowserWindow（helper/main/windows.js） | 注入 SpringBoard 的透明 `UIWindow`（自定义 windowLevel） |
| React 桌宠卡片 / 动画状态机（src/client/pet/card） | Objective-C 视图控制器 + 状态机 |
| VP9-alpha webm 动画 | 转码为 PNG/WebP 序列帧，`UIImage` 序列或 YYImage 播放 |
| 拖拽/碰撞/回弹（src/client/pet/motion） | `UIPanGestureRecognizer` + 原生动画 |
| 点击回应（pet/motion/touch-press, click-sound） | `UITapGestureRecognizer` + 回应动画选择 |
| DSH LLM/网络/凭据 | 首版不做，预留 Native 网络层接口 |

## 5. 并行子任务（团队）

- task-1 `springboard-re`：SpringBoard 注入逆向 → docs/springboard-re.md
- task-2 `pet-core-port`：核心逻辑移植规格 → docs/pet-core-port-spec.md
- task-3 `asset-pipeline`：webm 转码管线 → tools/transcode-webm + docs/asset-pipeline.md
- task-5 `build-env`：WSL2 环境方案 → docs/build-env-setup.md
- task-4 `tweak`（依赖 task-1）：Theos 工程骨架 → tweak/

集成者（lead）：总体方案、环境、工程骨架、最终合并与可落地交付。

## 6. 硬约束与风险

- 本机 WSL 当前 **Disabled** 且实测安装失败；且即便装好也无法产出 arm64e 新 ABI，故放弃本机编译。
- 编译统一走 GitHub Actions `macos-14`，本地只需编辑源码、提交即可拿到 .deb 产物。
- 真机行为（窗口挂载点、事件注入）需越狱 iPhone 实测验证；文档中的假设均标注「待真机验证」。
- 素材版权：代码 MIT，素材禁止商用、二创公开需署名（见 dsh-pet README）。

## 7. 完成判据

产出可由 GitHub Actions（macos-14）`make package` 编译、安装到 iPhone 12 无根越狱机、桌面出现可拖拽/点击播放动画的大肥鱼 deb 工程（首版）。
