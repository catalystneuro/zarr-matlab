# Data types

zarr-matlab supports every Zarr v3 core data type plus the numpy extension
types written by zarr-python.

| Zarr data type | MATLAB type | Notes |
|---|---|---|
| `bool` | `logical` | |
| `int8` … `int64`, `uint8` … `uint64` | same-named integer | |
| `float32` / `float64` | `single` / `double` | |
| `float16` | `single` | converted losslessly on read; rounds to-nearest-even on write |
| `complex64` / `complex128` | `single` / `double` complex | |
| `string` | `string` array | variable-length UTF-8 (`vlen-utf8` codec) |
| `variable_length_bytes` | cell of `uint8` row vectors | `vlen-bytes` codec; create with `"bytes"` |
| `numpy.datetime64` / `numpy.timedelta64` | `int64` ticks | see below |
| `struct` (legacy name `structured`) | struct array | records of named fixed-size fields; see below |
| `fixed_length_utf32` | `string` array | fixed-size UTF-32 text, mostly as a `struct` field |

`zarr.create` accepts either MATLAB class names (`"double"`, `"logical"`) or
Zarr names (`"float64"`, `"bool"`).

```matlab
store = zarr.stores.MemoryStore();

zc = zarr.create(store, 4, "complex128", Path="c");
zc(:) = [1+2i; 3-4i; complex(NaN, Inf); 0];
v = zc(:);
assert(v(2) == 3-4i && isnan(real(v(3))))

zh = zarr.create(store, 3, "float16", Path="h");
zh(:) = single([1.5; -2; 0.099976]);
assert(isa(zh(:), 'single'))
```

## Strings

`string` arrays map to the Zarr `string` dtype with the `vlen-utf8` codec —
fully compatible with zarr-python string arrays, including empty strings and
non-ASCII text. Compression codecs stack on top as usual.

```matlab
labels = zarr.create(store, [2 2], "string", Path="labels", ...
    ChunkShape=[2 2], Codecs={zarr.codecs.GzipCodec(5)}, FillValue="?");
labels(1, :) = ["alpha" "beta"];
out = labels(:, :);
assert(out(1, 2) == "beta" && out(2, 1) == "?")
```

Raw byte strings use the `"bytes"` dtype and cell arrays of `uint8`:

```matlab
raw = zarr.create(store, 3, "bytes", Path="raw");
raw(:) = {uint8([1 2 3]); uint8.empty(1, 0); uint8(255)};
out = raw(:);
assert(isequal(out{1}, uint8([1 2 3])) && isempty(out{2}))
```

## Structured records

The `struct` data type stores records of named, fixed-size fields, which
HDF5 and NWB call a compound type. MATLAB holds such an array as a struct
array with one field per record field. The data type is defined by its list
of fields, so `zarr.create` takes it as a struct with `name` and
`configuration`, in the same shape it has in `zarr.json`. A text field is
`fixed_length_utf32`, which spends four bytes per character.

```matlab
labelType = struct('name', "fixed_length_utf32", ...
    'configuration', struct('length_bytes', 32));        % up to 8 characters
fields = struct('name', {'id'; 'label'}, 'data_type', {'int32'; labelType});
recordType = struct('name', "struct", 'configuration', struct('fields', fields));

records = zarr.create(store, 3, recordType, Path="records");
records.write(struct('id', {int32(1); int32(2)}, 'label', {"alpha"; "beta"}), 1);
out = records.read();
assert(out(2).label == "beta")
assert(out(3).id == 0 && out(3).label == "")              % default fill record
```

A `FillValue` for a structured array is a scalar struct with every field.
Arrays that zarr-python wrote before version 3.3 use the legacy name
`structured`; zarr-matlab reads them and writes them back under that name.

## Datetimes: exact by design

zarr-python (and pandas/xarray) commonly write `numpy.datetime64[ns]`.
MATLAB's `datetime` stores milliseconds as a double, which cannot represent
nanosecond timestamps exactly — a silent-corruption trap. zarr-matlab
therefore exposes these types as **exact int64 ticks**, with the unit
available in the metadata:

```matlab
t = zarr.create(store, 4, "datetime64[ns]", Path="t");   % fill = NaT (intmin)
t(1) = int64(0);                                         % ns since epoch
t(2) = int64(1700000000123456789);                       % exact (scalar literal)
t(3) = int64(-1);
v = t(:);
assert(v(2) == int64(1700000000123456789))               % exact
assert(v(4) == intmin('int64'))                          % NaT
disp(t.meta.dataTypeConfig.unit)                         % "ns"
```

Convert to MATLAB `datetime` when (sub-microsecond) precision loss is
acceptable:

```matlab
dt = datetime(1970, 1, 1) + seconds(double(v(2)) * 1e-9);
assert(year(dt) == 2023)
```

`timedelta64` works identically (`"timedelta64[ms]"` etc.); NaT is
`intmin('int64')` in both.
