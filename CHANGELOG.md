# Changelog

## 0.1.0 - 2026-10-21

- Consolidate the backup branch and Zig build/injector sources into main.
- Retain the current cross-compiled C package, socket error handling and single logging implementation.
- Publish version-tagged packages through the existing build workflow.

The Windows x86 package is built from C with `make package`. The Zig sources remain experimental.
