APP_NAME := Linea Lite
BUNDLE_ID := io.github.linea.desktop-lite
BUILD_DIR := build
APP_DIR := $(BUILD_DIR)/$(APP_NAME).app
BIN := $(APP_DIR)/Contents/MacOS/$(APP_NAME)
SOURCES := Sources/LineaLite/PushToTalkState.swift Sources/LineaLite/TextCleanup.swift Sources/LineaLite/main.swift

.PHONY: build run test clean

build:
	mkdir -p "$(APP_DIR)/Contents/MacOS"
	cp Info.plist "$(APP_DIR)/Contents/Info.plist"
	xcrun swiftc -O -framework AppKit -framework ApplicationServices -framework AVFoundation -framework Speech $(SOURCES) -o "$(BIN)"
	codesign --force --sign - --identifier "$(BUNDLE_ID)" "$(APP_DIR)"
	codesign --verify --deep --strict "$(APP_DIR)"

run: build
	open "$(APP_DIR)"

test:
	mkdir -p "$(BUILD_DIR)"
	xcrun swiftc Sources/LineaLite/PushToTalkState.swift Sources/LineaLite/TextCleanup.swift Tests/main.swift -o "$(BUILD_DIR)/tests"
	"$(BUILD_DIR)/tests"

clean:
	rm -rf "$(BUILD_DIR)"
