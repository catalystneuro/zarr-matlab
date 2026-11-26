classdef PrefetchStore < zarr.stores.Store
    %PREFETCHSTORE Store wrapper that answers reads from values fetched in advance.
    %   store = zarr.stores.PrefetchStore(inner) wraps another store.
    %   prefetch(store, keys) fetches the given keys with one call to the
    %   inner store's getMany and keeps the values. zarr.stores.HttpStore
    %   serves that call with concurrent requests when there are at least
    %   ParallelThreshold keys, 4 by default (see its getMany).
    %
    %   Every read of a prefetched key is answered from its value: get,
    %   getMany and exists, and the byte-range reads getPartial,
    %   getPartialMany and getSuffix, which return part of the value. A key
    %   that the inner store did not hold when it was prefetched reads as
    %   absent. Reads of other keys, list and listDir go to the inner
    %   store. Writing or erasing a key drops its prefetched value.
    %
    %   Use it when a program knows which keys it will read one after
    %   another, such as the single chunks of many small arrays, and each
    %   read would otherwise be a round trip of its own.
    %
    %   Example:
    %       store = zarr.stores.PrefetchStore(zarr.stores.HttpStore(url));
    %       store.prefetch(["a", "b", "c", "d"] + "/c/0");
    %       a = zarr.open(store, Path="a");
    %       values = a(:);   % served from the prefetched chunk

    properties (SetAccess = immutable)
        Inner   % the wrapped zarr.stores.Store
    end

    properties (Access = private)
        % containers.Map from key to struct(data, found). Created in the
        % constructor: a handle default would be shared by every instance.
        Prefetched
    end

    methods
        function obj = PrefetchStore(inner)
            arguments
                inner (1,1) zarr.stores.Store
            end
            obj.Inner = inner;
            obj.Prefetched = containers.Map('KeyType', 'char', 'ValueType', 'any');
        end

        function prefetch(obj, keys)
            %PREFETCH Fetch keys together and keep their values.
            %   A key is fetched once, however often it is named in this
            %   call and in earlier ones.
            keys = unique(reshape(string(keys), 1, []), "stable");
            keys = keys(~obj.isPrefetched(keys));
            if isempty(keys)
                return
            end
            [fetched, found] = obj.Inner.getMany(keys);
            for i = 1:numel(keys)
                obj.Prefetched(char(keys(i))) = struct("data", fetched{i}, "found", found(i));
            end
        end

        function [data, found] = get(obj, key)
            if obj.isPrefetched(key)
                entry = obj.Prefetched(char(key));
                data = entry.data;
                found = entry.found;
                return
            end
            [data, found] = obj.Inner.get(key);
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
                [values(~held), found(~held)] = obj.Inner.getMany(keys(~held));
            end
        end

        function [data, found] = getPartial(obj, key, offset, len)
            if obj.isPrefetched(key)
                % The Store default takes the range from the value that
                % get returns.
                [data, found] = getPartial@zarr.stores.Store(obj, key, offset, len);
            else
                [data, found] = obj.Inner.getPartial(key, offset, len);
            end
        end

        function [values, found] = getPartialMany(obj, keys, offsets, lens)
            keys = reshape(string(keys), 1, []);
            values = cell(1, numel(keys));
            found = false(1, numel(keys));
            held = obj.isPrefetched(keys);
            for i = find(held)
                [values{i}, found(i)] = obj.getPartial(keys(i), offsets(i), lens(i));
            end
            if ~all(held)
                [values(~held), found(~held)] = obj.Inner.getPartialMany( ...
                    keys(~held), offsets(~held), lens(~held));
            end
        end

        function [data, found] = getSuffix(obj, key, len)
            if obj.isPrefetched(key)
                % The Store default takes the suffix from the value that
                % get returns.
                [data, found] = getSuffix@zarr.stores.Store(obj, key, len);
            else
                [data, found] = obj.Inner.getSuffix(key, len);
            end
        end

        function tf = exists(obj, key)
            if obj.isPrefetched(key)
                entry = obj.Prefetched(char(key));
                tf = entry.found;
            else
                tf = obj.Inner.exists(key);
            end
        end

        function set(obj, key, data)
            obj.forget(key);
            obj.Inner.set(key, data);
        end

        function erase(obj, key)
            obj.forget(key);
            obj.Inner.erase(key);
        end

        function keys = list(obj)
            keys = obj.Inner.list();
        end

        function [subdirs, files] = listDir(obj, prefix)
            [subdirs, files] = obj.Inner.listDir(prefix);
        end
    end

    methods (Access = private)
        function tf = isPrefetched(obj, keys)
            %ISPREFETCHED True for each of keys that has a prefetched value.
            tf = isKey(obj.Prefetched, cellstr(keys));
        end

        function forget(obj, key)
            if obj.isPrefetched(key)
                remove(obj.Prefetched, char(key));
            end
        end
    end
end
