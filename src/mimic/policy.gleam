import gleam/int
import gleam/list
import gleam/string
import mimic/types.{type Capture, type Header}
import mimic/workshop.{type DriftClass, Breaking, Major, Trivial}

/// Automatic promotion is deliberately narrower than a general drift report.
/// Unknown structural changes need review. A version-looking change inside
/// arbitrary text is not enough to qualify as a version-only bump.
pub fn classify(
  baseline: Capture,
  candidate: Capture,
  baseline_accepted: Bool,
) -> DriftClass {
  case baseline_accepted {
    False -> Breaking
    True -> {
      case version_only(baseline, candidate) {
        True -> Trivial
        False -> Major
      }
    }
  }
}

pub fn version_only(baseline: Capture, candidate: Capture) -> Bool {
  baseline.client == candidate.client
  && baseline.endpoint == candidate.endpoint
  && baseline.request_kind == candidate.request_kind
  && baseline.method == candidate.method
  && baseline.target == candidate.target
  && baseline.http_version == candidate.http_version
  && baseline.body == candidate.body
  && baseline.transport == candidate.transport
  && versions_compatible(baseline.version, candidate.version)
  && headers_version_only(baseline.headers, candidate.headers)
}

fn versions_compatible(before: String, after: String) -> Bool {
  before == after || { semver(before) && semver(after) }
}

fn semver(value: String) -> Bool {
  case string.split(value, ".") {
    [major, minor, patch] -> {
      list.all([major, minor, patch], fn(part) {
        case int.parse(part) {
          Ok(number) -> number >= 0 && int.to_string(number) == part
          Error(_) -> False
        }
      })
    }
    _ -> False
  }
}

fn user_agent_version_only(before: String, after: String) -> Bool {
  case string.split(before, " "), string.split(after, " ") {
    [old_product, ..old_suffix], [new_product, ..new_suffix]
      if old_suffix == new_suffix
    -> {
      case string.split(old_product, "/"), string.split(new_product, "/") {
        [old_name, old_version], [new_name, new_version] -> {
          old_name != ""
          && old_name == new_name
          && semver(old_version)
          && semver(new_version)
        }
        _, _ -> False
      }
    }
    _, _ -> False
  }
}

fn headers_version_only(before: List(Header), after: List(Header)) -> Bool {
  case before, after {
    [], [] -> True
    [old, ..old_rest], [new, ..new_rest] if old.name == new.name -> {
      let allowed = case old.value == new.value {
        True -> True
        False -> {
          case string.lowercase(old.name) {
            "user-agent" -> user_agent_version_only(old.value, new.value)
            "x-stainless-package-version" -> {
              semver(old.value) && semver(new.value)
            }
            _ -> False
          }
        }
      }
      allowed && headers_version_only(old_rest, new_rest)
    }
    _, _ -> False
  }
}
