# RTMPCamera - iOS 虚拟摄像头
# 适配 iPhone 12 Pro + iOS 16.1 + Dopamine RootHide 无根越狱

ARCHS = arm64 arm64e
TARGET = iphone:clang:16.1:16.1
INSTALL_TARGET_PROCESSES = SpringBoard

# RootHide 无根越狱必须配置
THEOS_PACKAGE_SCHEME = rootless

# 聚合编译 (子项目)
include $(THEOS)/makefiles/common.mk

# 子项目定义
SUBPROJECTS = RTMPDaemon RTMPCameraTweak RTMPCameraApp

# 添加共享头文件搜索路径
ADDITIONAL_CFLAGS = -fobjc-arc -I$(THEOS_PROJECT_DIR)

include $(THEOS_MAKE_PATH)/aggregate.mk

# 打包配置
PACKAGE_VERSION = 1.0.2
PACKAGE_BUILD = 1

# 安装目标 (RootHide 路径)
after-install::
	install.exec "killall -9 SpringBoard || true"

