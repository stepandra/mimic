GLEAM ?= gleam

.PHONY: test check format build

test:
	$(GLEAM) test

check:
	$(GLEAM) format --check src test
	$(GLEAM) test

format:
	$(GLEAM) format src test

build:
	$(GLEAM) build
