function [data, found] = http_read_range(url, offset, len)
%HTTP_READ_RANGE Read len bytes at a 0-based offset from a complete URL.
%   [data, found] = http_read_range(url, offset, len) requests url exactly
%   as given, so it must already be percent-encoded. found is false when the
%   server answers 404 or 403; any other failure raises zarr:StoreError.
%
%   The response says which bytes the server sent, and the requested bytes
%   are taken from them:
%     206 - the bytes named by Content-Range, which may run past the end of
%           the requested range. Without that header, the body starts at
%           offset.
%     200 - the server ignored the Range header and sent the whole object.
%   data is shorter than len when the object ends before offset + len.

request = matlab.net.http.RequestMessage('GET', matlab.net.http.HeaderField( ...
    'Range', sprintf('bytes=%d-%d', offset, offset + len - 1)));
options = matlab.net.http.HTTPOptions('ConnectTimeout', 30, 'ConvertResponse', false);
% 'literal' keeps the URL as written rather than encoding it again.
response = request.send(matlab.net.URI(url, 'literal'), options);
status = double(response.StatusCode);

data = uint8([]);
found = status ~= 404 && status ~= 403;
if ~found
    return
end
body = reshape(uint8(response.Body.Data), 1, []);
switch status
    case 206
        bodyStart = contentRangeStart(response, offset);
    case 200
        bodyStart = 0;
    otherwise
        error("zarr:StoreError", "HTTP status %d reading bytes %d-%d of %s.", ...
            status, offset, offset + len - 1, url);
end
% body holds the object's bytes from bodyStart on.
first = offset - bodyStart + 1;
if first < 1
    error("zarr:StoreError", ...
        "Requested bytes from %d of %s, but the server sent bytes from %d.", ...
        offset, url, bodyStart);
end
data = body(first:min(first + len - 1, numel(body)));
end

function start = contentRangeStart(response, offset)
%CONTENTRANGESTART The 0-based position in the object of a 206 body's first
%   byte, from its Content-Range header ("bytes 10-19/100"). A response
%   without a readable header is taken to start at the requested offset.
start = offset;
field = response.getFields('Content-Range');
if isempty(field)
    return
end
tokens = regexp(char(field(1).Value), '^\s*bytes\s+(\d+)-', 'tokens', 'once');
if ~isempty(tokens)
    start = str2double(tokens{1});
end
end
