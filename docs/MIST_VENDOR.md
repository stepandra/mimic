# Mist 6.0.3 parser boundary patch

MIMIC uses the local `vendor/mist` package rather than a floating fork. The
source artifact is the official Hex tarball:

- URL: `https://repo.hex.pm/tarballs/mist-6.0.3.tar`
- SHA-256 of the **outer tarball** (the original manifest `outer_checksum`):
  `1B07F321D5FA0CB162D81496F2DE96AEB6EF8980F4F38230A4CC3F849497E020`
- License: Apache-2.0, original unmodified text at `vendor/mist/LICENSE`
  (SHA-256 `c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4`).

The package contains the original `gleam.toml` (SHA-256
`1f545b2f729b9affd576ff0e7fe73491d09b606c242410f52b8b38210df33192`),
all 15 Gleam sources and its Erlang FFI. Hex's generated Erlang modules,
generated includes, `.app.src`, build output, and README are not needed as
source/build inputs and are not vendored. The top-level `gleam.toml` and
`manifest.toml` change only Mist's dependency source to `vendor/mist`; all
other dependency versions and checksums remain locked.

## Source SHA-256 before the patch

These are hashes of files extracted from that verified Hex tarball. Every
vendored source file has the same hash, except `src/mist/internal/http.gleam`.

```text
b6ffd52630d7827580aa88b913f67c5f42a76e1c3005a21c2e3336b0ed705ca0  src/mist_ffi.erl
489e4883d11db7abf7190a48688e577fb083a041d1403cf765d35cd547dc091d  src/mist.gleam
f2a691365e64934d21662cd9ad5fbbd12e42a2075d21e3c11f22082ee4591945  src/mist/internal/buffer.gleam
1c09aafb936b324311f898c8058264bb7838bf3f5a5d5dccdeac444b236c1f25  src/mist/internal/clock.gleam
e9aefcc0bd68a389cd5789ba30870041bb7d35e15a8bf127c2cfa33c081fb165  src/mist/internal/encoder.gleam
2052018f6c3cf26308c02b52a0cfc6dbee78853f1c9a97c9590b98595d347efc  src/mist/internal/file.gleam
d9f7830847f4e94ea2218ea8a972cb5e41910aa26783f1d08a96e9769517cd07  src/mist/internal/handler.gleam
18f5d2fe5272faa2967d9f76f030e725665dd78d89c99900b9b9dd4e5feff151  src/mist/internal/http.gleam
53893814ffc904538376e2ebb8c63d31d6e3ba63d88901cf0b038c3c95ba3efe  src/mist/internal/http/handler.gleam
9f999409c044f9e3ccac25e339a01a25f319f76c0945ca836b86da7893f31104  src/mist/internal/http2.gleam
767b4682197a7992c5e9900c49fee51dd35aa22bb2a4fa07ca6f85677dd36191  src/mist/internal/http2/flow_control.gleam
c11c2f13ed63a11b69e4631a67aba18758ac6eabae8da2e0904b5adc2e8ab5a1  src/mist/internal/http2/frame.gleam
94ac6f4f2b922b5740110915f76bd1f74d65d9349bf964ba1be2a5f6febe85e5  src/mist/internal/http2/handler.gleam
e91fd2b753c59afc7478e84bb97a28e3af0a3d6dbed8be515dd28fe22fea13ff  src/mist/internal/http2/stream.gleam
0ed67f72287c3c58e3bb8d9024d0cd9351455d7e2497c54457e0c2493e507718  src/mist/internal/next.gleam
c419b32f63df86768eac89874f700c3907a85bd656e57c68e984f9aedf9ba7e3  src/mist/internal/websocket.gleam
```

The patched `src/mist/internal/http.gleam` SHA-256 is
`4dc4dbf0fc3f35b3496679c36e204ef104c5c11b243519bf94576ade716695dc`.

## Minimal source difference

Only `src/mist/internal/http.gleam` changes:

1. A prominent modification notice identifies the patched file.
2. Before `dict.insert` erases duplicates, reject a second case-insensitive
   `Authorization`, `Host`, `Upgrade`, `Sec-WebSocket-Key`,
   `Sec-WebSocket-Version`, `Sec-WebSocket-Protocol`, or
   `Sec-WebSocket-Extensions` field with Mist's existing `MalformedRequest`
   error. No field values enter the error. Duplicates of list-valued
   `Connection`, `Accept`, and other non-singleton headers retain Mist's
   original handling.
3. Before constructing a `Request` (which does not retain the HTTP version),
   reject an HTTP/1.0 request with an `Upgrade` header. Ordinary HTTP/1.0
   remains supported. The original `Initial(rest)` body bytes remain intact.

The behavior is tested through actual loopback raw TCP connections to a Mist
handler in `test/mist_boundary_test.gleam`, with a namespaced test FFI. The
unmodified Hex source fails four test groups (duplicate Authorization, Host,
WebSocket singleton, HTTP/1.0 upgrade); the patched source passes all six
groups, including a real valid HTTP/1.1 WebSocket handshake, legal repeated
list headers, and a coalesced body.

To reverify provenance, fetch the URL above, check the outer SHA-256, extract
`contents.tar.gz` from the tarball, then compare the source hashes. Only the
documented parser diff should remain. Do not replace it with generated Erlang
from the Hex archive or patch `build/packages/mist`.

`gleam format --check` passes for the modified parser and boundary test. It
does not pass for the unchanged upstream `http2/frame.gleam` under Gleam
1.18.1; the original `mist.gleam` also contains one trailing space on its
SSE comment line, so `git diff --check` flags that newly vendored line.
These original bytes are intentionally retained for provenance rather than
silently creating unrelated vendored source diffs.
