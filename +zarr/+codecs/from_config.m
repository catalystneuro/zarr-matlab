function codec = from_config(entry)
%FROM_CONFIG Build a codec object from a decoded metadata entry.
%   entry is a struct with field 'name' and optional 'configuration'. A
%   codec zarr-matlab does not implement is returned as a
%   zarr.codecs.UnsupportedCodec, which raises zarr:UnsupportedCodec only
%   when a pipeline is built from it.

name = string(entry.name);
if isfield(entry, 'configuration') && ~isempty(entry.configuration)
    cfg = entry.configuration;
else
    cfg = struct();
end

switch name
    case "bytes"
        codec = zarr.codecs.BytesCodec.fromConfig(cfg);
    case "transpose"
        codec = zarr.codecs.TransposeCodec.fromConfig(cfg);
    case "gzip"
        codec = zarr.codecs.GzipCodec.fromConfig(cfg);
    case "crc32c"
        codec = zarr.codecs.Crc32cCodec.fromConfig(cfg);
    case "sharding_indexed"
        codec = zarr.codecs.ShardingCodec.fromConfig(cfg);
    case "blosc"
        codec = zarr.codecs.BloscCodec.fromConfig(cfg);
    case "zstd"
        codec = zarr.codecs.ZstdCodec.fromConfig(cfg);
    case "vlen-utf8"
        codec = zarr.codecs.VlenUtf8Codec();
    case "vlen-bytes"
        codec = zarr.codecs.VlenBytesCodec();
    case "numcodecs.zlib"
        codec = zarr.codecs.ZlibCodec.fromConfig(cfg);
    case "numcodecs.shuffle"
        codec = zarr.codecs.ShuffleCodec.fromConfig(cfg);
    otherwise
        codec = zarr.codecs.UnsupportedCodec(name, string(jsonencode(entry)));
end
end
