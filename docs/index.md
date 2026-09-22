# zarr-matlab

Read and write **Zarr v3** arrays natively in MATLAB — no Python required.

[Zarr](https://zarr.dev) is a chunked, compressed array storage format for
scientific data, designed for cloud storage and parallel I/O. zarr-matlab is
a pure-MATLAB implementation of the
[Zarr v3 specification](https://zarr-specs.readthedocs.io/en/latest/v3/core/index.html)
with byte-level interoperability against
[zarr-python](https://zarr.readthedocs.io/): data written by either
implementation reads back identically in the other, verified by CI on every
commit.

```matlab
z = zarr.create("weather.zarr", [720 1440], "single", ...
    Path="temp", ChunkShape=[180 360], ...
    Codecs={zarr.codecs.ZstdCodec(5)}, FillValue=single(NaN));

z(:, :) = single(20 + 5 * randn(720, 1440));   % write with normal indexing
block = z(1:100, end-99:end);                  % reads only the chunks it needs
```

## Installation

**Toolbox (recommended):** download `zarr-matlab-<version>.mltbx` from the
[latest release](https://github.com/catalystneuro/zarr-matlab/releases/latest)
and double-click it. Prebuilt `zstd`/`blosc`/`crc32c` codecs for Linux,
Windows, and Apple Silicon are included.

**From source:** clone the repo and add its root (the folder *containing*
`+zarr`) to your MATLAB path. Build the compression codecs once with
`run tools/build_mex.m` (needs a C compiler plus libzstd/libblosc).

Requires MATLAB **R2023a or newer** with a JVM (used for gzip).

## Feature highlights

- **Arrays and groups** with attributes and `dimension_names`, accessed with
  ordinary MATLAB indexing
- **Every Zarr v3 data type**: integers, floats (incl. float16), complex,
  variable-length strings and bytes, datetime64/timedelta64
- **Codecs**: zstd, blosc (lz4/zstd/… with shuffle/bitshuffle), gzip,
  crc32c checksums, transpose
- **Sharding**: many small chunks per stored object, with efficient ranged
  partial reads
- **Stores**: local directories, in-memory, zip archives, read-only HTTP(S)
- **Consolidated metadata** for single-read hierarchy opens on remote storage

## How this fits the MATLAB Zarr landscape

MathWorks' official
[Zarr support](https://github.com/mathworks/MATLAB-support-for-Zarr-files)
covers format **v2** only.
[scalableminds/zarr-matlab](https://github.com/scalableminds/zarr-matlab)
binds the [zarrs](https://zarrs.dev) Rust implementation. This library is a
pure-MATLAB **v3** implementation with complete dtype coverage and
CI-verified zarr-python round trips.

!!! note "Documentation is tested"
    Every MATLAB code block in these pages is executed by the test suite
    (`tests/TestDocs.m`) on every commit — examples cannot silently rot.
