"""Step 1: zarr-python writes a store for MATLAB to read.

Usage: python tools/interop_write.py <store_dir>
"""
import sys

import numpy as np
import zarr

from interop_cases import CASES, RESERVED_ATTRS, build_codec_kwargs, pattern


def main(root):
    store = zarr.storage.LocalStore(root)
    group = zarr.create_group(store, attributes={"title": "interop", "answer": 42})
    sub = group.create_group("sub", attributes={"depth": 1, **RESERVED_ATTRS})

    for name, dtype, shape, chunks, spec in CASES:
        kwargs = build_codec_kwargs(spec)
        arr = group.create_array(
            name, shape=shape, dtype=dtype,
            chunks=chunks if len(shape) else "auto",
            **kwargs,
        )
        data = pattern(shape, dtype)
        if "partial" in spec:
            region = tuple(slice(0, p) for p in spec["partial"])
            arr[region] = data[region]
        elif len(shape):
            arr[...] = data
        else:
            arr[()] = data[()]

    named = sub.create_array(
        "named", shape=(4, 6), dtype="float64", chunks=(2, 3), compressors=(),
        dimension_names=["y", "x"], attributes={"units": "mm", "scale": 1.5},
    )
    named[...] = pattern((4, 6), "float64")
    print(f"wrote {len(CASES) + 1} arrays to {root}")


if __name__ == "__main__":
    main(sys.argv[1])
