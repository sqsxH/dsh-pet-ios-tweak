dsh-pet 动画素材目录（会被打进 deb 安装到此路径）

放置方法（在 WSL2 / Git Bash 里）：
  SRC_DIR=<dsh-pet>/assets/webm \
  OUT_ROOT="C:/Users/ASUS/Documents/deepseek-harness/default-workspace/tweak/layout/Library/Application Support/dsh-pet" \
  bash tools/transcode-webm/transcode.sh

转码后每个动画是一个目录：
  <动画名>/frames/frame_00001.webp ...
  <动画名>/anim.json

首版最小素材清单（core-spec §3.4）：
  待机呼吸休闲、东张西望、被鼠标拖拽悬空反馈、
  点击回应-开心跃动、点击回应-害羞惊讶、点击回应-傲娇生气、
  点击回应-挠痒咯咯笑、点击回应-元气挥手

打包：THEOS_PACKAGE_SCHEME=rootless make package
