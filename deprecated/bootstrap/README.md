# Legacy Bootstrap Compiler

This directory holds the deprecated Haskell bootstrap compiler.

- Bootstrap library sources live under `deprecated/bootstrap/src/Clasp/`.
- The self-hosted compiler now lives at the repository root in `src/`.
- The long-term goal is to keep shrinking this bootstrap layer until `claspc` runs entirely through the self-hosted native path.

While that takeover is still in progress, this tree remains the compatibility and recovery implementation for the public `claspc` CLI.
