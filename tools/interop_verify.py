"""Step 3: zarr-python verifies the MATLAB-written store.

Usage: python tools/interop_verify.py <store_dir>
"""
import math
import sys

import numpy as np
import zarr

from interop_cases import RESERVED_ATTRS, CASES, pattern


def main(root):
    store = zarr.storage.LocalStore(root)
    group = zarr.open_group(store, mode="r")
    assert group.attrs["title"] == "interop", group.attrs.asdict()
    assert group.attrs["answer"] == 42
    assert group["sub"].attrs["depth"] == 1

    checked = 0
    for name, dtype, shape, chunks, spec in CASES:
        arr = group[name]
        assert arr.shape == shape, (name, arr.shape, shape)
        if dtype not in ("string", "bytes"):
            assert arr.dtype == np.dtype(dtype), (name, arr.dtype)
        expected = pattern(shape, dtype)
        if "partial" in spec:
            fill = spec.get("fill_value")
            if fill is None:
                if dtype.startswith(("datetime64", "timedelta64")):
                    fill = np.array("NaT", dtype=dtype)[()]
                else:
                    fill = 0
            full = np.full(shape, fill, dtype=dtype)
            region = tuple(slice(0, p) for p in spec["partial"])
            full[region] = expected[region]
            expected = full
        actual = arr[...] if len(shape) else arr[()]
        np.testing.assert_array_equal(actual, expected, err_msg=name)
        if "fill_value" in spec and isinstance(spec["fill_value"], float) \
                and math.isnan(spec["fill_value"]):
            assert math.isnan(arr.fill_value), name
        checked += 1

    named = group["sub"]["named"]
    np.testing.assert_array_equal(named[...], pattern((4, 6), "float64"))
    assert named.metadata.dimension_names == ("y", "x"), named.metadata.dimension_names
    assert named.attrs["units"] == "mm" and named.attrs["scale"] == 1.5

    # The hdmf-zarr reserved names must come back exactly as they went out.
    sub_attrs = dict(group["sub"].attrs)
    for key, expected in RESERVED_ATTRS.items():
        assert sub_attrs[key] == expected, f"{key}: {sub_attrs.get(key)!r} != {expected!r}"

    print(f"python verified {checked + 1} MATLAB-written arrays")


if __name__ == "__main__":
    main(sys.argv[1])
