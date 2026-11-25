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

TOOL_NAME = finchlog
finchlog_FILES = $(wildcard service/*.m) $(wildcard shared/*.m)
finchlog_CFLAGS = -fobjc-arc -Ishared -Iservice
finchlog_FRAMEWORKS = Foundation CoreFoundation IOKit SystemConfiguration
finchlog_LIBRARIES = z
finchlog_CODESIGN_FLAGS = -Sservice/entitlements.plist
finchlog_INSTALL_PATH = /usr/bin

APPLICATION_NAME = FinchLogs
FinchLogs_FILES = $(wildcard app/*.m) $(wildcard shared/*.m)
FinchLogs_CFLAGS = -fobjc-arc -Ishared -Iapp
FinchLogs_FRAMEWORKS = UIKit Foundation CoreFoundation CoreGraphics QuartzCore IOKit SystemConfiguration
FinchLogs_LIBRARIES = z
FinchLogs_RESOURCE_DIRS = app/Resources
FinchLogs_CODESIGN_FLAGS = -Sapp/entitlements.plist

include $(THEOS_MAKE_PATH)/tool.mk
include $(THEOS_MAKE_PATH)/application.mk

after-stage:: ; $(ECHO_NOTHING)chmod -R go-w "$(THEOS_STAGING_DIR)"$(ECHO_END)
