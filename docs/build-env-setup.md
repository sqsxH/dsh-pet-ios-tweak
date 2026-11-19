# dsh-pet → iOS 越狱 tweak：Windows / WSL2 构建环境搭建

> 目标：在**没有 Mac** 的前提下，仅用这台 Windows 主机（i3-4170 / Win11 24H2 build 26100）搭建可编译、可打包、可安装到越狱 iPhone 的 Theos 环境，用于构建 dsh-pet 的 SpringBoard 悬浮桌宠 tweak。
> 关联任务：本环境供 task-1（SpringBoard 注入方案）、task-4（tweak 工程骨架）使用；动画素材转码见 task-3。
> 文档中普通等宽文本为命令。所有命令**未特别标注即在 WSL Ubuntu 普通用户下执行**。

---

## 0. 本机现状（已实测，2026-11-18）

| 检查项 | 实测结果 | 含义 |
|---|---|---|
| `wsl.exe --status` | 无有效输出，提示需 `wsl.exe --install` | WSL 未安装 |
| `Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux` | `Disabled` | WSL 功能关闭 |
| `Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform` | `Disabled` | WSL2 所需的虚拟机平台关闭 |
| OS | Windows 11 专业工作站版 10.0.26100 (24H2) | 支持 WSL2 |
| CPU | Intel i3-4170，`VirtualizationFirmwareEnabled=True`，`VMMonitorModeExtensions=True` | BIOS 已开 VT-x，可跑 WSL2 |

> 结论：两个 Windows 可选功能都是 Disabled，但硬件虚拟化已就绪，走 `wsl --install` 一键路径即可，无需进 BIOS。

---

## 1. 两条路径：minimum viable 与完整

- **Minimum viable（首版推荐）**：`wsl --install -d Ubuntu-22.04` → Theos 安装脚本 → 官方 `theos/sdks` 的 `iPhoneOS16.5.sdk` → rootless 配置 → 编译骨架 tweak 出 `.deb`。**全程不碰 iPhone 头文件拷贝**，约 30–60 分钟。
- **完整（追加）**：从越狱 iPhone 拷贝私有框架/类头文件以支撑 SpringBoard 深度 hook（task-1 需要），以及 arm64e 新 ABI 处理。见 §8、§7.5。

> 标记说明：**[管理员]** = 必须以管理员身份打开 PowerShell；**[重启]** = 需要重启 Windows；**[WSL]** = 在 Ubuntu 终端里执行；**[iPhone]** = 在越狱 iPhone 上（SSH）执行。

---

## 2. 启用 WSL2（[管理员] + [重启]）

### 2.1 一键安装（推荐）
以**管理员身份**打开 PowerShell（Win+X → 终端(管理员)），执行：

```powershell
# [管理员] 一键启用 WSL + 虚拟机平台 + 设置默认版本 2 + 安装 Ubuntu 22.04
wsl.exe --install -d Ubuntu-22.04
```

该命令自动完成：启用 `Microsoft-Windows-Subsystem-Linux` 和 `VirtualMachinePlatform`、下载 WSL2 Linux 内核、设置 `wsl --set-default-version 2`、安装 Ubuntu 22.04 发行版。

### 2.2 若一键失败，手动逐项启用（[管理员]）

```powershell
# [管理员]
dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart
# 或用 PowerShell cmdlet（二选一）
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -NoRestart
Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -NoRestart
```

然后安装发行版：

```powershell
# [管理员]
wsl.exe --set-default-version 2
wsl.exe --install -d Ubuntu-22.04
# 若 Microsoft Store 不可用，可手动下载发行版：
# https://aka.ms/wslubuntu2204  → 得到 Ubuntu2204.appx，双击安装
```

### 2.3 [重启] 并验证

```powershell
# [重启后，管理员] 验证功能已启用
Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux | Select-Object FeatureName,State
Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform | Select-Object FeatureName,State
# 期望：两行 State 均为 Enabled

wsl.exe --status
# 期望：出现「适用于 Linux 的 Windows 子系统: 已启用」等正常信息，不再提示安装

wsl.exe -l -v
# 期望：Ubuntu-22.04  VERSION 列为 2，STATE 为 Running/Stopped
```

首次启动 Ubuntu 会要求设置 UNIX 用户名与密码（**普通用户，不要用 root** —— Theos 官方明确要求以普通用户安装和运行）。

进入 Ubuntu 后验证内核与架构：

```bash
# [WSL]
uname -a                 # 应含 Microsoft 字样，内核 5.x/6.x
cat /etc/os-release      # Ubuntu 22.04
```

---

## 3. Ubuntu 基础依赖（[WSL]）

```bash
# [WSL] 更新源
sudo apt update && sudo apt upgrade -y

# [WSL] Theos 官方要求的最小前置 + 实用构建工具
sudo apt install -y bash curl sudo git make build-essential python3 perl dpkg-dev file zip unzip xz-utils libxml2-dev libssl-dev libffi-dev zlib1g-dev ca-certificates openssh-client rsync
```

逐项验证：

```bash
# [WSL] 期望各自打印版本号，无 "command not found"
bash --version | head -1
curl --version | head -1
git --version
make --version | head -1
clang --version 2>/dev/null | head -1 || echo "clang 将随 Theos 工具链提供"
dpkg-deb --version | head -1
```

> 说明：现代 Theos 自带预编译 clang 工具链（含 `ldid`），所以系统 clang 不是必须；`dpkg-deb` 由 `dpkg-dev` 提供，用于检查/解包 `.deb`（Theos 打包现用自带的 `dm.pl`，不强制依赖 dpkg，但装上便于验包）。

---

## 4. 安装 Theos（[WSL]，普通用户）

官方安装脚本会：克隆 Theos 到 `~/theos`、下载预编译工具链（clang、ldid 等）到 `~/theos/toolchain`，并配置 `~/.zshrc`/`~/.bashrc`。

```bash
# [WSL] 必须用普通用户（不要用 root / sudo 执行安装脚本）
bash -c "$(curl -fsSL https://raw.githubusercontent.com/theos/theos/master/bin/install-theos)"
```

若脚本因网络中断失败，可手动安装：

```bash
# [WSL] 手动安装兜底
export THEOS=~/theos
git clone --recursive https://github.com/theos/theos.git $THEOS
# 工具链随 make 首次触发下载；若需手动，见 Theos 安装文档
```

配置环境变量（安装脚本通常已写入，确认一下）：

```bash
# [WSL] 写入 ~/.bashrc（若使用 zsh 则写 ~/.zshrc）
echo 'export THEOS=$HOME/theos' >> ~/.bashrc
echo 'export PATH=$THEOS/bin:$PATH' >> ~/.bashrc
source ~/.bashrc
```

验证：

```bash
# [WSL]
echo $THEOS                       # 期望 /home/<user>/theos
ls $THEOS/bin/nic.pl $THEOS/bin/ldid 2>/dev/null || true
$THEOS/bin/nic.pl --help 2>&1 | head -5   # 能打印模板列表即成功
which ldid || echo "ldid 在 $THEOS/toolchain/.../bin/ldid（随工具链）"
find $THEOS/toolchain -name ldid 2>/dev/null | head -3
```

更新 Theos（排障第一步）：

```bash
# [WSL]
$THEOS/bin/update-theos
```

---

## 5. 获取 iOS SDK（[WSL]）

### 5.1 用官方预编译 SDK（minimum viable，强烈推荐）

Theos 官方 `theos/sdks` 仓库提供含私有符号 tbd 的补丁 SDK。当前官方版本：`iPhoneOS10.3.sdk`、`iPhoneOS13.7.sdk`、`iPhoneOS15.6.sdk`、`iPhoneOS16.5.sdk`（最新）。

```bash
# [WSL] 下载并解压 SDK 仓库
cd ~
curl -L -o sdks-master.zip https://github.com/theos/sdks/archive/refs/heads/master.zip
unzip -q sdks-master.zip

# 拷贝 SDK 到 $THEOS/sdks（rootless 需 iOS 15+，用 16.5）
mkdir -p $THEOS/sdks
cp -r sdks-master/iPhoneOS16.5.sdk $THEOS/sdks/
# 如还需低版本兼容，可再拷 15.6： cp -r sdks-master/iPhoneOS15.6.sdk $THEOS/sdks/
```

验证：

```bash
# [WSL]
ls -d $THEOS/sdks/iPhoneOS16.5.sdk
ls $THEOS/sdks/iPhoneOS16.5.sdk/System/Library/Frameworks | head -5
test -f $THEOS/sdks/iPhoneOS16.5.sdk/System/Library/Frameworks/UIKit.framework/UIKit.tbd && echo "SDK OK"
```

> 若需要 iOS 17/18 SDK，官方仓库未收录，可用社区镜像 `https://github.com/xybp888/iOS-SDKs`（含 13.5–27）或 `https://github.com/Tonwalter888/iOS-18.6-SDK`，克隆后同样拷到 `$THEOS/sdks/`。首版不需要，16.5 足够。

### 5.2 rootless 所需 SDK 版本（关键）

- Theos 官方文档：**rootless 方案只支持 iOS 15+**，部署目标应设为 `15.0`。
- 因此 SDK 至少用 `iPhoneOS15.6.sdk`，推荐 `iPhoneOS16.5.sdk`。不要用 13.7/10.3 编 rootless。
- 架构：`iphoneos-arm64`（Theos 在 `THEOS_PACKAGE_SCHEME=rootless` 时自动设置）。

---

## 6. dpkg-deb 验证（[WSL]）

```bash
# [WSL] 稍后对打出的 .deb 验包
dpkg-deb -I your.deb        # 查看 control 元数据
dpkg-deb -c your.deb | head # 查看包内文件，rootless 应全部位于 /var/jb/...
```

---

## 7. rootless 兼容配置（Dopamine / palera1n）

Dopamine 与 palera1n（rootless 模式）都把文件系统根重定向到 `/var/jb`。Theos 通过环境变量 `THEOS_PACKAGE_SCHEME=rootless` 自动处理：

- 库/框架搜索路径切到 `.../iphone/rootless`；
- install_name 改为 `@rpath`；
- 包内文件安装前缀 `THEOS_PACKAGE_INSTALL_PREFIX=/var/jb`；
- 包架构设为 `iphoneos-arm64`；
- rootless v2 还会注入 `/var/jb/` 与 `@loader_path/.jbroot/` 两类 rpath，兼容 jbroot 被重定位的越狱。

### 7.1 编译命令

```bash
# [WSL] 每次构建 rootless 包都带上该变量
THEOS_PACKAGE_SCHEME=rootless make
THEOS_PACKAGE_SCHEME=rootless make package
```

### 7.2 Makefile 片段（供 task-4 直接采用）

```makefile
ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
    ARCHS = arm64 arm64e
    TARGET = iphone:clang:latest:15.0
else
    ARCHS = armv7 armv7s arm64 arm64e
    TARGET = iphone:clang:latest:7.0
endif

TARGET := iphone:clang:16.5:15.0   # 也可显式锁定 SDK 16.5 / 最低 iOS 15
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = dshpet
dshpet_FILES = Tweak.xm PetWindow.xm PetAnimationView.xm
dshpet_FRAMEWORKS = UIKit CoreGraphics QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk
```

### 7.3 rootless.h（路径兼容）

代码里不要写死 `/Library/...`，用：

```objc
#import <rootless.h>
NSString *p = ROOT_PATH_NS(@"/Library/MobileSubstrate/DynamicLibraries/dshpet.dylib");
```

### 7.4 切换 rootful/rootless 必须清理

```bash
# [WSL] 切换方案前必做，否则产物混杂
make clean
```

### 7.5 arm64e 关键坑（SpringBoard 必读）

- SpringBoard 是**系统二进制**。在 **A12 及以上**（Dopamine 设备）它是 `arm64e` 且使用 iOS 14+ 的**新 ABI**；在 **A11 及以下**（palera1n checkm8 设备）是 `arm64`，无此问题。
- Theos 官方说明：**新 arm64e ABI 只能在 macOS/Xcode 上编译**（ld64 改动未开源）。Linux/WSL 无法原生产出新 ABI。
- 无 Mac 的三种绕法（按推荐度）：
  1. 先用 **A11 及以下设备（palera1n，arm64）** 测试，绕开该问题 —— 首版最省事；
  2. 用 **GitHub Actions** 云端 macOS 编译（官方 example workflow：`p0358/SilentScreenshots/.github/workflows/build.yml`）；
  3. 用 **allemande**（静态旧 ABI 转换器，`https://github.com/p0358/allemande`）或加 `oldabi` 依赖（后者系统级，仅测试用，别随包发布）。
- 该限制**只影响 hook 系统二进制**（如 SpringBoard），普通 App/CLI 不受影响。

> 待确认：测试机是 A11 及以下还是 A12+？若为 A12+ 且走 Dopamine，需按上述方案 1/2/3 处理，否则 tweak 可能不注入 SpringBoard。

---

## 8. 从越狱 iPhone 拷贝 SDK / 头文件（[iPhone] + [WSL]）

> 仅当 task-1 需要 SpringBoard 私有类头文件时做。编译用的 **SDK 本体仍用 §5 的预编译包**，这里拷的是私有框架头文件 / class-dump 结果，放到 SDK 的 `include` 里供 hook 引用。

### 8.1 iPhone 端准备

```bash
# [iPhone] 在 Sileo/Zebra 安装 OpenSSH；SSH 默认账号 root，密码 alpine（首次务必改密码）
# 确认 IP：设置 → 无线局域网 → 当前网络详情，或用 ifconfig
```

### 8.2 WSL 端 SSH 连通性验证

```bash
# [WSL] 先测连通（首次会问 yes/no，再输密码 alpine）
ssh root@<iPhone_IP> "uname -a; sw_vers 2>/dev/null || echo iOS"

# 免密（可选，推荐）：把 WSL 的公钥塞进 iPhone
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_ios -N ""
ssh-copy-id -i ~/.ssh/id_ed25519_ios.pub root@<iPhone_IP>
```

### 8.3 拷贝头文件（区分 rootless / rootful）

```bash
# [WSL] —— rootless（Dopamine/palera1n）：越狱文件系统在 /var/jb ——
ssh root@<iPhone_IP> "test -d /var/jb/usr/include && echo ROOTLESS_OK"

rsync -avz root@<iPhone_IP>:/var/jb/usr/include/ ~/ios-headers/usr/include/
rsync -avz root@<iPhone_IP>:/var/jb/System/Library/Frameworks/ ~/ios-headers/Frameworks/ 2>/dev/null || true

# —— rootful（旧越狱）：路径是 /usr/include ——
# rsync -avz root@<iPhone_IP>:/usr/include/ ~/ios-headers/usr/include/

# 合并进所用 SDK（注意只补私有头文件，别用设备头覆盖整个 SDK 的公开头，避免版本错配）
rsync -av ~/ios-headers/usr/include/ $THEOS/sdks/iPhoneOS16.5.sdk/usr/include/
```

### 8.4 SpringBoard 私有类头文件（task-1）

```bash
# [iPhone] 从设备导出 SpringBoard 类头文件（需先装 class-dump）
ssh root@<iPhone_IP> "class-dump -H /System/Library/CoreServices/SpringBoard.app/SpringBoard -o /tmp/sb-headers"
# rootless 下 SpringBoard 路径可能是 /var/jb/... 或系统原路径，以实际为准

# [WSL] 拉回本地
rsync -avz root@<iPhone_IP>:/tmp/sb-headers/ ~/springboard-headers/
```

验证：

```bash
# [WSL]
ls ~/ios-headers/usr/include | head
grep -R "SBHomeScreenViewController" ~/springboard-headers/ | head -3
```

---

## 9. 端到端冒烟测试（[WSL]，验证整条链可用）

```bash
# [WSL] 用 nic.pl 生成 tweak 模板（交互式，选 11 iPhone/Tweak，填包名 com.example.dshpet）
$THEOS/bin/nic.pl
cd dshpet

# 打 rootless 包
THEOS_PACKAGE_SCHEME=rootless make package

# 验证产物
ls packages/*.deb
dpkg-deb -I packages/*.deb | grep -E "Package|Version|Architecture"
dpkg-deb -c packages/*.deb | head -10   # 期望路径含 /var/jb/Library/MobileSubstrate/DynamicLibraries/
```

成功标志：生成 `.deb`，且 `Architecture: iphoneos-arm64`、内部文件路径以 `/var/jb/` 开头。

---

## 10. 安装 .deb 到 iPhone（[WSL] + [iPhone]）

方式 A —— Theos 远程安装（需 iPhone 开启 SSH）：

```bash
# [WSL]
export THEOS_DEVICE_IP=<iPhone_IP>
export THEOS_DEVICE_USER=root
THEOS_PACKAGE_SCHEME=rootless make install
```

方式 B —— 手动拷贝：

```bash
# [WSL]
scp packages/*.deb root@<iPhone_IP>:/var/tmp/
ssh root@<iPhone_IP> "dpkg -i /var/tmp/*.deb; killall -9 SpringBoard"
```

> rootless 设备上包管理器（Sileo/Zebra）会自动识别 `iphoneos-arm64` 架构；装完注销或 `killall SpringBoard` 生效。

---

## 11. 常见问题排错

| 症状 | 原因 / 处理 |
|---|---|
| `wsl.exe --status` 无输出 / 提示安装 | WSL 未装，按 §2 `wsl --install -d Ubuntu-22.04` |
| `wsl --install` 报 0x80370102 | 未在 BIOS 开虚拟化或 Hyper-V 未启用；本机已确认 VT-x 开启，若仍报错在「启用或关闭 Windows 功能」勾选 Hyper-V 后重启 |
| WSL2 联网失败 / DNS 异常 | 在 `/etc/wsl.conf` 加 `[network]` 与 `generateResolvConf = false` 后自定义 DNS；或关闭代理/VPN 的 fake-IP DNS（本机 web 抓取曾遇 github.com 被解析到 127.0.0.1） |
| Theos 安装脚本中途失败 | 多为网络问题；重跑脚本，或 `$THEOS/bin/update-theos`；必要时按 §4 手动 clone |
| `command not found: ldid` | ldid 随工具链在 `$THEOS/toolchain/.../bin/`，确认已 `source ~/.bashrc` 且 PATH 含 `$THEOS/bin` |
| 编译报找不到 `UIKit.framework` / 私有符号 | SDK 未放对位置；确认 `$THEOS/sdks/iPhoneOS16.5.sdk` 存在且含 tbd，见 §5 |
| 装到 iPhone 后 tweak 不生效 | ①未带 `THEOS_PACKAGE_SCHEME=rootless` 重编；②切换方案后没 `make clean`；③A12+ 的 arm64e 新 ABI 问题（§7.5）；④plist 的 Filter 没包含 `com.apple.springboard` |
| `.deb` 安装报架构不符 | rootless 必须是 `iphoneos-arm64`；确认用了 rootless 变量而非 rootful 的 `iphoneos-arm` |
| `dpkg-deb` 找不到 | `sudo apt install dpkg-dev` |
| 切换 rootful/rootless 后产物混乱 | 必须 `make clean` 再重编 |

---

## 12. 参考与依据

- Theos 官方安装文档：https://theos.dev/docs/installation-linux
- Theos Rootless 文档（/var/jb、THEOS_PACKAGE_SCHEME=rootless、arm64e 说明）：https://theos.dev/docs/rootless
- Theos SDK 仓库（iPhoneOS16.5.sdk 等）：https://github.com/theos/sdks
- 社区 SDK（iOS 17+）：https://github.com/xybp888/iOS-SDKs
- arm64e 旧 ABI 转换：https://github.com/p0358/allemande；CI 编译示例：https://github.com/p0358/SilentScreenshots/blob/master/.github/workflows/build.yml
- Microsoft WSL 安装：https://aka.ms/wslinstall

> 本机基线事实来源：本会话内 `pwsh` 实测（2026-11-18），非网络资料。上述网络资料的 SDK 版本、rootless 路径与 ABI 限制来自 Theos 官方站点与仓库。