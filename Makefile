.PHONY: build test lint format app dmg verify snapshots run probe clean

build:
	swift build

test:
	swift test

lint:
	swift format lint --strict --recursive Package.swift Sources Tests

format:
	swift format --in-place --recursive Package.swift Sources Tests

# `make app` builds only for this Mac's architecture (faster); `make dmg` builds a universal app.
app:
	UNIVERSAL=$${UNIVERSAL:-0} scripts/make-app.sh

dmg:
	UNIVERSAL=$${UNIVERSAL:-1} scripts/make-app.sh
	scripts/make-dmg.sh

verify:
	scripts/verify-dmg.sh "$$(cat build/dmg-path.txt)"

snapshots:
	swift run TapeloopSnapshots build/snapshots

run: app
	open build/Tapeloop.app

# Records 10 s of microphone and system audio through the app bundle (so macOS asks for the app's own
# permissions), keeps them compressed in RAM, then writes build/probe/probe-*.m4a and build/probe/report.txt.
PROBE_SECONDS ?= 10
probe: app
	rm -f build/probe/report.txt build/probe/probe-*.m4a
	open -W -n build/Tapeloop.app --args --probe --seconds $(PROBE_SECONDS) --out "$(CURDIR)/build/probe"
	@cat build/probe/report.txt

clean:
	swift package clean
	rm -rf build
