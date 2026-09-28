GLEAM ?= gleam

.PHONY: test check integration parity format build

test:
	$(GLEAM) test

check:
	$(GLEAM) format --check src test
	$(GLEAM) test

integration:
	GLEAM="$(GLEAM)" sh scripts/verify-integration.sh

# Missing drivers and unsupported required capabilities must fail.
parity:
	$(GLEAM) run -m parity/runner -- release "$(DRIVERS)" --manifest test/parity/v2/manifest.json

format:
	$(GLEAM) format src test

build:
	$(GLEAM) build
