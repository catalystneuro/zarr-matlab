# Contributing

See [CONTRIBUTING.md](https://github.com/catalystneuro/zarr-matlab/blob/main/CONTRIBUTING.md)
in the repository for the development setup, test workflow, and design
ground rules. The short version:

- Every change keeps `run tools/run_tests.m` green, including the
  bidirectional zarr-python interop tests.
- New dtypes/codecs/features come with interop cases in
  `tools/interop_cases.py` + `tools/interop_matlab.m` proving both
  directions.
- Documentation examples are executed by `tests/TestDocs.m` — every
  ```` ```matlab ```` block in these pages must run cleanly (blocks that
  should not run use ```` ```text ```` or ```` ```python ```` fences).
- No Python at runtime; R2023a compatibility is enforced by CI.
