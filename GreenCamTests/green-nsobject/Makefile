ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:16.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = GreenCamNSObject
GreenCamNSObject_FILES = Tweak.x
GreenCamNSObject_CFLAGS = -fobjc-arc
GreenCamNSObject_FRAMEWORKS = Foundation AVFoundation CoreMedia CoreVideo UIKit

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 SpringBoard || true"
