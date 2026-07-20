# RTMPCamera - iOS 铏氭嫙鎽勫儚澶?
# 閫傞厤 iPhone 12 Pro + iOS 16.1 + Dopamine RootHide 鏃犳牴瓒婄嫳

ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:16.0
INSTALL_TARGET_PROCESSES = SpringBoard

# RootHide 鏃犳牴瓒婄嫳蹇呴』閰嶇疆
THEOS_PACKAGE_SCHEME = rootless

# 鑱氬悎缂栬瘧 (瀛愰」鐩?
include $(THEOS)/makefiles/common.mk

# 瀛愰」鐩畾涔?
SUBPROJECTS = RTMPDaemon RTMPCameraTweak RTMPCameraApp

# 娣诲姞鍏变韩澶存枃浠舵悳绱㈣矾寰?
ADDITIONAL_CFLAGS = -fobjc-arc -I$(THEOS_PROJECT_DIR)

include $(THEOS_MAKE_PATH)/aggregate.mk

# 鎵撳寘閰嶇疆
PACKAGE_VERSION = 1.0.2
PACKAGE_BUILD = 1

# 瀹夎鐩爣 (RootHide 璺緞)
after-install::
	install.exec "killall -9 SpringBoard || true"

