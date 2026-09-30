function full = resolve_relative(base, rel)
%RESOLVE_RELATIVE Resolve rel against a base directory (path or URL),
%   normalizing "." and ".." segments. Absolute rel (URL or filesystem
%   path) is returned as-is.

base = string(base);
rel = string(rel);
if startsWith(rel, "http://") || startsWith(rel, "https://")
    full = rel;
    return
end

isHttp = startsWith(base, "http://") || startsWith(base, "https://");
if ~isHttp && (startsWith(rel, "/") || ~isempty(regexp(rel, '^[A-Za-z]:[\\/]', 'once')))
    full = rel;  % absolute filesystem path
    return
end

if isHttp
    tok = regexp(char(base), '^(https?://[^/]+)(.*)$', 'tokens', 'once');
    hostPart = string(tok{1});
    pathPart = string(tok{2});
    segs = split(pathPart, "/");
else
    hostPart = "";
    segs = split(strrep(base, "\", "/"), "/");
end
% Keep segs a row vector throughout: deleting the last element of a column
% string array flips it to 1x0, after which (end+1,1) assignment gap-fills
% with <missing>.
segs = reshape(segs(strlength(segs) > 0 & segs ~= "."), 1, []);
leadingSlash = ~isHttp && startsWith(strrep(base, "\", "/"), "/");
% A relative base can climb above its first segment: the result keeps the
% leading ".." segments and is resolved later against the current folder.
isRelativeBase = ~isHttp && ~leadingSlash && isempty(regexp(base, '^[A-Za-z]:', 'once'));

for s = reshape(split(strrep(rel, "\", "/"), "/"), 1, [])
    if s == "" || s == "."
        continue
    elseif s == ".."
        if ~isempty(segs) && segs(end) ~= ".."
            segs(end) = [];
        elseif isRelativeBase
            segs(end + 1) = s; %#ok<AGROW>
        else
            error("zarr:StoreError", "Relative path '%s' escapes above the root.", rel);
        end
    else
        segs(end + 1) = s; %#ok<AGROW>
    end
end

if isempty(segs)
    joined = "";
else
    joined = strjoin(segs, "/");
end
if isHttp
    full = hostPart + "/" + joined;
elseif leadingSlash
    full = "/" + joined;
else
    full = joined;
end
end
