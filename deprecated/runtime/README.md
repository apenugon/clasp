# Legacy JS Backend Runtime

This directory holds the deprecated JavaScript backend server and worker shims.

- Active native runtime sources now live in `runtime/`.
- Compiler-packaged JS helper assets now live in `src/runtime/`.
- The goal is to remove these backend JS shims once the native backend owns the full server and worker surface.
