function [data, found] = http_get(url, rangeHeader)
%HTTP_GET Fetch a URL as bytes, optionally with a Range header.
%   [data, found] = http_get(url, rangeHeader) requests url exactly as
%   given, so it must already be percent-encoded. rangeHeader is a Range
%   header value such as 'bytes=0-99', or [] for the whole object. found is
%   false when the server answers 404 or 403; any other failure raises the
%   webread error.

headers = {};
if ~isempty(rangeHeader)
    headers = {'Range', rangeHeader};
end
opts = weboptions('ContentType', 'binary', 'Timeout', 30);
if ~isempty(headers)
    opts.HeaderFields = headers;
end
try
    data = reshape(webread(url, opts), 1, []);
    data = uint8(data);
    found = true;
catch err
    if contains(err.identifier, "404") || contains(err.identifier, "403")
        data = uint8([]);
        found = false;
    else
        rethrow(err);
    end
end
end
