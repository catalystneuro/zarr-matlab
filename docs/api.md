# API reference

## Top-level functions

### `zarr.open`

```text
node = zarr.open(store)
node = zarr.open(store, Path="group/array")
```

Open an existing array or group; returns `zarr.Array` or `zarr.Group`.
`store` is a directory path or a store object. Errors with
`zarr:NodeNotFound` if no `zarr.json` exists at the path.

### `zarr.create`

```text
z = zarr.create(store, shape, dtype, Name=Value...)
```

Create an array (see [Arrays](user-guide/arrays.md) for the full option
table). `shape` is the Zarr shape: `[m n ...]`, a scalar `n` (rank-1), or
`[]` (rank-0). `dtype` accepts MATLAB class names, Zarr names, `"string"`,
`"bytes"`, or `"datetime64[<unit>]"` / `"timedelta64[<unit>]"`.

Options: `Path`, `ChunkShape`, `ShardShape`, `IndexLocation`, `Codecs`,
`FillValue`, `Attributes`, `DimensionNames`, `Order`, `ChunkKeyEncoding`,
`WriteEmptyChunks`, `Overwrite`.

### `zarr.create_group`

```text
g = zarr.create_group(store, Path="a/b", Attributes=struct(...))
```

Create a group (and any missing parents). Idempotent for existing groups.

### `zarr.consolidate_metadata`

```text
zarr.consolidate_metadata(store)
```

Inline all node metadata into the root group's `zarr.json`
(zarr-python-compatible). Re-run after changing the hierarchy.

### `zarr.delete_node`

```text
zarr.delete_node(store, path)
```

Recursively remove an array or group and all data beneath it.

---

## `zarr.Array`

Handle class returned by `zarr.open`/`zarr.create`.

**Properties (read-only):** `store`, `path`, `meta`, `shape` (Zarr shape),
`dtype` (Zarr name), `chunkShape`, `attrs` (cell-valued `dictionary`;
look up with `attrs{"name"}`), `dimensionNames`.
**Settable:** `writeEmptyChunks` (default `false`).

**Indexing:** full MATLAB paren indexing — slices, `end`, `:`, numeric and
logical fancy indexing, scalar expansion on assignment. `z(:)` reads the
whole array as a column.

**Methods:**

| Method | Description |
|---|---|
| `read(start, count)` | region read, 1-based; `count` may contain `Inf`; both optional |
| `write(data, start)` | region write; `start` optional (defaults to origin) |
| `resize(newShape)` | change shape; shrinking deletes out-of-bounds chunks |
| `append(data, dim)` | grow along `dim` and write `data` at the end |
| `setAttr(name, value)` / `setAttrs(s)` | update / replace attributes; `name` is written exactly, `s` is a dictionary or scalar struct |
| `size / ndims / numel / disp` | standard MATLAB semantics |

## `zarr.Group`

**Properties:** `store`, `path`, `meta`, `attrs`.

| Method | Description |
|---|---|
| `item(name)` | open a child (accepts nested paths, e.g. `"a/b"`) |
| `isKey(name)` | does a child node exist |
| `children()` | `[arrayNames, groupNames]`, both string columns |
| `createArray(name, shape, dtype, ...)` | like `zarr.create` under this group |
| `createGroup(name, ...)` | create a child group |
| `setAttr / setAttrs` | attribute updates; `name` is written exactly, `setAttrs` takes a dictionary or scalar struct |
| `tree(maxDepth)` | print the hierarchy |

Both `item` and `children` are served from consolidated metadata when
present (no store reads).

---

## Stores (`zarr.stores.*`)

| Class | Constructor | Notes |
|---|---|---|
| `LocalStore` | `LocalStore(root)` | directory; atomic writes, ranged reads |
| `MemoryStore` | `MemoryStore()` | in-memory |
| `ZipStore` | `ZipStore(path, Mode="r"/"w")` | one-file store; `"w"` finalizes on `close()` |
| `HttpStore` | `HttpStore(baseUrl)` | read-only; Range requests for partial reads |

Custom backends subclass `zarr.stores.Store`: implement
`get`, `set`, `erase`, `exists`, `list`, `listDir`; optionally override
`getPartial(key, offset, len)` and `getSuffix(key, len)` for ranged reads.

## Codecs (`zarr.codecs.*`)

| Class | Constructor |
|---|---|
| `ZstdCodec` | `ZstdCodec(level, checksum)` — level −131072…22 (default 0), checksum logical |
| `BloscCodec` | `BloscCodec(cname="zstd", clevel=5, shuffle="shuffle", typesize=0, blocksize=0)` |
| `GzipCodec` | `GzipCodec(level)` — 0…9, default 5 |
| `Crc32cCodec` | `Crc32cCodec()` |
| `TransposeCodec` | `TransposeCodec(order)` — 0-based permutation |
| `BytesCodec` | `BytesCodec(endian)` — `"little"` (default) / `"big"` |
| `ShardingCodec` | `ShardingCodec(innerChunkShape, Codecs={...}, IndexCodecs={...}, IndexLocation="end")` |
| `VlenUtf8Codec` / `VlenBytesCodec` | `VlenUtf8Codec()` / `VlenBytesCodec()` — inserted automatically for `string`/`bytes` dtypes |

## Error identifiers

All errors use the `zarr:` prefix; the ones worth catching:

`zarr:NodeNotFound`, `zarr:NodeExists`, `zarr:Indexing`,
`zarr:ShapeMismatch`, `zarr:UnsupportedCodec`, `zarr:MissingMex`,
`zarr:ChecksumError`, `zarr:CodecError`, `zarr:InvalidMetadata`,
`zarr:StoreError`.
