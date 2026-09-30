classdef ManifestStore < zarr.stores.Store
    %MANIFESTSTORE Read-only "virtual" store: metadata lives in an index
    %   directory; chunk keys resolve through manifest.json to byte ranges
    %   in other files (kerchunk/VirtualiZarr-style) or inline base64 data.
    %
    %   store = zarr.stores.ManifestStore("/path/to/index.zarr")
    %   store = zarr.stores.ManifestStore("https://host/index.zarr")
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
    %   Paths are relative to the index root (absolute paths/URLs allowed).

    properties (SetAccess = immutable)
        root (1,1) string
    end

    properties (Access = private)
        metaStore                % LocalStore/HttpStore over the index dir
        chunkMap                 % containers.Map: key -> entry struct
        defaultPath (1,1) string = ""
        isHttp (1,1) logical
    end

    methods
        function obj = ManifestStore(root)
            obj.root = strip(string(root), 'right', '/');
            obj.isHttp = startsWith(obj.root, "http://") || startsWith(obj.root, "https://");
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
            if isfield(entry, 'path') && ~isempty(entry.path)
                target = string(entry.path);
            elseif strlength(obj.defaultPath) > 0
                target = obj.defaultPath;
            else
                error("zarr:StoreError", "Manifest entry has no path and no default_path.");
            end
            base = double(entry.offset);
            n = min(len, double(entry.length) - offset);
            resolved = zarr.internal.resolve_relative(obj.root, target);
            if startsWith(resolved, "http://") || startsWith(resolved, "https://")
                % A manifest path is a URL, already percent-encoded and possibly
                % carrying a query string, so it is requested exactly as written.
                [data, found] = zarr.stores.HttpStore.readRange(resolved, base + offset, n);
            else
                fid = fopen(resolved, 'r');
                found = fid ~= -1;
                if found
                    cleaner = onCleanup(@() fclose(fid));
                    fseek(fid, base + offset, 'bof');
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
    end
end
