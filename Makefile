APP_NAME := Linea Lite
BUNDLE_ID := io.github.linea.desktop-lite
SIGN_IDENTITY ?= Linea Local Development
SIGN_FLAGS ?=
SWIFT_FLAGS ?= -O -warnings-as-errors -strict-concurrency=complete
MACOS_DEPLOYMENT_TARGET := 13.0
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
SOURCES := Sources/LineaLite/AudioSegmentation.swift Sources/LineaLite/CaptureHUD.swift Sources/LineaLite/CaptureVisuals.swift Sources/LineaLite/HistoryMenuView.swift Sources/LineaLite/HistoryStore.swift Sources/LineaLite/PasteboardSupport.swift Sources/LineaLite/PushToTalkState.swift Sources/LineaLite/QwenRuntime.swift Sources/LineaLite/TextCleanup.swift Sources/LineaLite/WorkspaceVocabulary.swift Sources/LineaLite/main.swift
TEST_SOURCES := Sources/LineaLite/AudioSegmentation.swift Sources/LineaLite/CaptureVisuals.swift Sources/LineaLite/HistoryStore.swift Sources/LineaLite/PasteboardSupport.swift Sources/LineaLite/PushToTalkState.swift Sources/LineaLite/QwenRuntime.swift Sources/LineaLite/TextCleanup.swift Sources/LineaLite/WorkspaceVocabulary.swift Tests/main.swift
COVERAGE_SOURCES := Sources/LineaLite/AudioSegmentation.swift Sources/LineaLite/CaptureVisuals.swift Sources/LineaLite/HistoryStore.swift Sources/LineaLite/PasteboardSupport.swift Sources/LineaLite/PushToTalkState.swift Sources/LineaLite/QwenRuntime.swift Sources/LineaLite/TextCleanup.swift Sources/LineaLite/WorkspaceVocabulary.swift

.PHONY: build build-universal compile-check coverage lint run test test-quality test-quality-corpus test-quality-x86 smoke verify package release runtime-arm64 runtime-x86_64 runtimes clean

build:
	test -x "$(QWEN_ASR_BIN)"
	rm -rf "$(APP_DIR)"
	mkdir -p "$(APP_DIR)/Contents/MacOS" "$(APP_DIR)/Contents/Resources/bin"
	cp Info.plist "$(APP_DIR)/Contents/Info.plist"
	cp "$(QWEN_ASR_BIN)" "$(APP_DIR)/Contents/Resources/bin/qwen-asr"
	cp -R Resources/. "$(APP_DIR)/Contents/Resources/"
	xcrun swiftc $(SWIFT_FLAGS) -target $(NATIVE_ARCH)-apple-macosx$(MACOS_DEPLOYMENT_TARGET) -framework AppKit -framework ApplicationServices -framework AVFoundation $(SOURCES) -o "$(BIN)"
	@if security find-identity -v -p codesigning | /usr/bin/grep -Fq '"$(SIGN_IDENTITY)"'; then \
		codesign --force $(SIGN_FLAGS) --sign "$(SIGN_IDENTITY)" "$(APP_DIR)/Contents/Resources/bin/qwen-asr"; \
		codesign --force $(SIGN_FLAGS) --sign "$(SIGN_IDENTITY)" --identifier "$(BUNDLE_ID)" --entitlements Entitlements.plist "$(APP_DIR)"; \
	else \
		codesign --force --sign - "$(APP_DIR)/Contents/Resources/bin/qwen-asr"; \
		codesign --force --sign - --identifier "$(BUNDLE_ID)" --entitlements Entitlements.plist "$(APP_DIR)"; \
	fi
	codesign --verify --strict "$(APP_DIR)/Contents/Resources/bin/qwen-asr"
	codesign --verify --deep --strict "$(APP_DIR)"

build-universal:
	test -x "$(ARM_QWEN_ASR_BIN)"
	test -x "$(X86_QWEN_ASR_BIN)"
	lipo "$(ARM_QWEN_ASR_BIN)" -verify_arch arm64
	lipo "$(X86_QWEN_ASR_BIN)" -verify_arch x86_64
	rm -rf "$(APP_DIR)" "$(ARM_APP_BIN)" "$(X86_APP_BIN)"
	mkdir -p "$(APP_DIR)/Contents/MacOS" "$(APP_DIR)/Contents/Resources/bin"
	cp Info.plist "$(APP_DIR)/Contents/Info.plist"
	lipo -create "$(ARM_QWEN_ASR_BIN)" "$(X86_QWEN_ASR_BIN)" -output "$(APP_DIR)/Contents/Resources/bin/qwen-asr"
	cp -R Resources/. "$(APP_DIR)/Contents/Resources/"
	xcrun swiftc $(SWIFT_FLAGS) -target arm64-apple-macosx$(MACOS_DEPLOYMENT_TARGET) -framework AppKit -framework ApplicationServices -framework AVFoundation $(SOURCES) -o "$(ARM_APP_BIN)"
	xcrun swiftc $(SWIFT_FLAGS) -target x86_64-apple-macosx$(MACOS_DEPLOYMENT_TARGET) -framework AppKit -framework ApplicationServices -framework AVFoundation $(SOURCES) -o "$(X86_APP_BIN)"
	lipo -create "$(ARM_APP_BIN)" "$(X86_APP_BIN)" -output "$(BIN)"
	@if security find-identity -v -p codesigning | /usr/bin/grep -Fq '"$(SIGN_IDENTITY)"'; then \
		codesign --force $(SIGN_FLAGS) --sign "$(SIGN_IDENTITY)" "$(APP_DIR)/Contents/Resources/bin/qwen-asr"; \
		codesign --force $(SIGN_FLAGS) --sign "$(SIGN_IDENTITY)" --identifier "$(BUNDLE_ID)" --entitlements Entitlements.plist "$(APP_DIR)"; \
	else \
		codesign --force --sign - "$(APP_DIR)/Contents/Resources/bin/qwen-asr"; \
		codesign --force --sign - --identifier "$(BUNDLE_ID)" --entitlements Entitlements.plist "$(APP_DIR)"; \
	fi
	lipo "$(BIN)" -verify_arch arm64 x86_64
	lipo "$(APP_DIR)/Contents/Resources/bin/qwen-asr" -verify_arch arm64 x86_64
	@test "$$(xcrun vtool -show-build "$(BIN)" | /usr/bin/grep -c "minos $(MACOS_DEPLOYMENT_TARGET)")" -eq 2
	@test "$$(xcrun vtool -show-build "$(APP_DIR)/Contents/Resources/bin/qwen-asr" | /usr/bin/grep -c "minos $(MACOS_DEPLOYMENT_TARGET)")" -eq 2
	codesign --verify --strict "$(APP_DIR)/Contents/Resources/bin/qwen-asr"
	codesign --verify --deep --strict "$(APP_DIR)"

run: build
	open "$(APP_DIR)"

compile-check:
	mkdir -p "$(BUILD_DIR)"
	xcrun swiftc $(SWIFT_FLAGS) -target $(NATIVE_ARCH)-apple-macosx$(MACOS_DEPLOYMENT_TARGET) -framework AppKit -framework ApplicationServices -framework AVFoundation $(SOURCES) -o "$(BUILD_DIR)/compile-check"

package: test build-universal
	test -z "$$(find "$(APP_DIR)" -type f -name '*.gguf' -print -quit)"
	rm -rf "$(PACKAGE_DIR)" "$(DMG)"
	mkdir -p "$(PACKAGE_DIR)"
	ditto "$(APP_DIR)" "$(PACKAGE_DIR)/$(APP_NAME).app"
	ln -s /Applications "$(PACKAGE_DIR)/Applications"
	hdiutil create -quiet -volname "$(APP_NAME)" -srcfolder "$(PACKAGE_DIR)" -format UDZO "$(DMG)"
	hdiutil verify "$(DMG)"
	@echo "$(DMG)"

smoke:
	./scripts/smoke-app.sh "$(APP_DIR)"

test-quality:
	./scripts/test-real-model.sh "$(APP_DIR)"

test-quality-corpus:
	@if test -f "$(HOME)/Library/Application Support/local-voice-dictation-stable/benchmarks/human-reference.jsonl"; then \
		LINEA_QUALITY_MANIFEST="$(HOME)/Library/Application Support/local-voice-dictation-stable/benchmarks/human-reference.jsonl" ./scripts/test-real-model.sh "$(APP_DIR)"; \
	else \
		echo "Local human voice corpus not found; skipped."; \
	fi

test-quality-x86:
	LINEA_RUNTIME_ARCH=x86_64 ./scripts/test-real-model.sh "$(APP_DIR)"

verify:
	$(MAKE) clean
	$(MAKE) lint
	$(MAKE) coverage
	$(MAKE) package
	$(MAKE) smoke
	$(MAKE) test-quality
	$(MAKE) test-quality-corpus
	$(MAKE) test-quality-x86

release:
	@case "$(SIGN_IDENTITY)" in "Developer ID Application:"*) ;; *) echo "release requires SIGN_IDENTITY='Developer ID Application: ...'" >&2; exit 1;; esac
	@test -n "$(NOTARY_PROFILE)" || (echo "release requires NOTARY_PROFILE" >&2; exit 1)
	@security find-identity -v -p codesigning | /usr/bin/grep -Fq '"$(SIGN_IDENTITY)"' || (echo "Developer ID identity not found" >&2; exit 1)
	$(MAKE) clean
	$(MAKE) lint
	$(MAKE) coverage
	$(MAKE) package SIGN_IDENTITY="$(SIGN_IDENTITY)" SIGN_FLAGS="--options runtime --timestamp"
	$(MAKE) smoke
	$(MAKE) test-quality
	$(MAKE) test-quality-x86
	NOTARY_PROFILE="$(NOTARY_PROFILE)" ./scripts/notarize.sh "$(DMG)"

runtime-arm64:
	./scripts/build-qwen-runtime.sh macos-arm64

runtime-x86_64:
	./scripts/build-qwen-runtime.sh macos-x86_64

runtimes: runtime-arm64 runtime-x86_64

test:
	mkdir -p "$(BUILD_DIR)"
	xcrun swiftc $(SWIFT_FLAGS) -framework AppKit -framework AVFoundation $(TEST_SOURCES) -o "$(BUILD_DIR)/tests"
	"$(BUILD_DIR)/tests"

lint:
	plutil -lint Info.plist Entitlements.plist
	bash -n scripts/*.sh

coverage:
	rm -rf "$(BUILD_DIR)/coverage"
	mkdir -p "$(BUILD_DIR)/coverage"
	xcrun swiftc $(SWIFT_FLAGS) -profile-generate -profile-coverage-mapping -framework AppKit -framework AVFoundation $(TEST_SOURCES) -o "$(BUILD_DIR)/coverage/tests"
	LLVM_PROFILE_FILE="$(BUILD_DIR)/coverage/default.profraw" "$(BUILD_DIR)/coverage/tests"
	xcrun llvm-profdata merge -sparse "$(BUILD_DIR)/coverage/default.profraw" -o "$(BUILD_DIR)/coverage/default.profdata"
	xcrun llvm-cov report "$(BUILD_DIR)/coverage/tests" -instr-profile="$(BUILD_DIR)/coverage/default.profdata" $(COVERAGE_SOURCES) | tee "$(BUILD_DIR)/coverage/report.txt"
	@percent="$$(awk '/TOTAL/ { gsub(/%/, "", $$10); print $$10 }' "$(BUILD_DIR)/coverage/report.txt")"; \
		awk -v percent="$$percent" 'BEGIN { if (percent + 0 < 70) { print "Line coverage " percent "% is below 70%" > "/dev/stderr"; exit 1 } }'

clean:
	rm -rf "$(BUILD_DIR)"
