# Quickstart

This walkthrough creates a store, writes and reads data, builds a hierarchy,
and shows the headline features. Every block runs as-is (the test suite
executes this page in a temporary directory).

## Create an array

A local store is just a directory; each chunk is one file inside it.

```matlab
z = zarr.create("quickstart.zarr", [720 1440], "single", ...
    Path="temperature", ...
    ChunkShape=[180 360], ...
    Codecs={zarr.codecs.ZstdCodec(3)}, ...
    FillValue=single(NaN), ...
    DimensionNames=["lat" "lon"], ...
    Attributes=struct(units="degC"));
disp(z)
```

## Write and read with ordinary indexing

`zarr.Array` supports MATLAB paren indexing — slices, `end`, `:`, logical and
fancy indices. Reads fetch only the chunks that intersect the request; writes
that partially cover a chunk do a read-modify-write automatically.

```matlab
z(:, :) = single(20 + 5 * randn(720, 1440));
z(1, 1) = single(-40);              % single element
block = z(1:10, end-9:end);         % corner block
column = z(:, 100);                 % one column
assert(isequal(size(block), [10 10]))
assert(z(1, 1) == single(-40))
```

Explicit methods do the same thing, `h5read`-style:

```matlab
data = z.read([1 1], [10 10]);      % start, count (1-based)
z.write(single(zeros(10, 10)), [1 1]);
```

## Reopen and inspect

```matlab
z2 = zarr.open("quickstart.zarr", Path="temperature");
disp(z2.shape)            % [720 1440]
disp(z2.dtype)            % "float32"
disp(z2.attrs{"units"})
disp(z2.dimensionNames)   % ["lat" "lon"]
```

## Groups and hierarchy

```matlab
g = zarr.open("quickstart.zarr");          % root group (created implicitly)
run1 = g.createGroup("run1");
spikes = run1.createArray("spikes", [1e5 1], "int16", ChunkShape=[16384 1]);
spikes(1:5, 1) = int16([3 1 4 1 5]');

[arrayNames, groupNames] = g.children();
assert(ismember("run1", groupNames))
tree(g)                                    % print the hierarchy
```

## Sharding

With `ShardShape`, each stored object holds a grid of independently
compressed inner chunks, and reads fetch only the byte ranges they need —
small chunks without millions of small files. See [Sharding](user-guide/sharding.md).

```matlab
zs = zarr.create("quickstart.zarr", [4096 4096], "uint16", ...
    Path="image", ChunkShape=[256 256], ShardShape=[2048 2048], ...
    Codecs={zarr.codecs.BloscCodec(cname="zstd", shuffle="bitshuffle")});
m = uint16(magic(256));
zs(1:256, 1:256) = m;
tile = zs(1:100, 1:100);
assert(isequal(tile, m(1:100, 1:100)))
```

## Growing arrays

```matlab
spikes.append(int16(ones(100, 1)), 1);     % append along dimension 1
assert(isequal(spikes.shape, [1e5 + 100, 1]))
spikes.resize([2e5 1]);                    % explicit resize (fill-extends)
```

## Consolidated metadata

One `zarr.json` read instead of one per node — essential on remote storage:

```matlab
zarr.consolidate_metadata("quickstart.zarr");
gc = zarr.open("quickstart.zarr");         % children lookups now serve from memory
[an, gn] = gc.children();
assert(ismember("temperature", an))
```

## Next steps

- [Arrays](user-guide/arrays.md) — creation options, indexing, fill values
- [Data types](user-guide/data-types.md) — the full dtype ↔ MATLAB mapping
- [Compression](user-guide/compression.md) — codec chains and performance
- [Using with Python](user-guide/python-interop.md) — conventions for
  round-tripping with zarr-python
