# Third-party notices

## CLIProxyAPI

Provider compatibility contracts and synthetic regression cases reference
[CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) at revision
`acdace936fa7df2905500c7f5e0a97d683138dea`. MIMIC's Gleam implementation is not
the CPA executable. Source-derived behavior is identified in the provider
documents and is not evidence of live compatibility. The upstream notice is
retained below for source adaptations.

```text
MIT License

Copyright (c) 2025-2005.9 Luis Pater
Copyright (c) 2025.9-present Router-For.ME

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Mist

Mist 6.0.3 is vendored under `vendor/mist` with its original
[Apache-2.0 license](vendor/mist/LICENSE). Its HTTP parser has a narrowly
scoped security-boundary patch; the archive checksums, original source
provenance and exact changes are documented in
[docs/MIST_VENDOR.md](docs/MIST_VENDOR.md).

Other dependencies are declared in `gleam.toml` and pinned in `manifest.toml`;
their own license notices accompany their distributions.
