"""Shared case definitions + deterministic data patterns for interop checks.

The same patterns are implemented in MATLAB (tools/interop_pattern.m); both
sides generate expected values independently, so no sidecar files are needed.
"""
import numpy as np

# Reserved attribute names of the hdmf-zarr Zarr v3 storage convention. Every
# one begins with an underscore, which is not a valid MATLAB identifier, so
# these only survive a MATLAB round trip because attributes are carried as a
# dictionary rather than a struct.
RESERVED_ATTRS = {
    "_DTYPE": "object_reference",
    "_REFERENCE_FIELDS": ["electrode"],
    "_LINKS": [{"name": "device", "source": ".", "path": "/general/devices/probe"}],
    "_REF_ATTR": {"_REFERENCE": {"path": "/general/electrodes", "source": "."}},
}

CASES = [
    # name, dtype, shape, chunks, codec spec
    ("f64_gzip", "float64", (10, 13), (4, 5), {"compressors": ["gzip5"]}),
    ("i32_crc", "int32", (5, 4, 3), (2, 2, 2), {"compressors": ["gzip1", "crc32c"]}),
    ("f32_be", "float32", (8,), (3,), {"serializer": "bytes_be"}),
    ("f64_transpose", "float64", (6, 8), (3, 4), {"filters": ["transpose10"]}),
    ("f16", "float16", (11,), (4,), {"compressors": ["gzip5"]}),
    ("c128", "complex128", (4, 5), (2, 3), {"compressors": ["gzip5"]}),
    ("c64", "complex64", (6,), (4,), {}),
    ("bool", "bool", (7, 3), (4, 2), {}),
    ("u64", "uint64", (6,), (4,), {"fill_value": 2**60, "partial": (3,)}),
    ("i64", "int64", (5,), (2,), {}),
    ("u8", "uint8", (9, 2), (4, 2), {}),
    ("i8", "int8", (9,), (5,), {}),
    ("u16", "uint16", (7,), (3,), {}),
    ("i16", "int16", (7,), (3,), {}),
    ("u32", "uint32", (7,), (3,), {}),
    ("f32", "float32", (3, 4, 2, 2), (2, 2, 2, 2), {"compressors": ["gzip5"]}),
    ("nanfill", "float64", (6, 6), (3, 3), {"fill_value": float("nan"), "partial": (3, 3)}),
    ("scalar", "float64", (), (), {}),
    ("v2keys", "float64", (5, 5), (2, 2), {"chunk_key_encoding": "v2"}),
    # sharded cases: chunks = inner chunk shape, spec["shards"] = shard shape
    ("shard2d", "float64", (12, 10), (3, 5),
     {"shards": (6, 10), "compressors": ["gzip5"]}),
    ("shard_start", "int32", (8, 8), (2, 2),
     {"shards": {"shape": (4, 8), "index_location": "start"}}),
    ("shard_fill", "float64", (8, 8), (2, 2),
     {"shards": (4, 4), "fill_value": float("nan"), "partial": (2, 2)}),
    ("shard3d", "int16", (6, 4, 4), (3, 2, 2),
     {"shards": (6, 4, 4), "compressors": ["gzip1", "crc32c"]}),
    # native codec cases (MEX-backed in MATLAB)
    ("zstd_default", "float64", (10, 8), (4, 3), {"compressors": ["zstd"]}),
    ("zstd_hi_ck", "int32", (20,), (7,), {"compressors": ["zstd19ck"]}),
    ("blosc_lz4_shuf", "float32", (9, 7), (4, 4), {"compressors": ["blosc_lz4_shuf"]}),
    ("blosc_zstd_bit", "int16", (12,), (5,), {"compressors": ["blosc_zstd_bit"]}),
    ("blosc_blosclz_noshuf", "uint8", (6, 6), (3, 3), {"compressors": ["blosc_blosclz_noshuf"]}),
    ("shard_zstd", "float64", (8, 8), (2, 4), {"shards": (4, 8), "compressors": ["zstd"]}),
    ("defaults", "float64", (7, 5), (3, 3), {"default_compressors": True}),
    # variable-length dtypes
    ("str2d", "string", (5, 4), (2, 3), {"compressors": ["gzip5"]}),
    ("str_shard", "string", (6,), (2,), {"shards": (6,)}),
    ("vbytes", "bytes", (7,), (3,), {}),
    # numpy extension dtypes (int64 ticks; NaT fill)
    ("dt_ns", "datetime64[ns]", (6,), (3,), {}),
    ("td_ms", "timedelta64[ms]", (5,), (2,), {"compressors": ["gzip5"]}),
    ("dt_fill", "datetime64[s]", (4,), (2,), {"partial": (2,)}),
    # remaining codec-option combinations
    ("blosc_lz4hc_shuf", "float64", (8, 6), (3, 3),
     {"compressors": ["blosc_lz4hc_shuf"]}),
    ("blosc_zlib_shuf", "int32", (10,), (4,),
     {"compressors": ["blosc_zlib_shuf"]}),
    ("gzip9", "float32", (6, 6), (3, 3), {"compressors": ["gzip9"]}),
    ("shard_nested", "float64", (8, 8), (4, 4),
     {"shards": (8, 8), "nested_inner": (2, 2)}),
    # numcodecs extension codecs (zlib framing, byte shuffle)
    ("zlib5", "float64", (8, 6), (4, 3), {"compressors": ["zlib5"]}),
    ("shuffle_zlib", "int32", (10,), (4,), {"compressors": ["shuffle4", "zlib1"]}),
]


def pattern(shape, dtype):
    n = int(np.prod(shape)) if len(shape) else 1
    base = np.arange(n, dtype=np.float64) % 251
    if dtype == "string":
        return np.array([f"s{int(x)}" for x in base], dtype=object).reshape(shape)
    if dtype == "bytes":
        return np.array([bytes(range(int(x) % 5)) for x in base],
                        dtype=object).reshape(shape)
    if dtype.startswith(("datetime64", "timedelta64")):
        return base.astype(np.int64).astype(np.dtype(dtype)).reshape(shape)
    dt = np.dtype(dtype)
    if dt == np.bool_:
        v = (base % 2).astype(bool)
    elif dt.kind == "c":
        v = (base / 4 + 1j * (base / 4 + 0.5)).astype(dt)
    elif dt.kind == "f":
        v = (base / 4).astype(dt)
    else:
        v = base.astype(dt)
    return v.reshape(shape)


def build_codec_kwargs(spec):
    from zarr.codecs import (BloscCodec, BytesCodec, Crc32cCodec, GzipCodec,
                             ShardingCodec, TransposeCodec, ZstdCodec)
    kwargs = {}
    comp_map = {
        "gzip1": GzipCodec(level=1),
        "gzip5": GzipCodec(level=5),
        "gzip9": GzipCodec(level=9),
        "crc32c": Crc32cCodec(),
        "zstd": ZstdCodec(),
        "zstd19ck": ZstdCodec(level=19, checksum=True),
        "blosc_lz4_shuf": BloscCodec(cname="lz4", clevel=5, shuffle="shuffle"),
        "blosc_zstd_bit": BloscCodec(cname="zstd", clevel=3, shuffle="bitshuffle"),
        "blosc_blosclz_noshuf": BloscCodec(cname="blosclz", clevel=9, shuffle="noshuffle"),
        "blosc_lz4hc_shuf": BloscCodec(cname="lz4hc", clevel=5, shuffle="shuffle"),
        "blosc_zlib_shuf": BloscCodec(cname="zlib", clevel=5, shuffle="shuffle"),
    }
    try:
        from zarr.codecs.numcodecs import Zlib as NcZlib, Shuffle as NcShuffle
    except ImportError:
        from numcodecs.zarr3 import Zlib as NcZlib, Shuffle as NcShuffle
    comp_map["zlib5"] = NcZlib(level=5)
    comp_map["zlib1"] = NcZlib(level=1)
    comp_map["shuffle4"] = NcShuffle(elementsize=4)
    if "nested_inner" in spec:
        kwargs["serializer"] = ShardingCodec(
            chunk_shape=spec["nested_inner"], codecs=[BytesCodec()])
    if spec.get("default_compressors"):
        pass  # let zarr-python pick its defaults
    elif "compressors" in spec:
        kwargs["compressors"] = tuple(comp_map[c] for c in spec["compressors"])
    else:
        kwargs["compressors"] = ()
    if spec.get("serializer") == "bytes_be":
        kwargs["serializer"] = BytesCodec(endian="big")
    if "filters" in spec:
        assert spec["filters"] == ["transpose10"]
        kwargs["filters"] = (TransposeCodec(order=(1, 0)),)
    if "fill_value" in spec:
        kwargs["fill_value"] = spec["fill_value"]
    if spec.get("chunk_key_encoding") == "v2":
        kwargs["chunk_key_encoding"] = {"name": "v2", "separator": "."}
    if "shards" in spec:
        kwargs["shards"] = spec["shards"]
    return kwargs
