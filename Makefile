BUILD_DIR := .build
APP_DIR := $(BUILD_DIR)/OneMaestro.app
APP_ZIP := $(BUILD_DIR)/OneMaestro.zip
OBJCFLAGS := -fobjc-arc -Wall -Wextra
SWIFTFLAGS := -O -parse-as-library -module-cache-path $(BUILD_DIR)/swift-module-cache
FRAMEWORKS := -framework Foundation -framework IOKit -framework IOUSBHost
COREAUDIO_FRAMEWORKS := -framework CoreAudio -framework CoreFoundation
ONE_CONTROL_FRAMEWORKS := -framework Foundation -framework IOKit -framework IOUSBHost -framework CoreAudio -framework CoreFoundation

.PHONY: all clean probe coreaudio-probe one-control app sign-app package

all: probe coreaudio-probe one-control

probe: $(BUILD_DIR)/apogee-one-probe

coreaudio-probe: $(BUILD_DIR)/coreaudio-probe

one-control: $(BUILD_DIR)/one-control

app: $(APP_DIR)/Contents/MacOS/OneMaestro

sign-app: app
	codesign --force --deep --sign - $(APP_DIR)

package: sign-app
	ditto -c -k --keepParent $(APP_DIR) $(APP_ZIP)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(BUILD_DIR)/apogee-one-probe: tools/apogee-one-probe/main.m | $(BUILD_DIR)
	clang $(OBJCFLAGS) $(FRAMEWORKS) $< -o $@

$(BUILD_DIR)/coreaudio-probe: tools/coreaudio-probe/main.c | $(BUILD_DIR)
	clang -Wall -Wextra $(COREAUDIO_FRAMEWORKS) $< -o $@

$(BUILD_DIR)/one-control: tools/one-control/main.m | $(BUILD_DIR)
	clang $(OBJCFLAGS) $(ONE_CONTROL_FRAMEWORKS) $< -o $@

$(APP_DIR)/Contents/MacOS/OneMaestro: apps/OneMaestro/OneMaestroApp.swift apps/OneMaestro/Info.plist $(BUILD_DIR)/one-control | $(BUILD_DIR)
	mkdir -p $(APP_DIR)/Contents/MacOS $(APP_DIR)/Contents/Resources
	cp apps/OneMaestro/Info.plist $(APP_DIR)/Contents/Info.plist
	cp $(BUILD_DIR)/one-control $(APP_DIR)/Contents/Resources/one-control
	swiftc $(SWIFTFLAGS) -framework SwiftUI -framework AppKit -framework CoreAudio $< -o $@

clean:
	rm -rf $(BUILD_DIR)
