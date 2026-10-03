TARGET := iphone:clang:10.3:6.0
ARCHS = armv7
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TorchLock
TorchLock_FILES = Tweak.x
TorchLock_FRAMEWORKS = UIKit AVFoundation CoreGraphics
TorchLock_CFLAGS = -Wno-deprecated-declarations
# The 10.3 SDK stubs omit _memset (iOS 6 libSystem has it); bind it at load time.
TorchLock_LDFLAGS = -Wl,-U,_memset
ifeq ($(DEBUG),1)
TorchLock_CFLAGS += -DTL_DEBUG=1
endif

include $(THEOS_MAKE_PATH)/tweak.mk
