.PHONY: build test fmt-check check run-list run-tui

build:
	zig build

test:
	zig build test

fmt-check:
	zig fmt --check src

check: fmt-check test

run-list:
	zig build run -- list

run-tui:
	zig build run -- tui
