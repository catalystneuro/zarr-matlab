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
    root = string(tok{1}) + "/";
    basePath = string(tok{2});
else
    [root, basePath] = splitRoot(strrep(base, "\", "/"));
end
% A relative base can climb above its first segment: the result keeps the
% leading ".." segments and is resolved later against the current folder.
isRelativeBase = strlength(root) == 0;

% The base's own "." and ".." segments follow the same rules as rel's, so
% "/a/b/../idx" is the base "/a/idx". segs starts as a 1x0 row and stays a
% row: deleting the last element of a column string array flips it to
% 1x0, after which (end+1,1) assignment gap-fills with <missing>.
segs = strings(1, 0);
segs = applySegments(segs, basePath, isRelativeBase, base);
segs = applySegments(segs, strrep(rel, "\", "/"), isRelativeBase, rel);

full = root + strjoin(segs, "/");
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

function [root, rest] = splitRoot(p)
%SPLITROOT Split a filesystem path into its root and the rest.
%   p uses "/" as the separator. root is the share ("//server/share/") for
%   a UNC path, the drive with its slash ("C:/") for a Windows path, "/"
%   for a POSIX path, and "" for a relative path, whose rest is then all of
%   p. A ".." cannot climb above the root.
unc = regexp(char(p), '^//[^/]+/[^/]+', 'match', 'once');
drive = regexp(char(p), '^[A-Za-z]:/?', 'match', 'once');
if ~isempty(unc)
    root = string(unc) + "/";
    rest = extractAfter(p, strlength(unc));
elseif ~isempty(drive)
    root = string(drive);
    rest = extractAfter(p, strlength(root));
elseif startsWith(p, "/")
    root = "/";
    rest = extractAfter(p, 1);
else
    root = "";
    rest = p;
end
end
