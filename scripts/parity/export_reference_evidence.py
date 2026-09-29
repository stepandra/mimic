"""Export only synthetic evidence; never copy target state, binaries or caches."""
import argparse
import json
from pathlib import Path
import tarfile

import reference_build as build


def selected(report):
    path = Path(report).resolve()
    results = (build.ROOT / "build/parity-results").resolve()
    if not path.is_relative_to(results) or path.is_symlink():
        raise ValueError("report must be a local parity result")
    value = json.loads(path.read_text())
    manifest = build.ROOT / "test/parity/v2/manifest.json"
    if (value["cpa_revision"] != build.REVISION
            or value["manifest_sha256"] != build.digest(manifest)
            or value["live_verified"] != "not_run"
            or value["required_total"] != 37):
        raise ValueError("unknown evidence scope")
    files = {path}
    for row in value["capabilities"]:
        directory = Path(row["artifacts"]).resolve()
        if not directory.is_relative_to(results):
            raise ValueError("artifact path outside lab")
        for plan_path in directory.glob("*.plan.json"):
            plan = json.loads(plan_path.read_text())
            fixture = json.loads(plan["fixture_json"])
            if fixture["provenance"] != "synthetic":
                raise ValueError("non-synthetic artifact")
            files.add(plan_path)
            result_path = plan_path.with_name(plan_path.name.replace(".plan.", ".result."))
            if result_path.exists():
                files.add(result_path)
        for target in ("mimic", "cpa"):
            for name in ("execution.json", "containment.json", "sandbox.sb", "target.log"):
                candidate = directory / target / "reference-runtime" / name
                if candidate.is_file():
                    files.add(candidate)
    return files


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reports", nargs="+", type=Path)
    args = parser.parse_args()
    files = {build.BUILD / "provenance.json", build.BUILD / "targets.json",
             build.ROOT / "test/parity/v2/manifest.json"}
    for name in ("provenance-initial.json", "targets-initial.json"):
        if (build.BUILD / name).is_file():
            files.add(build.BUILD / name)
    for name in ("final-gleam.log", "final-python.log", "final-release.log"):
        if (build.BUILD / name).is_file():
            files.add(build.BUILD / name)
    for report in args.reports:
        files.update(selected(report))
    for pattern in ("scripts/parity/*.py", "docs/parity/REFERENCE*.md",
                    "docs/parity/reference-v1/*.json", "test/parity/*.gleam"):
        files.update(build.ROOT.glob(pattern))
    # Exact bytes, no reserialization of observations. Nothing from runtime
    # credential stores or arbitrary recursive directory copies is accepted.
    files = sorted(files)
    identities = {build.digest(path) for path in files if path.name in
                  ("targets.json", "targets-initial.json")}
    for path in files:
        if path.name == "execution.json":
            if json.loads(path.read_text())["target_manifest_sha256"] not in identities:
                raise ValueError("missing historical target manifest; do not relabel old execution")
    index = {}
    for path in files:
        if path.is_symlink() or path.stat().st_size > 4 * 1024 * 1024:
            raise ValueError("unsafe evidence file")
        index[str(path.relative_to(build.ROOT))] = build.digest(path)
    output = build.BUILD / "evidence-manifest.json"
    output.write_text(json.dumps({
        "schema": "mimic.cpa-evidence-bundle/v1", "synthetic": True,
        "live_verified": "not_run", "files": index,
    }, indent=2) + "\n")
    archive = build.BUILD / "evidence.tar.gz"
    with tarfile.open(archive, "w:gz") as bundle:
        for path in [*files, output]:
            bundle.add(path, arcname=str(path.relative_to(build.ROOT)), recursive=False)
    print(json.dumps({"archive": str(archive), "sha256": build.digest(archive),
                      "manifest": str(output), "files": len(index)}, indent=2))


if __name__ == "__main__":
    main()
