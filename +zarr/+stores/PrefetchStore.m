classdef PrefetchStore < zarr.stores.Store
    %PREFETCHSTORE Store wrapper that answers reads from values fetched in advance.
    %   store = zarr.stores.PrefetchStore(inner) wraps another store.
    %   prefetch(store, keys) fetches the given keys with one call to the
    %   inner store's getMany, which zarr.stores.HttpStore serves with
    %   concurrent requests, and keeps the values. get and getMany answer
    %   prefetched keys from those values, including keys the inner store
    %   does not hold. Every other read, including byte-range reads, goes
    %   to the inner store. Writing or erasing a key drops its prefetched
    %   value.
    %
    %   Use it when a program knows which keys it will read one after
    %   another, such as the single chunks of many small arrays, and each
    %   read would otherwise be a round trip of its own.
    %
    %   Example:
    %       store = zarr.stores.PrefetchStore(zarr.stores.HttpStore(url));
    %       store.prefetch(["a/c/0", "b/c/0"]);
    %       a = zarr.open(store, Path="a");
    %       values = a(:);   % served from the prefetched chunk

    properties (SetAccess = immutable)
        inner   % the wrapped zarr.stores.Store
    end

    properties (Access = private)
        % containers.Map from key to struct(data, found). Created in the
        % constructor: a handle default would be shared by every instance.
        prefetched
    end

    methods
        function obj = PrefetchStore(inner)
            arguments
                inner (1,1) zarr.stores.Store
            end
            obj.inner = inner;
            obj.prefetched = containers.Map('KeyType', 'char', 'ValueType', 'any');
        end

        function prefetch(obj, keys)
            %PREFETCH Fetch keys together and keep their values.
            %   Keys fetched before are not fetched again.
            keys = reshape(string(keys), 1, []);
            keys = keys(~obj.isPrefetched(keys));
            if isempty(keys)
                return
            end
            [fetched, found] = obj.inner.getMany(keys);
            for i = 1:numel(keys)
                obj.prefetched(char(keys(i))) = struct("data", fetched{i}, "found", found(i));
            end
        end

        function [data, found] = get(obj, key)
            if obj.isPrefetched(key)
                entry = obj.prefetched(char(key));
                data = entry.data;
                found = entry.found;
                return
            end
            [data, found] = obj.inner.get(key);
        end

        function [values, found] = getMany(obj, keys)
            keys = reshape(string(keys), 1, []);
            values = cell(1, numel(keys));
            found = false(1, numel(keys));
            held = obj.isPrefetched(keys);
            for i = find(held)
                [values{i}, found(i)] = obj.get(keys(i));
            end
            if ~all(held)
                [values(~held), found(~held)] = obj.inner.getMany(keys(~held));
            end
        end

        function [data, found] = getPartial(obj, key, offset, len)
            [data, found] = obj.inner.getPartial(key, offset, len);
        end

        function [values, found] = getPartialMany(obj, keys, offsets, lens)
            [values, found] = obj.inner.getPartialMany(keys, offsets, lens);
        end

        function [data, found] = getSuffix(obj, key, len)
            [data, found] = obj.inner.getSuffix(key, len);
        end

        function tf = exists(obj, key)
            tf = obj.inner.exists(key);
        end

        function set(obj, key, data)
            obj.forget(key);
            obj.inner.set(key, data);
        end

        function erase(obj, key)
            obj.forget(key);
            obj.inner.erase(key);
        end

        function keys = list(obj)
            keys = obj.inner.list();
        end

        function [subdirs, files] = listDir(obj, prefix)
            [subdirs, files] = obj.inner.listDir(prefix);
        end
    end

    methods (Access = private)
        function tf = isPrefetched(obj, keys)
            %ISPREFETCHED True for each of keys that has a prefetched value.
            tf = isKey(obj.prefetched, cellstr(keys));
        end

        function forget(obj, key)
            if obj.isPrefetched(key)
                remove(obj.prefetched, char(key));
            end
        end
    end
end
