function codec = find_unsupported_codec(codecs)
%FIND_UNSUPPORTED_CODEC First zarr.codecs.UnsupportedCodec in a codec chain.
%   codec = find_unsupported_codec(codecs) searches the chain and the inner
%   and index chains of any sharding codec in it, and returns the first
%   unsupported codec found, or [] if there is none.

codec = [];
for i = 1:numel(codecs)
    c = codecs{i};
    if isa(c, 'zarr.codecs.UnsupportedCodec')
        codec = c;
    elseif isa(c, 'zarr.codecs.ShardingCodec')
        codec = zarr.internal.find_unsupported_codec([c.codecs, c.indexCodecs]);
    end
    if ~isempty(codec)
        return
    end
end
end
