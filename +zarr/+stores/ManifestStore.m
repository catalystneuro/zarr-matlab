classdef ManifestStore < zarr.stores.Store
    %MANIFESTSTORE Read-only "virtual" store: metadata lives in an index
    %   directory; chunk keys resolve through manifest.json to byte ranges
    %   in other files (kerchunk/VirtualiZarr-style) or inline base64 data.
    %
    %   store = zarr.stores.ManifestStore("/path/to/index.zarr")
    %   store = zarr.stores.ManifestStore("https://host/index.zarr")
    %
    %   A relative index location is resolved against the current folder
    %   when the store is created, and root holds the absolute path.
    %
    %   manifest.json format (aligned with VirtualiZarr's ChunkManifest):
    %   {
    %     "manifest_format": 1,
    %     "default_path": "../data.bin",          // optional
    %     "chunks": {
    %       "a/c/0/0": {"path": "../data.bin", "offset": 4096, "length": 65536},
    %       "a/c/0/1": {"inline": "<base64>"}
    %     }
    %   }
    %   A path is a file path relative to the index root, written without
    %   URL encoding even when the index is served over HTTP(S). An absolute
    %   filesystem path or an http(s) URL is accepted too. A URL is
    %   requested exactly as written, so it must be percent-encoded, and it
    %   may carry a query string, as a presigned S3 URL does.
    %
    %   A read that spans several chunks stored at http(s) URLs fetches them
    %   concurrently, on the thread workers of backgroundPool (see getMany
    %   and getPartialMany). Chunks in local files are read in turn.

    properties (SetAccess = immutable)
        root (1,1) string
    end

    properties
        %MAXCONCURRENTREQUESTS Requests getMany and getPartialMany keep in flight at once
        %   1 fetches every chunk in turn.
        MaxConcurrentRequests (1,1) double {mustBeInteger, mustBePositive} = 8

        %PARALLELTHRESHOLD Fewest remote chunks for which getMany and getPartialMany fetch concurrently
        %   The thread workers of backgroundPool take 1-3 s to start the
        %   first time they are used in a MATLAB session. Reads of fewer
        %   chunks are fetched in turn and never pay that.
        ParallelThreshold (1,1) double {mustBePositive} = 4
    end

    properties (Access = private)
        metaStore                % LocalStore/HttpStore over the index dir
        chunkMap                 % containers.Map: key -> entry struct
        defaultPath (1,1) string = ""
        isHttp (1,1) logical
    end

    methods
        function obj = ManifestStore(root)
            root = strip(string(root), 'right', '/');
            obj.isHttp = startsWith(root, "http://") || startsWith(root, "https://");
            if ~obj.isHttp
                % Resolve a relative location now, so a later change of folder
                % does not move the index or the chunk files it points to.
                root = zarr.internal.resolve_relative(pwd(), root);
            end
            obj.root = root;
            if obj.isHttp
                obj.metaStore = zarr.stores.HttpStore(obj.root);
            else
                obj.metaStore = zarr.stores.LocalStore(obj.root);
            end

            [bytes, found] = obj.metaStore.get("manifest.json");
            if ~found
                error("zarr:StoreError", "No manifest.json in '%s'.", obj.root);
            end
            txt = native2unicode(bytes, 'UTF-8');
            [topKeys, topVals] = zarr.internal.json_object_entries(txt);
            obj.chunkMap = containers.Map('KeyType', 'char', 'ValueType', 'any');
            for i = 1:numel(topKeys)
                switch topKeys(i)
                    case "default_path"
                        obj.defaultPath = string(jsondecode(char(topVals(i))));
                    case "chunks"
                        % keys may contain '/', so tokenize (jsondecode mangles)
                        [ck, cv] = zarr.internal.json_object_entries(topVals(i));
                        for j = 1:numel(ck)
                            obj.chunkMap(char(ck(j))) = jsondecode(char(cv(j)));
                        end
                end
            end
        end

        function [data, found] = get(obj, key)
            key = char(key);
            if obj.chunkMap.isKey(key)
                entry = obj.chunkMap(key);
                data = obj.fetch(entry, 0, Inf);
                found = true;
            else
                [data, found] = obj.metaStore.get(key);
            end
        end

        function [data, found] = getPartial(obj, key, offset, len)
            key = char(key);
            if obj.chunkMap.isKey(key)
                entry = obj.chunkMap(key);
                data = obj.fetch(entry, offset, len);
                found = true;
            else
                [data, found] = obj.metaStore.getPartial(key, offset, len);
            end
        end

        function [values, found] = getMany(obj, keys)
            %GETMANY Fetch several values, concurrently when enough are remote
            %   [values, found] = getMany(obj, keys) fetches the chunks that
            %   the manifest stores at http(s) URLs on the thread workers of
            %   backgroundPool, at most MaxConcurrentRequests at a time, when
            %   there are at least ParallelThreshold of them. Every other
            %   key is read in turn. If the concurrent fetch fails but the
            %   same chunks then read one after another, concurrent ranged
            %   reads are turned off for the rest of the session, with a
            %   warning.
            keys = reshape(string(keys), 1, []);
            [values, found] = obj.fetchMany(keys, zeros(1, numel(keys)), inf(1, numel(keys)), true);
        end

        function [values, found] = getPartialMany(obj, keys, offsets, lens)
            %GETPARTIALMANY Read a byte range of several values, concurrently when enough are remote
            %   [values, found] = getPartialMany(obj, keys, offsets, lens)
            %   reads lens(i) bytes at the 0-based offsets(i) of keys(i),
            %   choosing between concurrent and one-after-another reads as
            %   getMany does.
            keys = reshape(string(keys), 1, []);
            [values, found] = obj.fetchMany(keys, offsets, lens, false);
        end

        function [data, found] = getSuffix(obj, key, len)
            key = char(key);
            if obj.chunkMap.isKey(key)
                entry = obj.chunkMap(key);
                total = obj.entryLength(entry);
                data = obj.fetch(entry, max(0, total - len), len);
                found = true;
            else
                [data, found] = obj.metaStore.getSuffix(key, len);
            end
        end

        function tf = exists(obj, key)
            tf = obj.chunkMap.isKey(char(key)) || obj.metaStore.exists(key);
        end

        function set(varargin)
            error("zarr:StoreError", "ManifestStore is read-only.");
        end

        function erase(varargin)
            error("zarr:StoreError", "ManifestStore is read-only.");
        end

        function ks = list(obj)
            metaKeys = obj.metaStore.list();
            metaKeys = metaKeys(metaKeys ~= "manifest.json");
            ks = unique([metaKeys; string(obj.chunkMap.keys())']);
        end

        function [subdirs, files] = listDir(obj, prefix)
            prefix = string(prefix);
            if strlength(prefix) > 0
                pre = prefix + "/";
            else
                pre = "";
            end
            ks = obj.list();
            rel = ks(startsWith(ks, pre));
            rel = extractAfter(rel, strlength(pre));
            hasSlash = contains(rel, "/");
            files = rel(~hasSlash & strlength(rel) > 0);
            subdirs = unique(extractBefore(rel(hasSlash), "/"));
        end
    end

    methods (Access = private)
        function n = entryLength(obj, entry) %#ok<INUSL>
            if isfield(entry, 'inline')
                n = numel(matlab.net.base64decode(char(string(entry.inline))));
            else
                n = double(entry.length);
            end
        end

        function data = fetch(obj, entry, offset, len)
            if isfield(entry, 'inline')
                full = reshape(matlab.net.base64decode(char(string(entry.inline))), 1, []);
                data = full(offset + 1:min(offset + len, numel(full)));
                return
            end
            [resolved, start, n] = obj.locate(entry, offset, len);
            if isHttpUrl(resolved)
                % The URL is now fully encoded: an absolute one came that way
                % from the manifest, possibly with a query string. So it is
                % requested exactly as written.
                [data, found] = zarr.internal.http_read_range(resolved, start, n);
            else
                fid = fopen(resolved, 'r');
                found = fid ~= -1;
                if found
                    cleaner = onCleanup(@() fclose(fid));
                    fseek(fid, start, 'bof');
                    data = fread(fid, n, '*uint8')';
                else
                    data = uint8([]);
                end
            end
            if ~found
                error("zarr:StoreError", ...
                    "Manifest target '%s' is missing or unreadable.", resolved);
            end
        end

        function [resolved, start, n] = locate(obj, entry, offset, len)
            %LOCATE Where len bytes at offset of a chunk are stored: the file
            %   path or URL, the 0-based position in it, and the number of
            %   bytes, which stops at the end of the chunk. For an entry that
            %   is not inline.
            if isfield(entry, 'path') && ~isempty(entry.path)
                target = string(entry.path);
            elseif strlength(obj.defaultPath) > 0
                target = obj.defaultPath;
            else
                error("zarr:StoreError", "Manifest entry has no path and no default_path.");
            end
            start = double(entry.offset) + offset;
            n = min(len, double(entry.length) - offset);
            if obj.isHttp && ~isHttpUrl(target)
                % A relative path names a file beside the index the way a store
                % key does, so it is encoded the same way before it joins the
                % index URL.
                target = zarr.internal.encode_url_path(target);
            end
            resolved = zarr.internal.resolve_relative(obj.root, target);
        end

        function [values, found] = fetchMany(obj, keys, offsets, lens, whole)
            %FETCHMANY Read lens(i) bytes at offsets(i) of keys(i), or the
            %   whole value of each key when whole is true. Chunks stored at
            %   http(s) URLs are read concurrently when there are enough of
            %   them; every other key is read in turn.
            numKeys = numel(keys);
            values = cell(1, numKeys);
            found = false(1, numKeys);
            urls = strings(1, numKeys);
            ranges = zeros(numKeys, 2);
            remote = false(1, numKeys);
            for i = 1:numKeys
                key = char(keys(i));
                if ~obj.chunkMap.isKey(key)
                    continue
                end
                entry = obj.chunkMap(key);
                if isfield(entry, 'inline')
                    continue
                end
                [resolved, start, n] = obj.locate(entry, offsets(i), lens(i));
                if isHttpUrl(resolved)
                    urls(i) = resolved;
                    ranges(i, :) = [start n];
                    remote(i) = true;
                end
            end

            fetched = false(1, numKeys);
            parallelError = [];
            if nnz(remote) >= obj.ParallelThreshold && obj.MaxConcurrentRequests > 1 ...
                    && zarr.internal.parallel_fetch_available([], "range")
                try
                    [values(remote), found(remote)] = zarr.internal.http_get_parallel( ...
                        urls(remote), obj.MaxConcurrentRequests, ranges(remote, :));
                    fetched = remote;
                catch parallelError
                    % The chunks are read in turn below. A failure that also
                    % happens one request at a time is a real one, and that
                    % read raises it.
                end
            end
            missing = find(fetched & ~found, 1);
            if ~isempty(missing)
                error("zarr:StoreError", ...
                    "Manifest target '%s' is missing or unreadable.", urls(missing));
            end

            for i = find(~fetched)
                if whole
                    [values{i}, found(i)] = obj.get(keys(i));
                else
                    [values{i}, found(i)] = obj.getPartial(keys(i), offsets(i), lens(i));
                end
            end
            if ~isempty(parallelError)
                zarr.internal.parallel_fetch_available(false, "range");
                warning("zarr:ParallelFetchUnavailable", ...
                    "Fetching chunks concurrently failed (%s). Chunks are fetched one at a time for the rest of this MATLAB session.", ...
                    parallelError.message);
            end
        end
    end
end

function tf = isHttpUrl(location)
tf = startsWith(location, "http://") || startsWith(location, "https://");
end
