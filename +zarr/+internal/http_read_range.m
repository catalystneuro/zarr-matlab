function [data, found] = http_read_range(url, offset, len)
%HTTP_READ_RANGE Read len bytes at a 0-based offset from a complete URL.
%   [data, found] = http_read_range(url, offset, len) requests url exactly
%   as given, so it must already be percent-encoded. A server that ignores
%   the Range header sends the whole object, and the requested bytes are
%   taken from it. found is as for zarr.internal.http_get.

[data, found] = zarr.internal.http_get(url, sprintf('bytes=%d-%d', offset, offset + len - 1));
if ~found
    return
end
if numel(data) > len
    % Server ignored the Range header and sent the whole object.
    first = offset + 1;
    data = data(first:min(offset + len, numel(data)));
end
end
