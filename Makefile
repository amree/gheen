.PHONY: build run clean install

APP     = Gheen.app
SOURCES = $(wildcard Sources/Gheen/*.swift)

build: $(APP)

$(APP): $(SOURCES) Resources/Info.plist
	@rm -rf $(APP)
	@mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	@echo "==> Compiling (Apple Silicon, target macOS 13)"
	@swiftc \
		-swift-version 5 \
		-target arm64-apple-macosx13.0 \
		-O \
		-framework SwiftUI \
		-framework AppKit \
		-framework UserNotifications \
		-o $(APP)/Contents/MacOS/Gheen \
		$(SOURCES)
	@echo "==> Bundling Info.plist"
	@cp Resources/Info.plist $(APP)/Contents/Info.plist
	@echo "==> Ad-hoc signing"
	@codesign --force --deep --sign - $(APP)
	@echo "==> Built $(APP)"

run: build
	open $(APP)

clean:
	rm -rf $(APP)

install: build
	cp -R $(APP) /Applications/$(APP)
	@echo "==> Installed to /Applications/$(APP)"
