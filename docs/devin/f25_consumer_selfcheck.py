#!/usr/bin/env python3
"""Pure synthetic F25 consumer checks: no sockets, CLI, SDK, CPA or live calls."""
import ast
import copy
import json
from pathlib import Path

import f25_local_cli as f25


def wire(events):
    return "".join("event: " + e["type"] + "\ndata: " + json.dumps(e) + "\n\n"
                   for e in events).encode()


def sample(kind, status="completed", zero=False, signed=False):
    usage = {"input_tokens": 0 if zero else 8, "output_tokens": 0 if zero else 5,
             "total_tokens": 0 if zero else 13}
    item = {"id": "synthetic-item", "type": kind}
    if kind == "message":
        item.update(role="assistant", status=status, content=[
            {"type": "output_text", "text": "synthetic text", "annotations": []}])
    elif kind == "function_call":
        item.update(call_id="synthetic-call", name="run",
                    arguments=' {"x":"€"} ', status="completed")
    else:
        item["summary"] = [{"type": "summary_text", "text": "synthetic reasoning"}]
        if signed:
            item["encrypted_content"] = f25.ENCRYPTED
    document = {"id": "resp_synthetic", "object": "response", "created_at": 42,
                "model": f25.MODEL, "status": status, "output": [item], "store": False,
                "error": None, "incomplete_details": None, "usage": usage,
                "devin": {"stop_reason": 2}, "tools": [],
                "tool_choice": "auto", "parallel_tool_calls": True}
    if status == "incomplete":
        document["incomplete_details"] = {"reason": "max_output_tokens"}
    created = copy.deepcopy(document)
    created.update(status="in_progress", output=[], incomplete_details=None)
    events = []

    def emit(event_type, **fields):
        events.append({"type": event_type, "sequence_number": len(events), **fields})

    emit("response.created", response=created)
    empty = copy.deepcopy(item)
    identity = {"output_index": 0, "item_id": item["id"]}
    if kind == "function_call":
        empty.update(arguments="", status="in_progress")
        emit("response.output_item.added", output_index=0, item=empty)
        names = {"name": item["name"], "call_id": item["call_id"]}
        emit("response.function_call_arguments.delta", **identity, **names, delta=item["arguments"])
        emit("response.function_call_arguments.done", **identity, **names, arguments=item["arguments"])
    else:
        group = "summary" if kind == "reasoning" else "content"
        part_name = "response.reasoning_summary_part" if group == "summary" else "response.content_part"
        text_name = "response.reasoning_summary_text" if group == "summary" else "response.output_text"
        empty[group] = []
        if kind == "message":
            empty["status"] = "in_progress"
        emit("response.output_item.added", output_index=0, item=empty)
        identity[group + "_index"] = 0
        part = item[group][0]
        empty_part = copy.deepcopy(part)
        empty_part["text"] = ""
        emit(part_name + ".added", **identity, part=empty_part)
        emit(text_name + ".delta", **identity, delta=part["text"])
        emit(text_name + ".done", **identity, text=part["text"])
        emit(part_name + ".done", **identity, part=part)
    emit("response.output_item.done", output_index=0, item=item)
    emit("response." + status, response=document)
    return document, events


def main():
    root = Path(__file__).resolve().parents[2]
    paths = ["docs/devin/f25_consumer_selfcheck.py", "docs/devin/f25_local_cli.py",
             "docs/devin/f23_local_cli.py", "docs/devin/f24_local_cli.py",
             "docs/devin/f27_local_cli.py", "scripts/smoke-gateway.py"]
    for path in paths:
        ast.parse((root / path).read_text(), filename=path)
    variants = [("message", "completed", False, False), ("message", "completed", True, False),
                ("message", "incomplete", False, False), ("function_call", "completed", False, False),
                ("reasoning", "completed", False, False), ("reasoning", "completed", False, True)]
    for variant in variants:
        expected, events = sample(*variant)
        assert f25.consume(wire(events)) == expected
    _, events = sample("function_call")
    bad = copy.deepcopy(events)
    bad[2]["name"] = "conflict"
    controls = [bad, events[:-1]]
    _, events = sample("message")
    bad = copy.deepcopy(events)
    bad[3]["delta"] = "incorrect snapshot"
    controls += [bad, [e for e in events if e["type"] != "response.output_text.done"]]
    for events in controls:
        try:
            f25.consume(wire(events))
        except AssertionError:
            pass
        else:
            raise AssertionError("consumer accepted malformed control")
    assert f25.consume(wire([{"type": "error", "code": "provider_unavailable",
        "message": "Devin Responses stream failed", "param": None, "sequence_number": 0}])) is None
    # Confirm this failure fixture is an actual float32 dimension, not malformed protobuf.
    fields = f25.catalog_helpers.fields(f25.fixture("estimated-usage")[1][5:])
    group = next(v for tag, kind, v in fields if (tag, kind) == (28, 2))
    metrics = [v for tag, kind, v in f25.catalog_helpers.fields(group) if (tag, kind) == (2, 2)]
    for metric in metrics:
        value = next(v for tag, kind, v in f25.catalog_helpers.fields(metric) if (tag, kind) == (4, 2))
        assert f25.catalog_helpers.fields(value)[0][:2] == (2, 5)
    print(json.dumps({"syntax_files": len(paths), "consumer_positive": len(variants),
                      "consumer_negative": len(controls), "safe_error": True,
                      "dimension_fixture_fixed32": True, "sockets": False, "cli": False,
                      "sdk": False}, sort_keys=True))


if __name__ == "__main__":
    main()
