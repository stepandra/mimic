# Synthetic D auth configuration

This is a **local mock example**, not a measured Claude profile. It contains
no credential values and must not be treated as a live-provider preset.

Pre-create an absolute private state directory (`0700`); credential files
are written `0600`. Configure the environment before invoking
`mimic auth login claude`:

```text
MIMIC_CLAUDE_CLIENT_ID=synthetic-client
MIMIC_CLAUDE_AUTHORIZE_URL=http://127.0.0.1:9080/authorize
MIMIC_CLAUDE_TOKEN_URL=http://127.0.0.1:9080/token
MIMIC_CLAUDE_REDIRECT_URI=http://127.0.0.1:9222/callback
MIMIC_STATE_DIR=/absolute/private/state
```

The configured authorize and token endpoint must be owned by the operator.
No network access occurs merely from setting these variables. The CLI
performs a login only when explicitly invoked and never accepts token/code
values as arguments. For a real endpoint, use HTTPS and provider-approved
client configuration; that flow has not been verified.
