# Arrays

## Creating arrays

`zarr.create(store, shape, dtype, ...)` creates an array and returns a
`zarr.Array` handle. The store is a directory path or a
[store object](storage.md); `shape` is the Zarr shape (a scalar `n` makes a
rank-1 array of length `n`, `[]` makes a rank-0 scalar array).

```matlab
store = zarr.stores.MemoryStore();

z = zarr.create(store, [1000 2000], "double", ...
    Path="data", ...                              % node path within the store
    ChunkShape=[100 200], ...                     % default: one chunk = whole array
    Codecs={zarr.codecs.ZstdCodec(3)}, ...        % default: uncompressed
    FillValue=NaN, ...                            % default: 0 / false / "" / NaT
    DimensionNames=["y" "x"], ...
    Attributes=struct(description="example"));
```

All options:

| Option | Default | Meaning |
|---|---|---|
| `Path` | `""` (root) | node path; missing parent groups are created |
| `ChunkShape` | whole array | chunk grid |
| `ShardShape` | none | enables [sharding](sharding.md); must be a multiple of `ChunkShape` |
| `IndexLocation` | `"end"` | shard index placement (`"start"`/`"end"`) |
| `Codecs` | `{}` | codec chain; a `bytes` serializer is inserted automatically |
| `FillValue` | type-dependent zero | value of unwritten regions |
| `Attributes` | `struct()` | user attributes |
| `DimensionNames` | none | per-dimension names (use `missing` for null) |
| `Order` | `"C"` | `"F"` stores column-major chunks via a transpose codec |
| `ChunkKeyEncoding` | `"default"` | `"v2"` writes `0.0`-style chunk keys |
| `WriteEmptyChunks` | `false` | `true` stores chunks even when entirely fill value |
| `Overwrite` | `false` | replace an existing node |

## Indexing

`zarr.Array` supports MATLAB paren indexing. Reads touch only the chunks
intersecting the request; partial-chunk writes read-modify-write.

```matlab
d = reshape(1:24, [4 6]);
z2 = zarr.create(store, [4 6], "double", Path="idx", ChunkShape=[2 3]);
z2(:, :) = d;

z2(2:3, 4:6);            % contiguous slice
z2(end, end);            % end arithmetic
z2([1 4], [2 5]);        % fancy (non-contiguous) indices
z2(logical([1 0 1 0]), :);  % logical indexing
z2(:);                   % entire array as a column vector

z2(1:2, 1:3) = 0;        % assignment, scalar expansion works too:
z2(3, :) = 7;
assert(isequal(z2(3, 1), 7))
```

Out-of-bounds assignment is an error (Zarr arrays do not auto-grow like
MATLAB matrices — use `resize`/`append`):

```matlab
try
    z2(5, 1) = 1;
    error("unreachable");
catch err
    assert(err.identifier == "zarr:Indexing")
end
```

### Explicit region I/O

`read`/`write` mirror the `h5read` style and also support rank-0 arrays:

```matlab
block = z2.read([2 4], [2 3]);     % start, count (count Inf = "to end")
z2.write(zeros(2, 3), [2 4]);

s = zarr.create(store, [], "double", Path="scalar");  % rank-0
s.write(pi);
assert(s() == pi)
```

## Fill values and unwritten regions

Reading a region whose chunks were never written returns the fill value.
By default (matching zarr-python), chunks that are *entirely* fill value are
not stored at all, and overwriting a chunk with all-fill data deletes it:

```matlab
zf = zarr.create(store, [4 4], "double", Path="fills", ...
    ChunkShape=[2 2], FillValue=NaN);
zf(1:2, 1:2) = magic(2);
out = zf(:, :);
assert(all(isnan(out(3:4, :)), 'all'))     % unwritten -> fill
```

Set `WriteEmptyChunks=true` to store them anyway. Fill values support the
full spec: `NaN`, `±Inf`, `-0.0`, complex values, exact 64-bit integers, and
hex bit patterns are all round-tripped exactly.

## Resizing and appending

```matlab
za = zarr.create(store, [2 3], "double", Path="grow", ChunkShape=[2 2]);
za(:, :) = ones(2, 3);
za.append(2 * ones(2, 2), 2);      % grow along dim 2 and write
assert(isequal(za.shape, [2 5]))
za.resize([2 3]);                  % shrinking deletes out-of-bounds chunks
assert(isequal(za(:, :), ones(2, 3)))
```

## Attributes

Attributes live in the array's `zarr.json` and are exposed as a struct:

```matlab
za.setAttr('units', 'mV');
za.setAttr('history', {"created", "cleaned"});
assert(za.attrs{"units"} == "mV")
za.setAttrs(struct('units', 'uV'));   % replace all attributes
```

!!! warning
    Attribute *keys* must be valid MATLAB identifiers to survive the struct
    representation; other keys are normalized on read.
