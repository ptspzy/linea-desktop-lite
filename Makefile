APP_NAME := Linea Lite
BUILD_DIR := build
APP_DIR := $(BUILD_DIR)/$(APP_NAME).app
BIN := $(APP_DIR)/Contents/MacOS/$(APP_NAME)
SOURCES := Sources/LineaLite/TextCleanup.swift Sources/LineaLite/main.swift

.PHONY: build run test clean

build:
	mkdir -p "$(APP_DIR)/Contents/MacOS"
	cp Info.plist "$(APP_DIR)/Contents/Info.plist"
	xcrun swiftc -O -framework AppKit -framework AVFoundation -framework Speech $(SOURCES) -o "$(BIN)"

run: build
	open "$(APP_DIR)"

test:
	mkdir -p "$(BUILD_DIR)"
	xcrun swiftc Sources/LineaLite/TextCleanup.swift Tests/main.swift -o "$(BUILD_DIR)/text-cleanup-tests"
	"$(BUILD_DIR)/text-cleanup-tests"

clean:
	rm -rf "$(BUILD_DIR)"
