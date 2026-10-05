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
    %
    %   A read that spans several chunks fetches them concurrently, on the
    %   thread workers of backgroundPool (see getMany and getPartialMany).

    properties (SetAccess = immutable)
        baseUrl (1,1) string
    end

    properties
        %MAXCONCURRENTREQUESTS Requests getMany and getPartialMany keep in flight at once
        %   1 fetches every key in turn.
        MaxConcurrentRequests (1,1) double {mustBeInteger, mustBePositive} = 8

        %PARALLELTHRESHOLD Fewest keys for which getMany and getPartialMany fetch concurrently
        %   The thread workers of backgroundPool take 1-3 s to start the
        %   first time they are used in a MATLAB session. Reads of fewer
        %   keys, such as the single chunk of a scalar array, are fetched in
        %   turn and never pay that.
        ParallelThreshold (1,1) double {mustBePositive} = 4
    end

    methods
        function obj = HttpStore(baseUrl)
            obj.baseUrl = strip(string(baseUrl), 'right', '/');
        end

        function [data, found] = get(obj, key)
            [data, found] = zarr.internal.http_get(obj.keyUrl(key), []);
        end

        function [data, found] = getPartial(obj, key, offset, len)
            [data, found] = zarr.internal.http_read_range(obj.keyUrl(key), offset, len);
        end

        function [values, found] = getMany(obj, keys)
            %GETMANY Fetch several values, concurrently when there are enough
            %   [values, found] = getMany(obj, keys) fetches the keys on the
            %   thread workers of backgroundPool, at most
            %   MaxConcurrentRequests at a time, when there are at least
            %   ParallelThreshold of them; otherwise one after another.
            %
            %   Thread workers cannot run every function in every MATLAB
            %   release. If the concurrent fetch fails but the same keys then
            %   read one after another, concurrent fetching is turned off for
            %   the rest of the session, with a warning.
            keys = reshape(string(keys), 1, []);
            if numel(keys) < obj.ParallelThreshold || obj.MaxConcurrentRequests == 1 ...
                    || ~zarr.internal.parallel_fetch_available()
                [values, found] = getMany@zarr.stores.Store(obj, keys);
                return
            end
            urls = strings(1, numel(keys));
            for i = 1:numel(keys)
                urls(i) = obj.keyUrl(keys(i));
            end
            try
                [values, found] = zarr.internal.http_get_parallel(urls, obj.MaxConcurrentRequests);
            catch parallelError
                % A failure that also happens one request at a time is a
                % real one, and the sequential read raises it.
                [values, found] = getMany@zarr.stores.Store(obj, keys);
                zarr.internal.parallel_fetch_available(false);
                warning("zarr:ParallelFetchUnavailable", ...
                    "Fetching chunks concurrently failed (%s). Chunks are fetched one at a time for the rest of this MATLAB session.", ...
                    parallelError.message);
            end
        end

        function [values, found] = getPartialMany(obj, keys, offsets, lens)
            %GETPARTIALMANY Read a byte range of several values, concurrently when there are enough
            %   [values, found] = getPartialMany(obj, keys, offsets, lens)
            %   reads lens(i) bytes at the 0-based offsets(i) of keys(i). It
            %   chooses between concurrent and one-after-another reads as
            %   getMany does, and turns concurrent ranged reads off for the
            %   rest of the session in the same way if they fail.
            keys = reshape(string(keys), 1, []);
            if numel(keys) < obj.ParallelThreshold || obj.MaxConcurrentRequests == 1 ...
                    || ~zarr.internal.parallel_fetch_available([], "range")
                [values, found] = getPartialMany@zarr.stores.Store(obj, keys, offsets, lens);
                return
            end
            urls = strings(1, numel(keys));
            for i = 1:numel(keys)
                urls(i) = obj.keyUrl(keys(i));
            end
            ranges = [reshape(double(offsets), [], 1), reshape(double(lens), [], 1)];
            try
                [values, found] = zarr.internal.http_get_parallel(urls, ...
                    obj.MaxConcurrentRequests, ranges);
            catch parallelError
                % A failure that also happens one request at a time is a
                % real one, and the sequential read raises it.
                [values, found] = getPartialMany@zarr.stores.Store(obj, keys, offsets, lens);
                zarr.internal.parallel_fetch_available(false, "range");
                warning("zarr:ParallelFetchUnavailable", ...
                    "Reading byte ranges concurrently failed (%s). Ranges are read one at a time for the rest of this MATLAB session.", ...
                    parallelError.message);
            end
        end

        function [data, found] = getSuffix(obj, key, len)
            [data, found] = zarr.internal.http_get(obj.keyUrl(key), sprintf('bytes=-%d', len));
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

    methods (Access = private)
        function url = keyUrl(obj, key)
            % Keys can hold characters that change what a URL names, such as
            % the '#' in the '#refs#' keys of .mat-derived stores.
            url = obj.baseUrl + "/" + zarr.internal.encode_url_path(key);
        end
    end
end
