# RTMPCamera - iOS 閾忔碍瀚欓幗鍕剼�?
# 闁倿鍘?iPhone 12 Pro + iOS 16.1 + Dopamine RootHide 閺冪姵鐗寸搾濠勫�?

ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:16.0
INSTALL_TARGET_PROCESSES = SpringBoard

# RootHide 閺冪姵鐗寸搾濠勫韫囧懘銆忛柊宥囩枂
THEOS_PACKAGE_SCHEME = rootless

# 閼辨艾鎮庣紓鏍�?(鐎涙劙銆嶉惄?
include $(THEOS)/makefiles/common.mk

# 鐎涙劙銆嶉惄顔肩暰娑?
SUBPROJECTS = RTMPDaemon RTMPCameraTweak RTMPCameraApp

# 濞ｈ濮為崗鍙橀煩婢跺瓨鏋冩禒鑸垫偝缁便垼鐭惧?
ADDITIONAL_CFLAGS = -fobjc-arc -I$(THEOS_PROJECT_DIR)

include $(THEOS_MAKE_PATH)/aggregate.mk

# 閹垫挸瀵橀柊宥囩枂
PACKAGE_VERSION = 1.0.36
PACKAGE_BUILD = 1

# 鐎瑰顥婇惄顔界�?(RootHide 鐠侯垰绶?
after-install::
	install.exec "killall -9 SpringBoard || true"

