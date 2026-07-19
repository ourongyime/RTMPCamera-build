# RTMPCamera - iOS 虚拟摄像头

将 OBS RTMP 推流 / 本地视频 / 测试帧注入为 iOS 系统摄像头画面，替换微信、视频号等 App 的摄像头输入。

## 环境要求

| 项目 | 要求 |
|------|------|
| 设备 | iPhone 12 Pro |
| 系统 | iOS 16.1 |
| 越狱 | Dopamine RootHide (无根越狱) |
| Tweak 注入 | ElleKit |
| 包管理 | Sileo |

## 项目结构

```
RTMPCamera/
├── Makefile                          # 根 Makefile (aggregate)
├── control                           # 包元信息 (iphoneos-arm64e)
├── SharedFrame.h                     # 共享内存帧结构定义
├── RTMPCameraApp/                    # Swift UIKit 控制面板 App
│   ├── Makefile                      # APPLICATION 类型
│   ├── Info.plist                    # Bundle 配置 + 图标
│   ├── entitlements.plist
│   ├── main.swift
│   ├── AppDelegate.swift
│   └── MainViewController.swift      # 主界面 (视频源切换)
├── RTMPCameraTweak/                  # Logos/ObjC Hook 注入
│   ├── Makefile                      # TWEAK 类型
│   ├── Tweak.x                       # Hook AVFoundation
│   └── RTMPCameraTweak.plist         # Bundle filter
├── RTMPDaemon/                       # 后台守护进程
│   ├── Makefile                      # TOOL 类型
│   ├── main.m                        # RTMP拉流 + 帧缓冲
│   └── entitlements.plist
├── layout/                           # deb 包布局
│   └── DEBIAN/
│       ├── postinst                  # 安装脚本 (RootHide兼容)
│       ├── prerm                     # 卸载脚本 (不删dylib)
│       ├── preinst
│       └── postrm
└── .github/workflows/build.yml       # GitHub Actions 编译
```

## 编译方法

### 本地编译 (macOS + Theos)

```bash
# 1. 安装 Theos
git clone --recursive https://github.com/theos/theos.git /opt/theos

# 2. 设置 SDK
SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path)
ln -s "$SDK_PATH" /opt/theos/sdks/iPhoneOS16.1.sdk

# 3. 编译
export THEOS=/opt/theos
make package FINALPACKAGE=1

# 4. 产出: packages/*.deb
```

### GitHub Actions 编译

推送代码到 GitHub 仓库后，Actions 自动编译，产出 deb 包在 Artifacts 中下载。

## 安装方法

### Sileo 安装

1. 将 deb 包上传到 APT 源站
2. 在 Sileo 中添加源: `http://apt.chizicn.com`
3. 搜索 "RTMPCamera" 并安装
4. 安装完成后桌面会出现「虚拟摄像头」图标

### 手动安装

```bash
# SSH 到手机后
scp packages/com.rtmpcamera.camera_1.0.0_iphoneos-arm64e.deb root@手机IP:/var/jb/tmp/
ssh root@手机IP "dpkg -i /var/jb/tmp/com.rtmpcamera.camera_1.0.0_iphoneos-arm64e.deb"
ssh root@手机IP "uicache -p /var/jb/Applications"
ssh root@手机IP "killall -9 SpringBoard"
```

## 使用方法

1. 桌面打开「虚拟摄像头」App
2. 选择视频源:
   - **真实摄像头**: 正常使用手机摄像头
   - **RTMP流**: 输入 OBS 推流地址，手机拉流
   - **本地视频**: 选择 MP4/MOV 文件
   - **测试帧**: 彩色渐变测试画面
3. 点击「应用设置」
4. 打开微信/视频号等 App，摄像头画面已替换

## APT 源站上传

### HTTP 上传

```bash
curl -F "file=@packages/com.rtmpcamera.camera_1.0.0_iphoneos-arm64e.deb" \
     http://apt.chizicn.com/upload.php
```

### FTP 上传

```bash
ftp -n mb.chizicn.com 21 <<EOF
user apt_chizicn_com phEQSiyFfFkabSrK
binary
put packages/com.rtmpcamera.camera_1.0.0_iphoneos-arm64e.deb
bye
EOF
```

### 上传后刷新源索引

SSH 登录源站服务器，执行:
```bash
cd /var/www/apt/debs
dpkg-scanpackages . /dev/null | gzip -9c > Packages.gz
```

## 技术要点

- **共享内存**: daemon 通过 mmap 共享内存向 tweak 传递 BGRA 视频帧
- **Hook 方法**: MSHookMessageEx Hook AVCaptureVideoDataOutput 和 AVCaptureDevice
- **RootHide 适配**: 所有路径使用 /var/jb 前缀，postinst/prerm 兼容判断
- **帧格式**: 统一 kCVPixelFormatType_32BGRA
- **进程管理**: LaunchDaemon plist + launchctl
