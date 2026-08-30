APP_NAME := Linea Lite
BUNDLE_ID := io.github.linea.desktop-lite
SIGN_IDENTITY ?= Linea Local Development
BUILD_DIR := build
APP_DIR := $(BUILD_DIR)/$(APP_NAME).app
BIN := $(APP_DIR)/Contents/MacOS/$(APP_NAME)
VERSION := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
ARCH := $(shell uname -m)
DMG := $(BUILD_DIR)/Linea-Lite-$(VERSION)-macos-$(ARCH).dmg
PACKAGE_DIR := $(BUILD_DIR)/package
QWEN_ASR_BIN ?= .runtime/qwen-asr
SOURCES := Sources/LineaLite/CaptureHUD.swift Sources/LineaLite/CaptureVisuals.swift Sources/LineaLite/HistoryMenuView.swift Sources/LineaLite/HistoryStore.swift Sources/LineaLite/PushToTalkState.swift Sources/LineaLite/QwenRuntime.swift Sources/LineaLite/TextCleanup.swift Sources/LineaLite/WorkspaceVocabulary.swift Sources/LineaLite/main.swift
TEST_SOURCES := Sources/LineaLite/CaptureVisuals.swift Sources/LineaLite/HistoryStore.swift Sources/LineaLite/PushToTalkState.swift Sources/LineaLite/QwenRuntime.swift Sources/LineaLite/TextCleanup.swift Sources/LineaLite/WorkspaceVocabulary.swift Tests/main.swift

.PHONY: build run test package clean

build:
	test -x "$(QWEN_ASR_BIN)"
	mkdir -p "$(APP_DIR)/Contents/MacOS" "$(APP_DIR)/Contents/Resources/bin"
	cp Info.plist "$(APP_DIR)/Contents/Info.plist"
	cp "$(QWEN_ASR_BIN)" "$(APP_DIR)/Contents/Resources/bin/qwen-asr"
	cp -R Resources/. "$(APP_DIR)/Contents/Resources/"
	xcrun swiftc -O -framework AppKit -framework ApplicationServices -framework AVFoundation $(SOURCES) -o "$(BIN)"
	@if security find-identity -v -p codesigning | /usr/bin/grep -Fq '"$(SIGN_IDENTITY)"'; then \
		codesign --force --sign "$(SIGN_IDENTITY)" --identifier "$(BUNDLE_ID)" "$(APP_DIR)"; \
	else \
		codesign --force --sign - --identifier "$(BUNDLE_ID)" "$(APP_DIR)"; \
	fi
	codesign --verify --deep --strict "$(APP_DIR)"

run: build
	open "$(APP_DIR)"

package: build
	test -z "$$(find "$(APP_DIR)" -type f -name '*.gguf' -print -quit)"
	rm -rf "$(PACKAGE_DIR)" "$(DMG)"
	mkdir -p "$(PACKAGE_DIR)"
	ditto "$(APP_DIR)" "$(PACKAGE_DIR)/$(APP_NAME).app"
	ln -s /Applications "$(PACKAGE_DIR)/Applications"
	hdiutil create -quiet -volname "$(APP_NAME)" -srcfolder "$(PACKAGE_DIR)" -format UDZO "$(DMG)"
	hdiutil verify "$(DMG)"
	@echo "$(DMG)"

test:
	mkdir -p "$(BUILD_DIR)"
	xcrun swiftc $(TEST_SOURCES) -o "$(BUILD_DIR)/tests"
	"$(BUILD_DIR)/tests"

clean:
	rm -rf "$(BUILD_DIR)"
