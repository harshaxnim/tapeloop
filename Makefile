.PHONY: build test lint format app dmg verify snapshots run clean

build:
	swift build

test:
	swift test

lint:
	swift format lint --strict --recursive Package.swift Sources Tests

format:
	swift format --in-place --recursive Package.swift Sources Tests

app:
	scripts/make-app.sh

dmg: app
	scripts/make-dmg.sh

verify:
	scripts/verify-dmg.sh "$$(cat build/dmg-path.txt)"

snapshots:
	swift run RearviewSnapshots build/snapshots

run: app
	open build/Rearview.app

clean:
	rm -rf .build build
