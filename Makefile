APP_NAME := Linea Lite
BUNDLE_ID := io.github.linea.desktop-lite
SIGN_IDENTITY ?= Linea Local Development
BUILD_DIR := build
APP_DIR := $(BUILD_DIR)/$(APP_NAME).app
BIN := $(APP_DIR)/Contents/MacOS/$(APP_NAME)
NATIVE_ARCH := $(shell uname -m)
VERSION := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
DMG := $(BUILD_DIR)/Linea-Lite-$(VERSION)-macos-universal.dmg
PACKAGE_DIR := $(BUILD_DIR)/package
QWEN_ASR_BIN ?= .runtime/macos-$(NATIVE_ARCH)/qwen-asr
ARM_QWEN_ASR_BIN ?= .runtime/macos-arm64/qwen-asr
X86_QWEN_ASR_BIN ?= .runtime/macos-x86_64/qwen-asr
ARM_APP_BIN := $(BUILD_DIR)/$(APP_NAME)-arm64
X86_APP_BIN := $(BUILD_DIR)/$(APP_NAME)-x86_64
SOURCES := Sources/LineaLite/CaptureHUD.swift Sources/LineaLite/CaptureVisuals.swift Sources/LineaLite/HistoryMenuView.swift Sources/LineaLite/HistoryStore.swift Sources/LineaLite/PushToTalkState.swift Sources/LineaLite/QwenRuntime.swift Sources/LineaLite/TextCleanup.swift Sources/LineaLite/WorkspaceVocabulary.swift Sources/LineaLite/main.swift
TEST_SOURCES := Sources/LineaLite/CaptureVisuals.swift Sources/LineaLite/HistoryStore.swift Sources/LineaLite/PushToTalkState.swift Sources/LineaLite/QwenRuntime.swift Sources/LineaLite/TextCleanup.swift Sources/LineaLite/WorkspaceVocabulary.swift Tests/main.swift

.PHONY: build build-universal run test package runtime-arm64 runtime-x86_64 runtimes clean

build:
	test -x "$(QWEN_ASR_BIN)"
	mkdir -p "$(APP_DIR)/Contents/MacOS" "$(APP_DIR)/Contents/Resources/bin"
	cp Info.plist "$(APP_DIR)/Contents/Info.plist"
	cp "$(QWEN_ASR_BIN)" "$(APP_DIR)/Contents/Resources/bin/qwen-asr"
	cp -R Resources/. "$(APP_DIR)/Contents/Resources/"
	xcrun swiftc -O -target $(NATIVE_ARCH)-apple-macosx13.5 -framework AppKit -framework ApplicationServices -framework AVFoundation $(SOURCES) -o "$(BIN)"
	@if security find-identity -v -p codesigning | /usr/bin/grep -Fq '"$(SIGN_IDENTITY)"'; then \
		codesign --force --sign "$(SIGN_IDENTITY)" "$(APP_DIR)/Contents/Resources/bin/qwen-asr"; \
		codesign --force --sign "$(SIGN_IDENTITY)" --identifier "$(BUNDLE_ID)" "$(APP_DIR)"; \
	else \
		codesign --force --sign - "$(APP_DIR)/Contents/Resources/bin/qwen-asr"; \
		codesign --force --sign - --identifier "$(BUNDLE_ID)" "$(APP_DIR)"; \
	fi
	codesign --verify --strict "$(APP_DIR)/Contents/Resources/bin/qwen-asr"
	codesign --verify --deep --strict "$(APP_DIR)"

build-universal:
	test -x "$(ARM_QWEN_ASR_BIN)"
	test -x "$(X86_QWEN_ASR_BIN)"
	lipo "$(ARM_QWEN_ASR_BIN)" -verify_arch arm64
	lipo "$(X86_QWEN_ASR_BIN)" -verify_arch x86_64
	mkdir -p "$(APP_DIR)/Contents/MacOS" "$(APP_DIR)/Contents/Resources/bin"
	cp Info.plist "$(APP_DIR)/Contents/Info.plist"
	lipo -create "$(ARM_QWEN_ASR_BIN)" "$(X86_QWEN_ASR_BIN)" -output "$(APP_DIR)/Contents/Resources/bin/qwen-asr"
	cp -R Resources/. "$(APP_DIR)/Contents/Resources/"
	xcrun swiftc -O -target arm64-apple-macosx13.5 -framework AppKit -framework ApplicationServices -framework AVFoundation $(SOURCES) -o "$(ARM_APP_BIN)"
	xcrun swiftc -O -target x86_64-apple-macosx13.5 -framework AppKit -framework ApplicationServices -framework AVFoundation $(SOURCES) -o "$(X86_APP_BIN)"
	lipo -create "$(ARM_APP_BIN)" "$(X86_APP_BIN)" -output "$(BIN)"
	@if security find-identity -v -p codesigning | /usr/bin/grep -Fq '"$(SIGN_IDENTITY)"'; then \
		codesign --force --sign "$(SIGN_IDENTITY)" "$(APP_DIR)/Contents/Resources/bin/qwen-asr"; \
		codesign --force --sign "$(SIGN_IDENTITY)" --identifier "$(BUNDLE_ID)" "$(APP_DIR)"; \
	else \
		codesign --force --sign - "$(APP_DIR)/Contents/Resources/bin/qwen-asr"; \
		codesign --force --sign - --identifier "$(BUNDLE_ID)" "$(APP_DIR)"; \
	fi
	lipo "$(BIN)" -verify_arch arm64 x86_64
	lipo "$(APP_DIR)/Contents/Resources/bin/qwen-asr" -verify_arch arm64 x86_64
	codesign --verify --strict "$(APP_DIR)/Contents/Resources/bin/qwen-asr"
	codesign --verify --deep --strict "$(APP_DIR)"

run: build
	open "$(APP_DIR)"

package: build-universal
	test -z "$$(find "$(APP_DIR)" -type f -name '*.gguf' -print -quit)"
	rm -rf "$(PACKAGE_DIR)" "$(DMG)"
	mkdir -p "$(PACKAGE_DIR)"
	ditto "$(APP_DIR)" "$(PACKAGE_DIR)/$(APP_NAME).app"
	ln -s /Applications "$(PACKAGE_DIR)/Applications"
	hdiutil create -quiet -volname "$(APP_NAME)" -srcfolder "$(PACKAGE_DIR)" -format UDZO "$(DMG)"
	hdiutil verify "$(DMG)"
	@echo "$(DMG)"

runtime-arm64:
	./scripts/build-qwen-runtime.sh macos-arm64

runtime-x86_64:
	./scripts/build-qwen-runtime.sh macos-x86_64

runtimes: runtime-arm64 runtime-x86_64

test:
	mkdir -p "$(BUILD_DIR)"
	xcrun swiftc $(TEST_SOURCES) -o "$(BUILD_DIR)/tests"
	"$(BUILD_DIR)/tests"

clean:
	rm -rf "$(BUILD_DIR)"
