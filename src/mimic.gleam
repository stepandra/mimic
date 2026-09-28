import argv
import gleam/io
import mimic/auth
import mimic/autopilot
import mimic/check
import mimic/control
import mimic/corpus
import mimic/demo
import mimic/differ
import mimic/doctor
import mimic/drive
import mimic/fleet
import mimic/ingress
import mimic/lab
import mimic/observability
import mimic/persona
import mimic/pipeline
import mimic/quota
import mimic/recorder
import mimic/replay
import mimic/watch
import mimic/workshop

pub fn main() {
  case dispatch(argv.load().arguments) {
    Ok(output) -> {
      case output {
        "" -> Nil
        _ -> io.println(output)
      }
    }
    Error(message) -> {
      io.println_error("mimic: " <> message)
      exit(1)
    }
  }
}

/// Feature modules own argument validation and may block while serving.
pub fn dispatch(args: List(String)) -> Result(String, String) {
  case args {
    [] | ["help"] | ["--help"] | ["-h"] -> Ok(help())
    ["version"] | ["--version"] -> Ok("mimic 0.1.0")
    ["doctor"] -> doctor.run()
    ["demo", ..args] -> demo.cli(args)
    ["record", ..args] -> recorder.cli(args)
    ["corpus", ..args] -> corpus.cli(args)
    ["diff", ..args] -> differ.cli(args)
    ["persona", ..args] -> persona.cli(args)
    ["replay", ..args] -> replay.cli(args)
    ["lab", ..args] -> lab.cli(args)
    ["check", ..args] -> check.cli(args)
    ["auth", ..args] -> auth.cli(args)
    ["fleet", "quotas", ..args] -> quota.cli(args)
    ["fleet", ..args] -> fleet.cli(args)
    ["quota", ..args] -> quota.cli(args)
    ["serve", ..args] -> ingress.cli(args)
    ["drive", ..args] -> drive.cli(args)
    ["watch", ..args] -> watch.cli(args)
    ["workshop", "lab-bump", ..args] -> pipeline.cli(args)
    ["workshop", ..args] -> workshop.cli(args)
    ["autopilot", ..args] -> autopilot.cli(args)
    ["metrics"] -> observability.cli(["metrics"])
    ["metrics", ..args] -> observability.cli(args)
    ["obs", ..args] -> observability.cli(args)
    ["management", ..args] -> control.cli(args)
    _ -> Error("unknown command; run `mimic help` for available commands")
  }
}

pub fn help() -> String {
  "MIMIC — local compatibility laboratory

Usage: mimic <command> [arguments]

  record       Record HTTP/1.1 requests into a redacted corpus
  corpus       Add, list, select, export, and rotate captures
  diff         Structured header, beta, JSON, and transport drift
  persona      Lint, validate, and draft TOML wire profiles
  replay       Materialize a persona and replay to a configured endpoint
  lab          Run the deterministic loopback echo/SSE laboratory
  check        Check response acceptance and time-to-first-byte bounds
  auth         Operator-owned OAuth/credential lifecycle
  fleet        Credential selection, status, and quotas
  quota        Inspect the persisted quota ledger
  serve        Authenticated Anthropic/OpenAI-compatible ingress
  drive        Run a pinned, sandboxed capture scenario
  watch        Detect package-version changes and queue Workshop events
  workshop     Resumable PB/PO/CO pipelines with fail-closed gates
  autopilot    Constrained, evidence-validated local model roles
  metrics      Secret-safe observability
  management   Authenticated control API and vendored panel
  doctor       Check local runtime/tool prerequisites
  demo         Exercise corpus → persona → replay → lab with a synthetic fixture
  version      Print the application version

Run a command without arguments for its usage.
No live provider traffic or OAuth login is performed by default.
See README.md and docs/ for supported protocols and validation evidence."
}

@external(erlang, "mimic_cli_ffi", "exit")
fn exit(status: Int) -> Nil
