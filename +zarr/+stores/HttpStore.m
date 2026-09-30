classdef HttpStore < zarr.stores.Store
    %HTTPSTORE Read-only Zarr store over HTTP(S).
    %   zarr.stores.HttpStore("https://host/path/to/root")
    %
    %   Uses Range requests for partial reads when the server supports them
    %   (S3, nginx, most CDNs), so sharded arrays fetch only the byte ranges
    %   they need; falls back to full-object reads otherwise.
    %
    %   HTTP servers are not listable, so hierarchy browsing (children/tree)
    %   requires consolidated metadata (zarr.consolidate_metadata). Direct
    %   opens by path (zarr.open(store, Path="a/b")) always work.

    properties (SetAccess = immutable)
        baseUrl (1,1) string
    end

    methods
        function obj = HttpStore(baseUrl)
            obj.baseUrl = strip(string(baseUrl), 'right', '/');
        end

        function [data, found] = get(obj, key)
            [data, found] = zarr.stores.HttpStore.fetch(obj.keyUrl(key), []);
        end

        function [data, found] = getPartial(obj, key, offset, len)
            [data, found] = zarr.stores.HttpStore.readRange(obj.keyUrl(key), offset, len);
        end

        function [data, found] = getSuffix(obj, key, len)
            [data, found] = zarr.stores.HttpStore.fetch(obj.keyUrl(key), sprintf('bytes=-%d', len));
            if ~found
                return
            end
            if numel(data) > len
                data = data(end - len + 1:end);
            end
        end

        function tf = exists(obj, key)
            [~, tf] = obj.getPartial(key, 0, 1);
        end

        function set(varargin)
            error("zarr:StoreError", "HttpStore is read-only.");
        end

        function erase(varargin)
            error("zarr:StoreError", "HttpStore is read-only.");
        end

        function keys = list(obj) %#ok<STOUT,MANU>
            error("zarr:StoreError", ...
                "HTTP stores cannot be listed. Consolidate metadata (zarr.consolidate_metadata) to browse the hierarchy, or open nodes directly by Path.");
        end

        function [subdirs, files] = listDir(obj, prefix) %#ok<STOUT,INUSD>
            error("zarr:StoreError", ...
                "HTTP stores cannot be listed. Consolidate metadata (zarr.consolidate_metadata) to browse the hierarchy, or open nodes directly by Path.");
        end
    end

    methods (Static, Access = {?zarr.stores.ManifestStore})
        function [data, found] = readRange(url, offset, len)
            %READRANGE Read len bytes at 0-based offset from a complete URL.
            %   url is used as given, so it must already be percent-encoded.
            [data, found] = zarr.stores.HttpStore.fetch(url, ...
                sprintf('bytes=%d-%d', offset, offset + len - 1));
            if ~found
                return
            end
            if numel(data) > len
                % Server ignored the Range header and sent the whole object.
                first = offset + 1;
                data = data(first:min(offset + len, numel(data)));
            end
        end
    end

    methods (Access = private)
        function url = keyUrl(obj, key)
            % Percent-encode characters that would change URL semantics
            % ('#' starts a fragment; .mat-derived stores use '#refs#').
            key = strrep(strrep(strrep(string(key), "%", "%25"), "#", "%23"), " ", "%20");
            url = obj.baseUrl + "/" + key;
        end
    end

    methods (Static, Access = private)
        function [data, found] = fetch(url, rangeHeader)
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
    end
end
