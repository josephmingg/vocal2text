# Vocal — developer entry points. CI and humans use the same commands.

.PHONY: test build generate mac clean reset-tcc

# Build + run all package tests (pure targets work on Linux; full graph on macOS).
test:
	swift test

build:
	swift build

# Generate the Xcode project for the app shells (requires: brew install xcodegen).
generate:
	xcodegen generate

# Build the macOS app from the command line after `make generate`.
mac: generate
	xcodebuild -project Vocal.xcodeproj -scheme VocalMac -configuration Debug build

# Release-build VocalMac and install it to /Applications as Vocal.app.
# Requires the signing Team to be selected once in Xcode (Signing & Capabilities).
install:
	xcodebuild -project Vocal.xcodeproj -scheme VocalMac -configuration Release \
		-derivedDataPath build -allowProvisioningUpdates build
	rm -rf /Applications/Vocal.app
	ditto build/Build/Products/Release/VocalMac.app /Applications/Vocal.app
	@echo "✅ Installed /Applications/Vocal.app — grant mic + Accessibility once for this copy."

# Zip the installed app for sharing to another Mac (AirDrop the zip).
share: install
	cd /Applications && zip -r -y ~/Desktop/Vocal.zip Vocal.app
	@echo "✅ ~/Desktop/Vocal.zip ready to AirDrop."

clean:
	rm -rf .build Vocal.xcodeproj

# Development hygiene: clear wedged TCC grants after signing changes (docs/03 §3.4).
# Both bundle IDs. Debug runs from Xcode are com.vocal.mac.dev, but `make
# install` ships Release as com.vocal.mac — and a wedged grant on the installed
# copy is the one that actually stops you dictating, so resetting only the dev
# ID left the failing case untouched.
reset-tcc:
	tccutil reset Accessibility com.vocal.mac || true
	tccutil reset Microphone com.vocal.mac || true
	tccutil reset Accessibility com.vocal.mac.dev || true
	tccutil reset Microphone com.vocal.mac.dev || true
