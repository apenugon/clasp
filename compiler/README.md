# Compiler Layout

The self-hosted Clasp compiler lives at `src/`, with the entrypoint at `src/Main.clasp`.

The Haskell bootstrap compiler is retired and is no longer an active source tree, fallback, or ordinary verification target.

Verify the promoted self-hosted compiler entrypoint on the native path with:

```sh
bash src/scripts/verify.sh
```
