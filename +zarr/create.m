function z = create(store, shape, dtype, opts)
%CREATE Create a new Zarr v3 array.
%   z = zarr.create(store, shape, dtype, Name=Value)
%
%   store  - directory path or zarr.stores.Store (the store ROOT)
%   shape  - Zarr shape (row vector; [] creates a rank-0 scalar array,
%            a scalar n creates a rank-1 array of length n)
%   dtype  - MATLAB class name or Zarr data_type (default "double"). For a
%            data_type that needs a configuration -- a "struct" (whose
%            elements are structs of named fields) or a
%            "fixed_length_utf32" -- pass the data_type itself as
%            a scalar struct with fields name and configuration, e.g.
%              zarr.create(store, 3, struct('name', "struct", ...
%                  'configuration', struct('fields', fields)))
%            where fields is a struct array of {name, data_type} entries.
%
%   Options:
%     Path            - node path within the store (default "" = root)
%     ChunkShape      - chunk shape (default: whole array in one chunk)
%     FillValue       - fill value (default 0 / false)
%     Codecs          - cell array of codec objects. If it contains no
%                       array->bytes codec, a little-endian BytesCodec is
%                       inserted automatically (so {GzipCodec(5)} works).
%     Attributes      - struct of user attributes
%     DimensionNames  - string array (may contain missing for null)
%     Order           - "C" (default) or "F"; "F" adds a transpose codec so
%                       chunks are stored column-major (fast MATLAB I/O,
%                       still fully readable by zarr-python)
%     Overwrite       - overwrite an existing node (default false)

arguments
    store
    shape (1,:) double {mustBeNonnegative, mustBeInteger}
    dtype = "double"
    opts.Path (1,1) string = ""
    opts.ChunkShape (1,:) double = []
    opts.ShardShape (1,:) double = []
    opts.IndexLocation (1,1) string {mustBeMember(opts.IndexLocation, ["start", "end"])} = "end"
    opts.FillValue = []
    opts.Codecs cell = {}
    opts.Attributes struct = struct()
    opts.DimensionNames string = string.empty
    opts.Order (1,1) string {mustBeMember(opts.Order, ["C", "F"])} = "C"
    opts.ChunkKeyEncoding (1,1) string {mustBeMember(opts.ChunkKeyEncoding, ["default", "v2"])} = "default"
    opts.WriteEmptyChunks (1,1) logical = false
    opts.Overwrite (1,1) logical = false
end

store = zarr.internal.resolve_store(store);
path = zarr.internal.normalize_path(opts.Path);
if isstruct(dtype)
    % A data_type that carries a configuration, in the same shape it takes
    % on disk: {"name": ..., "configuration": ...}.
    if ~isfield(dtype, 'name') || ~isfield(dtype, 'configuration')
        error("zarr:UnsupportedDataType", ...
            "A struct dtype must have both a name and a configuration field.");
    end
    dataType = string(dtype.name);
    dtypeConfig = dtype.configuration;
else
    tok = regexp(char(dtype), '^(?:numpy\.)?(datetime64|timedelta64)\[(\w+)\]$', 'tokens', 'once');
    if ~isempty(tok)
        dataType = "numpy." + tok{1};
        dtypeConfig = struct('unit', tok{2}, 'scale_factor', 1);
    else
        dataType = zarr.internal.normalize_dtype(dtype);
        dtypeConfig = [];
    end
end
info = zarr.internal.dtype_info(dataType, dtypeConfig);
dtypeConfig = info.config;
R = numel(shape);

% Chunk shape
if isempty(opts.ChunkShape)
    chunkShape = max(shape, 1);
else
    chunkShape = reshape(opts.ChunkShape, 1, []);
end
if numel(chunkShape) ~= R
    error("zarr:ShapeMismatch", "ChunkShape rank must match shape rank.");
end
if R > 0 && any(chunkShape < 1)
    error("zarr:InvalidChunkShape", "Chunk dimensions must be >= 1.");
end

% Fill value
if isempty(opts.FillValue) && ~isstring(opts.FillValue)
    if startsWith(info.zarrType, "numpy.")
        fillValue = intmin('int64');  % NaT
    else
        fillValue = zarr.internal.default_scalar_fill_value(info);
    end
else
    fillValue = opts.FillValue;
    if info.zarrType == "bool"
        fillValue = logical(fillValue);
    elseif info.zarrType == "string" || info.zarrType == "fixed_length_utf32"
        fillValue = string(fillValue);
    elseif info.zarrType == "variable_length_bytes"
        fillValue = uint8(fillValue(:)');
    elseif info.isStructured
        if ~isstruct(fillValue)
            error("zarr:TypeMismatch", ...
                "structured arrays take a scalar struct FillValue with one field per record field.");
        end
    else
        fillValue = cast(fillValue, char(info.matlabClass));
    end
end

% Codec chain: [array->array ..., one array->bytes, bytes->bytes ...]
codecs = zarr.internal.complete_codecs(opts.Codecs, info);
if opts.Order == "F" && R >= 2
    if any(cellfun(@(c) c.name == "transpose", codecs))
        error("zarr:InvalidCodecs", "Order=""F"" cannot be combined with an explicit transpose codec.");
    end
    codecs = [{zarr.codecs.TransposeCodec(R - 1:-1:0)}, codecs];
end

codecs = zarr.internal.fill_blosc_typesize(codecs, info.itemsize);

% Sharding: the stored (outer) chunk becomes the shard; the user's ChunkShape
% becomes the inner chunk shape and the codec chain moves inside the shard.
if ~isempty(opts.ShardShape)
    shardShape = reshape(opts.ShardShape, 1, []);
    if numel(shardShape) ~= R
        error("zarr:ShapeMismatch", "ShardShape rank must match shape rank.");
    end
    if any(mod(shardShape, chunkShape) ~= 0)
        error("zarr:InvalidChunkShape", ...
            "ShardShape [%s] must be a multiple of ChunkShape [%s] in every dimension.", ...
            num2str(shardShape), num2str(chunkShape));
    end
    codecs = {zarr.codecs.ShardingCodec(chunkShape, Codecs=codecs, ...
        IndexLocation=opts.IndexLocation)};
    chunkShape = shardShape;
end

meta = zarr.metadata.ArrayMetadata();
meta.shape = shape;
meta.dataType = dataType;
meta.dataTypeConfig = dtypeConfig;
meta.keyEncoding = opts.ChunkKeyEncoding;
if opts.ChunkKeyEncoding == "v2"
    meta.keySeparator = ".";
end
meta.chunkShape = chunkShape;
meta.fillValue = fillValue;
meta.codecs = codecs;
meta.attributes = opts.Attributes;
if ~isempty(opts.DimensionNames)
    if numel(opts.DimensionNames) ~= R
        error("zarr:ShapeMismatch", "DimensionNames must have one entry per dimension.");
    end
    meta.dimensionNames = reshape(opts.DimensionNames, 1, []);
end

if strlength(path) == 0
    key = "zarr.json";
else
    key = path + "/zarr.json";
end
if store.exists(key) && ~opts.Overwrite
    error("zarr:NodeExists", ...
        "A node already exists at '%s'. Pass Overwrite=true to replace it.", path);
end

zarr.internal.ensure_parents(store, path);
store.set(key, unicode2native(char(meta.toJsonText()), 'UTF-8'));
z = zarr.Array(store, path, meta);
z.writeEmptyChunks = opts.WriteEmptyChunks;
end
