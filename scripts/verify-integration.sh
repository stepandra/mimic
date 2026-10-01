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
# Source/unit admission only. Never implicitly export/run a CPA candidate.
python3 scripts/parity/safe_unit_tests.py
python3 -m unittest discover -s scripts/release -p 'test_*.py' -v
# Unit contracts only: guarded synthetic loopback, no downloads/containers/clients.
python3 -I -S -B scripts/release/native_contracts.py

# Exercise the exact assembled modules, not source-copy overlays.
"$GLEAM" run -m provider_runtime_scenarios
"$GLEAM" run -m claude_provider_scenarios
"$GLEAM" run -m claude_runtime_v4_test
"$GLEAM" run -m claude_429_test
"$GLEAM" run -m mimic/providers/codex/scenario
mkdir -p build/integration
codex_state=$(mktemp -d "$PWD/build/integration/codex-scenario.XXXXXXXX")
chmod 700 "$codex_state"
"$GLEAM" run -m mimic/providers/codex/local -- "$codex_state"
"$GLEAM" run -m responses_scenario
"$GLEAM" run -m devin_scenarios
GLEAM="$GLEAM" python3 docs/devin/f22_local_cli.py
GLEAM="$GLEAM" python3 docs/devin/f23_local_cli.py
"$GLEAM" run -m gateway_websocket_test -- --strict
GLEAM="$GLEAM" python3 scripts/smoke-gateway.py
GLEAM="$GLEAM" python3 scripts/smoke-http-providers.py
GLEAM="$GLEAM" python3 scripts/smoke-enrollment.py
GLEAM="$GLEAM" python3 -m unittest discover -s test -p 'kimi_wire_test.py' -v
python3 scripts/smoke-kimi-compat-stream.py --self-test
GLEAM="$GLEAM" python3 scripts/smoke-kimi-compat-stream.py
python3 scripts/smoke-kimi-messages-stream.py --self-test
GLEAM="$GLEAM" python3 scripts/smoke-kimi-messages-stream.py
GLEAM="$GLEAM" python3 scripts/smoke-provider-websocket.py
GLEAM="$GLEAM" python3 scripts/smoke-codex-http.py

# Keep each VM separate; restoration must not reseed credentials.
mkdir -p build/integration
state=$(mktemp -d "$PWD/build/integration/claude-restart.XXXXXXXX")
chmod 700 "$state"
"$GLEAM" run -m claude_runtime_v4_test -- seed "$state"
"$GLEAM" run -m claude_runtime_v4_test -- restore "$state"

"$GLEAM" export erlang-shipment
python3 docs/devin/f22_local_cli.py --shipment build/erlang-shipment
python3 docs/devin/f23_local_cli.py --shipment build/erlang-shipment
python3 scripts/smoke-gateway.py --shipment build/erlang-shipment
python3 scripts/smoke-http-providers.py --shipment build/erlang-shipment
python3 scripts/smoke-enrollment.py --shipment build/erlang-shipment
python3 scripts/smoke-kimi-compat-stream.py --shipment build/erlang-shipment
python3 scripts/smoke-kimi-messages-stream.py --shipment build/erlang-shipment
python3 scripts/smoke-provider-websocket.py --shipment build/erlang-shipment
python3 scripts/smoke-codex-http.py --shipment build/erlang-shipment
printf '%s\n' 'Local integration checks passed. CPA differential/live gates were not run.'
