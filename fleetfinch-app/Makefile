THEOS ?= $(HOME)/.fleetfinch/theos
export THEOS

TARGET := iphone:clang:9.3:9.0
ARCHS := armv7
DEBUG ?= 0
FINALPACKAGE ?= 1
THEOS_PACKAGE_SCHEME :=
GO_EASY_ON_ME := 0
export THEOS_PLATFORM_DEB_COMPRESSION_TYPE := gzip

include $(THEOS)/makefiles/common.mk

TOOL_NAME = fleetfinch
fleetfinch_FILES = $(wildcard tool/*.m) $(wildcard shared/*.m)
fleetfinch_CFLAGS = -fobjc-arc -Ishared -Itool
fleetfinch_FRAMEWORKS = Foundation CoreFoundation IOKit MobileCoreServices
fleetfinch_PRIVATE_FRAMEWORKS = MobileWiFi
fleetfinch_CODESIGN_FLAGS = -Stool/entitlements.plist
fleetfinch_INSTALL_PATH = /usr/bin

APPLICATION_NAME = FleetFinch
FleetFinch_FILES = $(wildcard app/*.m) $(wildcard shared/*.m)
FleetFinch_CFLAGS = -fobjc-arc -Iapp -Ishared
FleetFinch_FRAMEWORKS = UIKit Foundation CoreGraphics
FleetFinch_RESOURCE_DIRS = app/Resources
FleetFinch_CODESIGN_FLAGS = -Sapp/entitlements.plist

include $(THEOS_MAKE_PATH)/tool.mk
include $(THEOS_MAKE_PATH)/application.mk

after-stage:: ; $(ECHO_NOTHING)chmod -R go-w "$(THEOS_STAGING_DIR)"$(ECHO_END)
