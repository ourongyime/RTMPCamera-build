ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:16.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = GreenCamSwizzle
GreenCamSwizzle_FILES = Tweak.x
GreenCamSwizzle_CFLAGS = -fobjc-arc
GreenCamSwizzle_FRAMEWORKS = Foundation AVFoundation CoreMedia CoreVideo UIKit
GreenCamSwizzle_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 SpringBoard || true"
