function codecs = complete_codecs(codecs, info)
%COMPLETE_CODECS Ensure a codec chain has exactly one array->bytes codec,
%   inserting the dtype's default serializer (BytesCodec, or the vlen codec
%   for variable-length dtypes) before the bytes->bytes codecs if the user
%   supplied none.

codecs = reshape(codecs, 1, []);
if ~isempty(zarr.internal.find_unsupported_codec(codecs))
    % The kind of an unsupported codec is unknown, so whether the chain
    % already has a serializer cannot be decided; it is kept as written.
    return
end
kinds = strings(1, numel(codecs));
for i = 1:numel(codecs)
    kinds(i) = codecs{i}.kind;
end
if ~any(kinds == "array_bytes")
    if nargin > 1 && info.zarrType == "string"
        serializer = zarr.codecs.VlenUtf8Codec();
    elseif nargin > 1 && info.zarrType == "variable_length_bytes"
        serializer = zarr.codecs.VlenBytesCodec();
    else
        serializer = zarr.codecs.BytesCodec();
    end
    insertAt = find(kinds == "bytes_bytes", 1);
    if isempty(insertAt)
        insertAt = numel(codecs) + 1;
    end
    codecs = [codecs(1:insertAt - 1), {serializer}, codecs(insertAt:end)];
end
end
