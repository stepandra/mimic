# Repackaging only, after explicit approval. No default image and no installs.
# BASE_RUNTIME must be an already-approved, pinned local Erlang29/Python runtime
# containing the explicitly approved target/fixtures/shipment. Never build from
# the repository or a credential-bearing user application shipment.
ARG BASE_RUNTIME
FROM ${BASE_RUNTIME}
COPY boundary/ /boundary/
COPY launch forbidden /containment/
COPY containment_faults.py /qa/containment_faults.py
COPY inputs.sha256 /containment/inputs.sha256
# The target launcher switches to UID10001. PID1 is a different trusted UID.
USER 0:0
WORKDIR /tmp
ENTRYPOINT ["/usr/local/bin/erl", "-noshell", "-noinput", "+S", "1:1", "+A", "1", "-pa", "/boundary/mimic/ebin", "/boundary/gleam_stdlib/ebin", "/boundary/gleam_json/ebin", "/boundary/argv/ebin", "-eval", "mimic_containment_boot:boot()."]
