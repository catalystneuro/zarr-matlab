# Stores and storage

A store is a flat key/value namespace with byte-range reads — everything else
(arrays, groups, chunks) is keys and bytes on top of it. Anywhere the API
takes a store you can pass a directory path (making a `LocalStore`) or a
store object.

## LocalStore

A directory on disk; each chunk/metadata document is a file. Writes are
atomic (temp file + rename), so concurrent readers never see partial chunks.

```matlab
root = "storage_demo.zarr";
z = zarr.create(root, [10 10], "double", Path="x", ChunkShape=[5 5]);
z(:, :) = magic(10);
z2 = zarr.open(root, Path="x");
assert(isequal(z2(:, :), magic(10)))
```

## MemoryStore

In-memory, ideal for tests and scratch work:

```matlab
mem = zarr.stores.MemoryStore();
zm = zarr.create(mem, 5, "int32");
zm(:) = int32((1:5)');
assert(isequal(zm(2:3), int32([2; 3])))
```

## ZipStore

A whole hierarchy inside one `.zip` file, compatible with zarr-python's
`ZipStore`. Write mode accumulates entries in memory and writes the file on
`close()` (zip entries can't be rewritten in place):

```matlab
zw = zarr.stores.ZipStore("archive.zarr.zip", Mode="w");
zarr.create_group(zw, Attributes=struct(kind="archive"));
za = zarr.create(zw, [4 4], "double", Path="data");
za(:, :) = magic(4);
zw.close();

zr = zarr.stores.ZipStore("archive.zarr.zip");    % read-only
g = zarr.open(zr);
assert(isequal(g.item("data").read(), magic(4)))
zr.close();
```

## HTTP(S) {#http}

`HttpStore` reads Zarr data from any web server, object-store HTTP endpoint,
or CDN. When the server honors `Range` requests (S3, nginx, …), sharded
arrays and arrays with uncompressed chunks fetch only the byte ranges they
need. A read that spans several chunks fetches them concurrently, whether
whole or as byte ranges.

```text
store = zarr.stores.HttpStore("https://example.com/data.zarr");
z = zarr.open(store, Path="temperature");   % direct opens always work
tile = z(1:512, 1:512);
```

HTTP servers cannot list keys, so browsing the hierarchy (`children`, `tree`)
requires consolidated metadata (below) — direct opens by `Path` always work.
Public S3 buckets work today via their HTTPS endpoints
(`https://<bucket>.s3.<region>.amazonaws.com/...`).

## Consolidated metadata

Opening a deep hierarchy normally costs one read per `zarr.json`. Fatal over
HTTP. `zarr.consolidate_metadata` inlines every node's metadata into the root
group's `zarr.json` (the same format zarr-python writes and reads), after
which hierarchy operations are served from memory:

```matlab
zarr.create(root, 3, "int8", Path="deep/nested/y");
zarr.consolidate_metadata(root);
gc = zarr.open(root);
node = gc.item("deep").item("nested").item("y");   % zero store reads
assert(isequal(node.shape, 3))
```

Consolidation is a snapshot — re-run it after adding or removing nodes.

## Deleting nodes

```matlab
zarr.delete_node(root, "deep");                    % recursive
assert(~gc.store.exists("deep/nested/y/zarr.json"))
```

## Custom stores

Subclass `zarr.stores.Store` and implement `get`, `set`, `erase`, `exists`,
`list`, and `listDir`; override `getPartial`/`getSuffix` with true ranged
reads if the backend supports them (that is what makes partial reads of
shards and uncompressed chunks efficient). Override `getMany` and
`getPartialMany` if the backend can serve several reads at once. See
`+zarr/+stores/HttpStore.m` for a compact example.
