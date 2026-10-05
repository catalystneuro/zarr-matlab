classdef (Abstract) Store < handle
    %STORE Abstract key/value store backing a Zarr hierarchy.
    %   Keys are '/'-separated strings; values are uint8 row vectors.

    methods (Abstract)
        [data, found] = get(obj, key)
        tf = exists(obj, key)
        set(obj, key, data)
        erase(obj, key)
        keys = list(obj)                    % all keys, string column
        [subdirs, files] = listDir(obj, prefix)  % immediate children of prefix
    end

    methods
        function [values, found] = getMany(obj, keys)
            %GETMANY Read several values: one get per key, in order.
            %   [values, found] = getMany(obj, keys) returns a cell row of
            %   values and a logical row, one entry per key of the string
            %   array keys. Stores that can fetch values concurrently
            %   override it (see zarr.stores.HttpStore).
            keys = reshape(string(keys), 1, []);
            values = cell(1, numel(keys));
            found = false(1, numel(keys));
            for i = 1:numel(keys)
                [values{i}, found(i)] = obj.get(keys(i));
            end
        end

        function [values, found] = getPartialMany(obj, keys, offsets, lens)
            %GETPARTIALMANY Byte-range reads of several values: one getPartial per key, in order.
            %   [values, found] = getPartialMany(obj, keys, offsets, lens)
            %   reads lens(i) bytes at the 0-based offsets(i) of keys(i), and
            %   returns a cell row of values and a logical row, one entry per
            %   key. Stores that can read ranges concurrently override it
            %   (see zarr.stores.HttpStore).
            keys = reshape(string(keys), 1, []);
            values = cell(1, numel(keys));
            found = false(1, numel(keys));
            for i = 1:numel(keys)
                [values{i}, found(i)] = obj.getPartial(keys(i), offsets(i), lens(i));
            end
        end

        function [data, found] = getPartial(obj, key, offset, len)
            %GETPARTIAL Byte-range read: len bytes starting at 0-based offset.
            %   Default falls back to a full read; subclasses override with a
            %   true ranged read where possible (required for efficient
            %   sharding).
            [full, found] = obj.get(key);
            if ~found
                data = uint8([]);
                return
            end
            first = offset + 1;
            last = min(offset + len, numel(full));
            data = full(first:last);
        end

        function [data, found] = getSuffix(obj, key, len)
            %GETSUFFIX Read the last len bytes of a value (shard index at "end").
            [full, found] = obj.get(key);
            if ~found
                data = uint8([]);
                return
            end
            data = full(max(1, numel(full) - len + 1):end);
        end
    end
end
