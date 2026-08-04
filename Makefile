ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:16.0
INSTALL_TARGET_PROCESSES = SpringBoard

THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

SUBPROJECTS = RTMPDaemon RTMPCameraTweak RTMPCameraApp

ADDITIONAL_CFLAGS = -fobjc-arc -I$(THEOS_PROJECT_DIR)

include $(THEOS_MAKE_PATH)/aggregate.mk

PACKAGE_VERSION = 1.0.76
PACKAGE_BUILD = 1

after-install::
	install.exec "killall -9 SpringBoard || true"