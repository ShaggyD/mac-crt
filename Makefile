.PHONY: build app run dev clean selftest

APP := build/Mac CRT.app
BIN := .build/release/MacCRT

build:
	swift build -c release

app:
	./scripts/build-app.sh release

run: app
	open "$(APP)"

selftest: build
	$(BIN) --selftest

# Debug loop: runs the raw binary, which shares the calling terminal's TCC
# identity and therefore skips the Screen Recording prompt.
dev:
	swift run -c debug

clean:
	rm -rf .build build
