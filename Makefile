.PHONY: build app run clean

build:
	swift build -c release

app:
	./scripts/build-app.sh release

run: app
	open build/CRTOverlay.app

# Debug loop: runs the raw binary, which shares the calling terminal's TCC identity.
dev:
	swift run -c debug

clean:
	rm -rf .build build
