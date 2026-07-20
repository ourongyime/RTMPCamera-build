# RTMPCameraTweak Makefile
# Logos/ObjC Tweak - Hook AVFoundation 替换摄像头画面

ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:16.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = RTMPCameraTweak
RTMPCameraTweak_FILES = Tweak.x
RTMPCameraTweak_FRAMEWORKS = UIKit Foundation AVFoundation CoreMedia CoreVideo
RTMPCameraTweak_CFLAGS = -fobjc-arc -I$(THEOS_PROJECT_DIR)
RTMPCameraTweak_LDFLAGS = -lz
RTMPCameraTweak_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/tweak.mk
