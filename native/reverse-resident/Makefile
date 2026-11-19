# Makefile — the reverse resident, built with Theos on the device or on a Mac.
#
# Nothing here is part of the pnpm workspace: the resident is the jailbreak-side half
# of the reverse capability, shipped as a tweak rather than a harness package. Build
# it where a Theos toolchain lives:
#
#   THEOS=/opt/theos make package
#
# and install the resulting .deb with the user's package manager.

TARGET = iphone:clang:16.5:15.0
ARCHS = arm64 arm64e

# A roothide device takes the roothide scheme; rootless and rootful take the
# default. The scheme changes where the package installs, nothing else:
#   THEOS=/opt/theos THEOS_PACKAGE_SCHEME=roothide make package
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ReverseResident
ReverseResident_FILES = Tweak.xm RVServer.m RVProcess.m RVMachO.m RVMemory.m
ReverseResident_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-unused-parameter
ReverseResident_FRAMEWORKS = Foundation UIKit

include $(THEOS_MAKE_PATH)/tweak.mk