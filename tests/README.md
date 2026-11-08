# Test suite

The test tree contains compiler fixtures and regression cases.

## Layout

- Root-level `*.kyn`: focused language/compiler fixtures used by configured test steps.
- `integration/`: numbered exit-code fixtures; filenames and expected exit codes are intentionally paired.
- `e2e/positive/`: accepted programs expected to compile and execute; most
  return normally, while deliberate division trap cases expect Linux SIGFPE
  (shell exit code 136, not a Kyn language guarantee).
- `e2e/negative/`: programs expected to fail compilation.
- `e2e/modules/`: multi-file import scenarios.
- `e2e/modules_negative/`: invalid module graphs and expected diagnostics.
- `diagnostics/`: focused diagnostic inputs.
- `fuzz/`: edge cases and fuzzing prototypes.

## Running tests

Run from the repository root:

```sh
zig build test
zig build e2e
zig build validate-ir
```

The build graph in `build.zig` and scripts in `tools/` define authoritative test discovery and execution. Do not rename or move fixtures without updating those consumers.
