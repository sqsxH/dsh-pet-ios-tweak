# =====================================================================
# dsh-pet → SpringBoard tweak 工程（Theos / rootless）
# 参考：docs/build-env-setup.md §7.2、docs/springboard-re.md §5 §9
# 构建：THEOS_PACKAGE_SCHEME=rootless make package
# 清理：THEOS_PACKAGE_SCHEME=rootless make clean
# =====================================================================

# rootless（Dopamine / palera1n）：Theos 自动加 /var/jb 安装前缀、
# 自动把 install_name 改为 @rpath、自动设置 iphoneos-arm64 架构。
THEOS_PACKAGE_SCHEME ?= rootless

ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
    # WSL2 无法原生编译 arm64e 新 ABI（build-env-setup.md §7.5）。
    # 默认只编 arm64，可在 A11 及以下（palera1n checkm8）设备测试。
    # 若走 GitHub Actions / macOS，可用 make ARCHS="arm64 arm64e" 追加。
    ARCHS = arm64
    # Theos TARGET 格式：iphone:clang:<SDK>:<最低 iOS 版本>。
    # rootless 要求 iOS 15+；这里显式锁 SDK 16.5 / Deployment 15.0。
    # （任务描述中的 "TARGET=iphone:clang:latest:arm64" 里的 arm64 实际由 ARCHS 表达。）
    TARGET = iphone:clang:16.5:15.0
else
    ARCHS = armv7 armv7s arm64
    TARGET = iphone:clang:latest:7.0
endif

include $(THEOS)/makefiles/common.mk

# 运行时资源目录（相对越狱根）。代码里统一用 ROOT_PATH_NS 读取，
# rootless 下实际路径为 /var/jb/Library/Application Support/dsh-pet/。
PET_RESOURCE_DIR = /Library/Application Support/dsh-pet

TWEAK_NAME = dshpet

dshpet_FILES = Tweak.xm PetManager.xm PetOverlayWindow.xm PetView.xm
dshpet_FRAMEWORKS = UIKit CoreGraphics QuartzCore Foundation
dshpet_CFLAGS = -DPET_RESOURCE_DIR='"$(PET_RESOURCE_DIR)/"' -Wall -Wno-unused-parameter -Wno-unused-const-variable -fobjc-arc

# Theos 默认查找 $(TWEAK_NAME).plist；工程规范文件名是 com.yourid.dshpet.plist。
# 下面规则在打包前同步二者，修改 filter 时只需改规范文件。
dshpet.plist: com.yourid.dshpet.plist
	@cp -f $< $@

before-package:: dshpet.plist
before-install:: dshpet.plist

include $(THEOS_MAKE_PATH)/tweak.mk

# =====================================================================
# 动画素材打包：把 tools/transcode-webm 的转码产物装进 deb。
# 约定：转码产物放在 tweak/layout/Library/Application Support/dsh-pet/
#       （Theos 会把 layout/ 下内容按原路径装入越狱根；rootless 自动加 /var/jb）
# 若你用 OUT_ROOT 指到别处，把下面 PET_ASSET_SRC 改成那个目录即可。
# =====================================================================
PET_ASSET_SRC ?= $(THEOS_PROJECT_DIR)/layout/Library/Application Support/dsh-pet

before-package::
	@mkdir -p "$(PET_ASSET_SRC)"
	@echo "[dshpet] 素材目录: $(PET_ASSET_SRC)"
	@if [ -z "$$(ls -A \"$(PET_ASSET_SRC)\" 2>/dev/null)" ]; then \
		echo "[dshpet] 警告: 素材目录为空，请先运行 tools/transcode-webm/transcode.sh"; \
	fi

# NOTE: do NOT delete dshpet.plist in after-clean. Theos needs it at the
# stage step of the NEXT make package; removing it here broke CI packaging.
# dshpet.plist is a checked-in copy of com.yourid.dshpet.plist.
