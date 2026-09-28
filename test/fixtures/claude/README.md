# Synthetic Claude fixtures

These fixtures are authored test inputs, not captures from Anthropic or Claude
Code. They exercise native Anthropic JSON shapes discussed in the pinned CPA
sources listed in `docs/CLAUDE_PROVIDER.md`. IDs, signatures, tokens, model names
and tools are synthetic. No fixture establishes a measured client fingerprint.

`native_messages.json` covers thinking/signature preservation, a tool call and
result, unknown extensions, and explicit 1h-before-default-5m cache placement.
