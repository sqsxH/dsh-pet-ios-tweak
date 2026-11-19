# dsh-pet → iOS 越狱桌宠 tweak（工程总入口）

目标：把开源桌宠 **dsh-pet（大肥鱼）** 移植成 iOS 越狱插件，在 SpringBoard 桌面悬浮播放动画，支持拖拽与点击。首版聚焦核心交互。

约束：无 Mac，仅本机 Windows；编译走 GitHub Actions `macos-14` 云端（本机 WSL 安装失败且无法产出 arm64e 新 ABI）。目标机 iPhone 12（A14 / arm64e）、无根越狱（rootless，Dopamine / palera1n），可装 .deb 测试。

## 目录导航

| 路径 | 内容 | 状态 |
|---|---|---|
| `docs/OVERALL-PLAN.md` | 总体方案、架构映射、完成判据 | ✅ |
| `docs/springboard-re.md` | SpringBoard 桌面注入逆向方案（推荐方案 A） | ✅ |
| `docs/build-env-setup.md` | 构建环境说明（本机 WSL 不可用 → 云 macOS 方案） | ✅ |
| `.github/workflows/build-tweak.yml` | GitHub Actions macos-14 云编译 rootless arm64e .deb | ✅ |
| `docs/pet-core-port-spec.md` | 动画/拖拽/点击核心行为移植规格 | ✅ |
| `docs/asset-pipeline.md` | webm→iOS 序列帧转码管线（含 alpha 陷阱） | ✅ |
| `tools/transcode-webm/` | 转码脚本与 manifest 生成器（实测通过） | ✅ |
| `tweak/` | Theos 工程（核心功能已实现，素材经 layout 打进 deb） | ✅ 代码完成，待真机验证 |

> 所有「需真机验证」的假设必须在越狱 iPhone 上确认后才算真正落地。当前工程尚未在真机编译/运行。

## 关键结论（先看这个）

1. **不用逆向 dsh-pet 本体**：它是开源 TS/React/Electron 项目，源码在
   `C:\Users\ASUS\.dsh\profiles\desktop\node_modules\dsh-pet\`。
2. **真正要逆向的是 iOS SpringBoard**：悬浮窗挂载点、事件穿透、生命周期。
3. **本机无法直编 iOS tweak**：本机 WSL 安装失败，且 iPhone 12 的 A14（arm64e 新 ABI）在 Linux 上无法编译系统二进制注入；统一走 GitHub Actions `macos-14`（Xcode clang 原生产出 arm64e）。
4. **目标机 iPhone 12 = arm64e 新 ABI**：rootless，包走 /var/jb；`ARCHS="arm64 arm64e"` 已覆盖。

## 快速开始（GitHub Actions 云编译）

```bash
# 1) 本地只改源码，提交到 GitHub（main/master）
git add . && git commit -m "build tweak" && git push

# 2) GitHub Actions 自动在 macos-14 上：装 Theos+iOS16.5 SDK → 转码素材 →
#    THEOS_PACKAGE_SCHEME=rootless ARCHS="arm64 arm64e" make package → 上传 .deb 产物
#    （也可在 Actions 页手动 workflow_dispatch 触发）

# 3) 下载 Actions 里的 dshpet-rootless-arm64e 产物，取出 .deb，传到 iPhone 12
scp dshpet*.deb root@<iPhone-IP>:/var/tmp/
# iPhone 上（rootless）
dpkg -i /var/tmp/*.deb
killall -9 SpringBoard   # 或 ldrestart
```

（本机若要临时自测可装 Theos，但 iPhone 12 的 arm64e 新 ABI 必须云 macOS 编译。）
安装后回桌面观察大肥鱼是否出现、可拖拽/点击。崩溃日志用 Frida / `syslog` 抓。
真机逐项验证清单见 `tweak/README.md` 第 4 节。构建环境说明见 `docs/build-env-setup.md`。

## 版权

dsh-pet 代码 MIT；**素材禁止商用，二创公开渠道须署名**（见其 README：
https://github.com/PC2005-cloud/dsh-pet）。本工程仅用于个人学习研究。
