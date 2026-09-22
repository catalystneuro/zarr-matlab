<div align="center">

<img src="docs/assets/logo.svg" width="110" alt="zarr-matlab logo: a chunked array whose stored chunks spell a Z"/>

# zarr-matlab

[![CI](https://github.com/catalystneuro/zarr-matlab/actions/workflows/ci.yml/badge.svg)](https://github.com/catalystneuro/zarr-matlab/actions/workflows/ci.yml)
[![Docs](https://github.com/catalystneuro/zarr-matlab/actions/workflows/docs.yml/badge.svg)](https://catalystneuro.github.io/zarr-matlab/)
[![GitHub release](https://img.shields.io/github/v/release/catalystneuro/zarr-matlab)](https://github.com/catalystneuro/zarr-matlab/releases)
[![codecov](https://codecov.io/gh/catalystneuro/zarr-matlab/graph/badge.svg?token=6mz3LceJhv)](https://codecov.io/gh/catalystneuro/zarr-matlab)

Read and write **Zarr v3** arrays natively in MATLAB — no Python required.

</div>

**📖 Documentation: [catalystneuro.github.io/zarr-matlab](https://catalystneuro.github.io/zarr-matlab/)** — every code example in the docs is executed by the test suite on every commit.

[Zarr](https://zarr.dev) is a chunked, compressed array storage format for
scientific data, designed for cloud storage and parallel I/O. This library
implements the [Zarr v3 specification](https://zarr-specs.readthedocs.io/en/latest/v3/core/index.html)
in pure MATLAB, with byte-level interoperability against
[zarr-python 3](https://zarr.readthedocs.io/) verified in the test suite: data
written by either implementation reads back identically in the other.

> **How this fits the MATLAB Zarr landscape:** MathWorks' official
> [Zarr support](https://github.com/mathworks/MATLAB-support-for-Zarr-files)
> covers Zarr **v2** only.
> [scalableminds/zarr-matlab](https://github.com/scalableminds/zarr-matlab)
> binds the [zarrs](https://zarrs.dev) Rust implementation — a thin, fast
> wrapper. **This library is a pure-MATLAB v3 implementation**: complete
> dtype coverage (incl. complex, float16, variable-length strings,
> datetime64), consolidated metadata, zip/HTTP stores, native MATLAB
> indexing, and an installer with prebuilt compression codecs — with
> byte-level zarr-python round trips verified in CI on every commit. See
> [PLAN.md](PLAN.md) for the roadmap.

## Installation

**Easiest:** download `zarr-matlab-<version>.mltbx` from the
[latest release](https://github.com/catalystneuro/zarr-matlab/releases/latest)
and double-click it (or `matlab.addons.install(...)`). It includes prebuilt
`zstd`/`blosc`/`crc32c` MEX codecs for Linux, Windows, and Apple Silicon.

**From source:** clone and add the repo root (the folder *containing* `+zarr`)
to your MATLAB path:

```matlab
addpath('/path/to/zarr-matlab')
run tools/build_mex.m   % MEX codecs: needs a C compiler + libzstd / libblosc
```

Requires MATLAB R2023a or newer with a JVM (used for gzip compression).
R2023a is the release that added brace indexing for `dictionary`, which
node attributes rely on.
Everything except the `zstd`/`blosc` codecs works without the MEX binaries;
opening data that needs them produces a clear error naming the missing codec.
Intel-Mac users must build the MEX locally (no CI runners exist for maci64).

## Quick start

```matlab
% Create a chunked, compressed array
z = zarr.create("weather.zarr", [720 1440], "single", ...
    Path="temp", ...
    ChunkShape=[180 360], ...
    Codecs={zarr.codecs.ZstdCodec(5)}, ...
    FillValue=single(NaN), ...
    DimensionNames=["lat" "lon"], ...
    Attributes=struct(units="degC"));

% Sharding: store many small chunks inside each object, read them individually
z = zarr.create("big.zarr", [100000 100000], "uint16", ...
    ChunkShape=[512 512], ShardShape=[8192 8192], ...
    Codecs={zarr.codecs.BloscCodec(cname="zstd", shuffle="bitshuffle")});

% Write and read with normal MATLAB indexing (1-based, end supported)
z(:, :) = single(randn(720, 1440));
block = z(1:100, end-99:end);

% Open an existing store (works on data written by zarr-python)
z = zarr.open("weather.zarr", Path="temp");
data = z.read();            % whole array
z.attrs                     % dictionary of attributes; z.attrs{"units"}
z.dimensionNames            % ["lat" "lon"]

% Groups and hierarchy
g = zarr.create_group("experiment.zarr", Attributes=struct(subject="M-042"));
a = g.createArray("spikes", [1e6 1], "int16", ChunkShape=[65536 1]);
sub = g.createGroup("processed");
[arrayNames, groupNames] = g.children();

% Grow arrays
z.append(newRows, 1);       % append along dimension 1
z.resize([1024 1440]);
```

### Stores

```matlab
zarr.stores.LocalStore("data.zarr")            % directory on disk (default for path strings)
zarr.stores.MemoryStore()                      % in-memory, useful for testing
zarr.stores.ZipStore("archive.zarr.zip")       % read a zipped store
zarr.stores.ZipStore("out.zarr.zip", Mode="w") % write one (finalized by close())
zarr.stores.HttpStore("https://host/data.zarr")% read-only over HTTP(S); Range
                                               % requests -> partial shard reads
```

Strings and consolidated metadata:

```matlab
z = zarr.create(store, [1000 1], "string", Path="labels");  % vlen-utf8, MATLAB string arrays
zarr.consolidate_metadata(store);   % single-read hierarchy opens (zarr-python compatible)
```

## Interop with Python: conventions

**Shapes are preserved, not flipped.** A zarr array with shape `(a, b, c)` in
Python has `size(z) == [a b c]` in MATLAB, and `arr[i, j, k]` in Python equals
`z(i+1, j+1, k+1)` — so `dimension_names` line up and no mental
transposition is needed (unlike MATLAB's `h5read`, which reverses dimensions).

| Zarr data type | MATLAB type |
|---|---|
| bool | logical |
| int8…int64, uint8…uint64 | same-named integer |
| float32 / float64 | single / double |
| float16 | single (converted losslessly on read; `"float16"` on create) |
| complex64 / complex128 | single / double complex |
| numpy.datetime64 / timedelta64 | int64 ticks (exact; unit in metadata — MATLAB `datetime` is double-backed and would lose ns precision). Create with `"datetime64[ns]"` etc. |

Rank mapping: rank-1 zarr arrays are MATLAB column vectors; rank-0 (scalar)
arrays are read with `z()`.

User attributes are exposed as a cell-valued `dictionary`, so a key is
whatever the file says -- including keys that are not valid MATLAB
identifiers, such as `_DTYPE` (hdmf-zarr's Zarr v3 convention), `chunk size`
or `2d-extent`. Look one up with braces: `z.attrs{"units"}`. Keys nested
inside an attribute *value* are exact too, and a JSON array always reads back
as a cell, so a one-element list stays a list; use `cell2mat` where a numeric
vector is wanted. A non-finite attribute is written as the bare token `NaN`,
`Infinity` or `-Infinity`, matching zarr-python; these are its extension to
JSON, so a strict parser will reject such a file while Python's `json` module
reads it. (A `fill_value` is separate and uses the quoted `"NaN"` the Zarr v3
spec requires.) Chunks are stored C-order per the spec; pass
`Order="F"` to `zarr.create` to store column-major chunks (adds a spec-standard
`transpose` codec — still fully readable by zarr-python — and makes MATLAB I/O
copy-free).

## Supported features

| Feature | Status |
|---|---|
| Zarr v3 arrays and groups, attributes, `dimension_names` | ✅ |
| All core data types (bool, ints, floats incl. float16, complex) | ✅ |
| Codecs: `bytes` (both endians), `transpose`, `gzip`, `crc32c` | ✅ |
| Fill values incl. NaN/±Inf, hex bit patterns, complex | ✅ |
| Region read/write, read-modify-write across chunk boundaries | ✅ |
| resize / append; chunk-key encodings `default` and `v2` (read) | ✅ |
| Stores: local filesystem, in-memory | ✅ |
| Codecs: `blosc` (all cnames/shuffles), `zstd` (MEX, `tools/build_mex.m`) | ✅ |
| `sharding_indexed`: partial shard reads, nested shards, both index locations | ✅ |
| Variable-length strings (`string`/`vlen-utf8`) and bytes (`vlen-bytes`) | ✅ |
| `numpy.datetime64` / `timedelta64` (as exact int64 ticks) | ✅ |
| Empty-chunk elision on write (zarr-python parity; `WriteEmptyChunks=true` to disable) | ✅ |
| Node deletion (`zarr.delete_node`), v2 chunk-key encoding read + write | ✅ |
| ZipStore (read + write), consolidated metadata (read + write) | ✅ |
| HTTP(S) read-only store with ranged partial reads | ✅ |
| Prebuilt MEX binaries (Linux/Windows/Apple Silicon, attached to releases) | ✅ |
| S3 store | 🚧 planned |
| Zarr v2 format | ❌ out of scope |

## Testing

```bash
matlab -batch "cd zarr-matlab; run tools/run_tests.m"
```

runs the full `matlab.unittest` suite in `tests/`, including a bidirectional
interop test that has zarr-python write a store covering every dtype × codec ×
sharding combination for MATLAB to verify, then verifies MATLAB's mirror
output with zarr-python. The interop test looks for python in `.venv/bin/python`
(create with `python3 -m venv .venv && .venv/bin/pip install "zarr>=3"`) or
`$ZARR_MATLAB_PYTHON`, and skips cleanly when unavailable.

## Citation

If you use zarr-matlab in your research, please cite it (see
[`CITATION.cff`](CITATION.cff), or use GitHub's "Cite this repository"
button):

> Dichter, B. (2026). *zarr-matlab: Zarr v3 for MATLAB* (Version 0.3.1)
> [Computer software]. https://github.com/catalystneuro/zarr-matlab

## Contributing / roadmap

Development follows the milestones in [PLAN.md](PLAN.md). Issues and PRs
welcome — especially interop reports with stores produced by other Zarr
implementations.
