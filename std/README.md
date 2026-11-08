# Standard library experiments

This directory contains experimental Kyn and Zig standard-library modules.

The current modules are prototypes, not a stable public API or a production-ready runtime. Some interfaces are placeholders and may not perform real operating-system work.

## Intended boundary

- `core/`: platform-independent primitives.
- `os/`: operating-system-specific interfaces.

Do not add an API as implemented until it has a defined contract, a real implementation, and positive and negative tests. The canonical status is in [docs/status.md](../docs/status.md).
