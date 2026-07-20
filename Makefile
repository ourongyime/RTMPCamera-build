# RTMPCamera - iOS 闁惧繑纰嶇€氭瑩骞楅崟顐㈠壖濠?
# 闂侇偄鍊块崢?iPhone 12 Pro + iOS 16.1 + Dopamine RootHide 闁哄啰濮甸悧瀵告惥婵犲嫬顏?

ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:16.0
INSTALL_TARGET_PROCESSES = SpringBoard

# RootHide 闁哄啰濮甸悧瀵告惥婵犲嫬顏伴煫鍥ф嚇閵嗗繘鏌婂鍥╂瀭
THEOS_PACKAGE_SCHEME = rootless

# 闁艰鲸鑹鹃幃搴ｇ磽閺嶎剛妲?(閻庢稒鍔欓妴宥夋儎?
include $(THEOS)/makefiles/common.mk

# 閻庢稒鍔欓妴宥夋儎椤旇偐鏆板☉?
SUBPROJECTS = RTMPDaemon RTMPCameraTweak RTMPCameraApp

# 婵烇綀顕ф慨鐐哄礂閸欐﹢鐓╁璺虹摠閺嬪啯绂掗懜鍨仢缂佷究鍨奸惌鎯ь嚗?
ADDITIONAL_CFLAGS = -fobjc-arc -I$(THEOS_PROJECT_DIR)

include $(THEOS_MAKE_PATH)/aggregate.mk

# 闁瑰灚鎸哥€垫﹢鏌婂鍥╂瀭
PACKAGE_VERSION = 1.0.16
PACKAGE_BUILD = 1

# 閻庣懓顦抽ˉ濠囨儎椤旂晫鍨?(RootHide 閻犱警鍨扮欢?
after-install::
	install.exec "killall -9 SpringBoard || true"

