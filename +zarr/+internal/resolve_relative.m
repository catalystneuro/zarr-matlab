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
    basePath = string(tok{2});
else
    hostPart = "";
    basePath = strrep(base, "\", "/");
end
leadingSlash = ~isHttp && startsWith(basePath, "/");
% A relative base can climb above its first segment: the result keeps the
% leading ".." segments and is resolved later against the current folder.
isRelativeBase = ~isHttp && ~leadingSlash && isempty(regexp(base, '^[A-Za-z]:', 'once'));

% The base's own "." and ".." segments follow the same rules as rel's, so
% "/a/b/../idx" is the base "/a/idx". segs starts as a 1x0 row and stays a
% row: deleting the last element of a column string array flips it to
% 1x0, after which (end+1,1) assignment gap-fills with <missing>.
segs = strings(1, 0);
segs = applySegments(segs, basePath, isRelativeBase, base);
segs = applySegments(segs, strrep(rel, "\", "/"), isRelativeBase, rel);

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

function segs = applySegments(segs, pathText, isRelativeBase, label)
%APPLYSEGMENTS Append the segments of pathText to segs, resolving "." and "..".
%   A ".." removes the last name in segs. When none is left, it is kept for
%   a relative base, which is resolved later against the current folder,
%   and is an error for an absolute one. label names the path in the error.
for s = reshape(split(pathText, "/"), 1, [])
    if s == "" || s == "."
        continue
    elseif s == ".."
        if ~isempty(segs) && segs(end) ~= ".."
            segs(end) = [];
        elseif isRelativeBase
            segs(end + 1) = s; %#ok<AGROW>
        else
            error("zarr:StoreError", "Relative path '%s' escapes above the root.", label);
        end
    else
        segs(end + 1) = s; %#ok<AGROW>
    end
end
end
