#!/bin/sh
# Local synthetic integration gate. This is NOT the CPA differential gate.
set -eu

cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
GLEAM=${GLEAM:-gleam}
export PYTHONDONTWRITEBYTECODE=1

"$GLEAM" format --check src test
"$GLEAM" test
"$GLEAM" run -- doctor
"$GLEAM" run -m parity/runner -- check --manifest test/parity/v2/manifest.json
python3 -m unittest discover -s scripts/parity -p 'test_*.py' -v

# Exercise the exact assembled modules, not source-copy overlays.
"$GLEAM" run -m provider_runtime_scenarios
"$GLEAM" run -m claude_provider_scenarios
"$GLEAM" run -m claude_runtime_v4_test
"$GLEAM" run -m mimic/providers/codex/scenario
mkdir -p build/integration
codex_state=$(mktemp -d "$PWD/build/integration/codex-scenario.XXXXXXXX")
chmod 700 "$codex_state"
"$GLEAM" run -m mimic/providers/codex/local -- "$codex_state"
"$GLEAM" run -m responses_scenario
"$GLEAM" run -m devin_scenarios
"$GLEAM" run -m gateway_websocket_test -- --strict
GLEAM="$GLEAM" python3 scripts/smoke-gateway.py
GLEAM="$GLEAM" python3 scripts/smoke-http-providers.py
GLEAM="$GLEAM" python3 scripts/smoke-provider-websocket.py

# Keep each VM separate; restoration must not reseed credentials.
mkdir -p build/integration
state=$(mktemp -d "$PWD/build/integration/claude-restart.XXXXXXXX")
chmod 700 "$state"
"$GLEAM" run -m claude_runtime_v4_test -- seed "$state"
"$GLEAM" run -m claude_runtime_v4_test -- restore "$state"

"$GLEAM" export erlang-shipment
python3 scripts/smoke-gateway.py --shipment build/erlang-shipment
python3 scripts/smoke-http-providers.py --shipment build/erlang-shipment
python3 scripts/smoke-provider-websocket.py --shipment build/erlang-shipment
printf '%s\n' 'Local integration checks passed. CPA differential/live gates were not run.'
