# RTMPCameraApp Makefile
# Swift UIKit 设置 App

ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:16.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = RTMPCameraApp
RTMPCameraApp_FILES = main.swift AppDelegate.swift MainViewController.swift
RTMPCameraApp_FRAMEWORKS = UIKit Foundation AVFoundation CoreMedia CoreGraphics CoreServices UniformTypeIdentifiers
RTMPCameraApp_PRIVATE_FRAMEWORKS =
RTMPCameraApp_CFLAGS = -fobjc-arc
RTMPCameraApp_SWIFTFLAGS = -target arm64-apple-ios16.0 -import-objc-header ../SharedFrame.h
RTMPCameraApp_ICON_FILES = AppIcon60x60
RTMPCameraApp_INSTALL_PATH = /Applications

include $(THEOS_MAKE_PATH)/application.mk
