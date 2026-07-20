# RTMPDaemon Makefile
# 后台守护进程 - RTMP接收 + 本地视频 + 帧缓冲共享内存

ARCHS = arm64 arm64e
TARGET = iphone:clang:16.1:16.1
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TOOL_NAME = RTMPDaemon
RTMPDaemon_FILES = main.m
RTMPDaemon_FRAMEWORKS = Foundation AVFoundation CoreMedia CoreVideo VideoToolbox
RTMPDaemon_PRIVATE_FRAMEWORKS =
RTMPDaemon_CFLAGS = -fobjc-arc -I$(THEOS_PROJECT_DIR)
RTMPDaemon_LDFLAGS = -lz -lbz2 -liconv
RTMPDaemon_CODESIGN_FLAGS = -Sentitlements.plist
RTMPDaemon_INSTALL_PATH = /usr/local/bin

include $(THEOS_MAKE_PATH)/tool.mk
