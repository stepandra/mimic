# Acquisition only. Both amd64 manifests are pinned; never build during execution.
FROM python:3.12.12-slim-bookworm@sha256:2986c55feb36e6cae00fa1fefb454283e4b33f35e75ff8bdd123b134130be301 AS python
FROM erlang:29.0-slim@sha256:04f8492a880e591288974ba5d5572e2a833fa3f9c62deceed207f2336d8d072b
COPY --from=python /usr/local/bin/python3.12 /usr/local/bin/python3
COPY --from=python /usr/local/lib/python3.12 /usr/local/lib/python3.12
COPY --from=python /usr/local/lib/libpython3.12.so.1.0 /usr/local/lib/
ENV LD_LIBRARY_PATH=/usr/local/lib
COPY claude /clients/claude
COPY codex-tree /clients/codex/
COPY harness.py fixtures.py evidence.py qa.py clients.lock.json Dockerfile /qa/
RUN chmod -R a+rX /qa /clients && chmod 0555 /clients/claude \
    && python3 -c "import ssl, socket, resource" && erl -noshell -eval 'halt().'
USER 10001:10001
WORKDIR /work
ENTRYPOINT ["python3", "/qa/harness.py"]
