function encoded = encode_url_path(keyPath)
%ENCODE_URL_PATH Percent-encode a store key or relative path for a URL.
%   encoded = encode_url_path(keyPath) escapes the characters that would
%   change what a URL names: "%" (starts an escape), "#" (starts a
%   fragment) and the space. "/" is kept, so segments stay segments.

encoded = strrep(strrep(strrep(string(keyPath), "%", "%25"), "#", "%23"), " ", "%20");
end
