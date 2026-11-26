# Contributing to zarr-matlab

Thanks for helping! The short version: every change should keep the full test
suite green, including the zarr-python interoperability tests.

## Development setup

1. Clone and add the repo root to your MATLAB path.
2. Python side (for interop tests):
   ```bash
   python3 -m venv .venv && .venv/bin/pip install "zarr>=3.4" numpy
   ```
3. MEX codecs (zstd/blosc/fast crc32c) — optional but recommended:
   ```matlab
   run tools/build_mex.m   % needs a C compiler and libzstd / libblosc
   ```
   Set `ZARR_MATLAB_LIBS` to a prefix containing `include/` and `lib/` if your
   libraries are somewhere unusual.

## Running tests

```matlab
run tools/run_tests.m
```

This runs `tests/` with `matlab.unittest`, including `TestPythonInterop`,
which drives a three-step round trip (zarr-python writes → MATLAB verifies &
writes → zarr-python verifies). It uses `.venv/bin/python` or
`$ZARR_MATLAB_PYTHON`, and skips cleanly if neither has zarr ≥ 3.4.

## Design ground rules

- **Spec first**: all chunk/slice math is 0-based C-order internally
  (`+zarr/+internal/chunk_intersections.m`), converted at the public API
  boundary. Read the relevant section of the
  [Zarr v3 spec](https://zarr-specs.readthedocs.io/) before changing codecs
  or metadata handling.
- **Interop is the contract**: new dtypes/codecs/features need cases in
  `tools/interop_cases.py` + `tools/interop_matlab.m` proving both directions.
- **No Python at runtime**: Python appears only in tests/CI.
- **Compatibility**: code must run on R2023a+ (CI enforces this).

## CI

- `ci.yml` — test matrix (Linux/Windows/macOS × latest, plus R2023a).
- `build-mex.yml` — builds relocatable MEX binaries on all platforms;
  attaches archives and the `.mltbx` to releases on `v*` tags.
- Caches: `ci.yml` caches the MATLAB install, the pip packages and the
  static compression libraries. GitHub removes a cache that has not been
  restored for 7 days, and a cache saved by a pull request run can be
  restored only by that pull request. When `gh cache list` shows no caches
  for `refs/heads/main`, run `gh workflow run ci.yml --ref main` before
  opening or pushing to pull requests. They then restore `main`'s caches
  instead of each saving its own copy, about 6 GB per run against the
  repository's 10 GB cache limit.
