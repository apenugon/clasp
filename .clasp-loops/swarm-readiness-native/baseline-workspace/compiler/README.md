# Compiler Layout

The self-hosted Clasp compiler now lives at `src/`, with the entrypoint at `src/Main.clasp`.

The legacy Haskell bootstrap compiler now lives under `deprecated/bootstrap/src/Clasp/`.

Verify the promoted self-hosted compiler entrypoint on the native path with:

```sh
bash src/scripts/verify.sh
```
