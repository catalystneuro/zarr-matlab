classdef Group < handle
    %GROUP A Zarr v3 group.

    properties (SetAccess = private)
        store
        path (1,1) string
        meta
    end

    properties (Dependent)
        attrs   % cell-valued dictionary of user attributes; look up with attrs{"name"}
    end

    methods
        function obj = Group(store, path, meta)
            obj.store = store;
            obj.path = zarr.internal.normalize_path(path);
            obj.meta = meta;
        end

        function a = get.attrs(obj), a = obj.meta.attributes; end

        function setAttr(obj, name, value)
            %SETATTR Set one attribute. name is written exactly as given,
            %   so it may be any JSON key ("_DTYPE", "chunk size").
            arguments
                obj
                name (1,1) string
                value
            end
            obj.meta.attributes(name) = {value};
            obj.writeMetadata();
        end

        function setAttrs(obj, s)
            %SETATTRS Replace all attributes with a dictionary or scalar struct.
            obj.meta.attributes = s;
            obj.writeMetadata();
        end

        function node = item(obj, name)
            %ITEM Open a child array or group by name (or nested path).
            %   Uses consolidated metadata when this group carries it (no
            %   extra store reads); falls back to the store otherwise.
            rel = zarr.internal.normalize_path(name);
            full = obj.childPath(name);
            if ~isempty(obj.meta.consolidated) && obj.meta.consolidated.isKey(char(rel))
                txt = obj.meta.consolidated(char(rel));
                m = jsondecode(char(txt));
                if strcmp(m.node_type, 'array')
                    node = zarr.Array(obj.store, full, ...
                        zarr.metadata.ArrayMetadata.fromJsonText(txt));
                else
                    gm = zarr.metadata.GroupMetadata.fromJsonText(txt);
                    gm.consolidated = obj.sliceConsolidated(rel);
                    node = zarr.Group(obj.store, full, gm);
                end
                return
            end
            node = zarr.open(obj.store, Path=full);
        end

        function tf = isKey(obj, name)
            rel = zarr.internal.normalize_path(name);
            if ~isempty(obj.meta.consolidated)
                tf = obj.meta.consolidated.isKey(char(rel));
                return
            end
            tf = obj.store.exists(obj.childPath(name) + "/zarr.json");
        end

        function [arrayNames, groupNames] = children(obj)
            arrayNames = string.empty(0, 1);
            groupNames = string.empty(0, 1);
            if ~isempty(obj.meta.consolidated)
                paths = string(obj.meta.consolidated.keys())';
                direct = paths(~contains(paths, "/"));
                for i = 1:numel(direct)
                    m = jsondecode(char(obj.meta.consolidated(char(direct(i)))));
                    if strcmp(m.node_type, 'array')
                        arrayNames(end + 1, 1) = direct(i); %#ok<AGROW>
                    else
                        groupNames(end + 1, 1) = direct(i); %#ok<AGROW>
                    end
                end
                return
            end
            [subdirs, ~] = obj.store.listDir(obj.path);
            for i = 1:numel(subdirs)
                key = obj.childPath(subdirs(i)) + "/zarr.json";
                [bytes, found] = obj.store.get(key);
                if ~found
                    continue
                end
                m = jsondecode(native2unicode(bytes, 'UTF-8'));
                if strcmp(m.node_type, 'array')
                    arrayNames(end + 1, 1) = subdirs(i); %#ok<AGROW>
                else
                    groupNames(end + 1, 1) = subdirs(i); %#ok<AGROW>
                end
            end
        end

        function z = createArray(obj, name, shape, dtype, opts)
            arguments
                obj
                name (1,1) string
                shape (1,:) double
                dtype (1,1) string = "double"
                opts.ChunkShape = []
                opts.ShardShape = []
                opts.IndexLocation (1,1) string = "end"
                opts.FillValue = []
                opts.Codecs = {}
                opts.Attributes = struct()
                opts.DimensionNames = string.empty
                opts.Order (1,1) string = "C"
                opts.Overwrite (1,1) logical = false
            end
            args = namedargs2cell(opts);
            z = zarr.create(obj.store, shape, dtype, args{:}, Path=obj.childPath(name));
        end

        function g = createGroup(obj, name, opts)
            arguments
                obj
                name (1,1) string
                opts.Attributes = struct()
            end
            g = zarr.create_group(obj.store, Path=obj.childPath(name), ...
                Attributes=opts.Attributes);
        end

        function disp(obj)
            fprintf('  zarr.Group  /%s   store: %s\n', obj.path, class(obj.store));
            names = keys(obj.meta.attributes);
            if ~isempty(names)
                fprintf('    attrs: %s\n', strjoin(names, ", "));
            end
            try
                [an, gn] = obj.children();
                for i = 1:numel(gn)
                    fprintf('    %s/\n', gn(i));
                end
                for i = 1:numel(an)
                    fprintf('    %s\n', an(i));
                end
            catch
                fprintf('    (children unavailable: store is not listable)\n');
            end
        end

        function tree(obj, maxDepth)
            %TREE Print the hierarchy below this group.
            if nargin < 2, maxDepth = Inf; end
            fprintf('/%s\n', obj.path);
            obj.printTree("", 1, maxDepth);
        end
    end

    methods (Access = private)
        function printTree(obj, indent, depth, maxDepth)
            [an, gn] = obj.children();
            for i = 1:numel(an)
                node = obj.item(an(i));
                fprintf('%s|- %s  [%s] %s\n', indent, an(i), ...
                    strjoin(string(node.shape), " "), node.dtype);
            end
            for i = 1:numel(gn)
                fprintf('%s|- %s/\n', indent, gn(i));
                if depth < maxDepth
                    sub = obj.item(gn(i));
                    sub.printTree(indent + "|  ", depth + 1, maxDepth);
                end
            end
        end
    end

    methods (Access = private)
        function sliced = sliceConsolidated(obj, prefix)
            %SLICECONSOLIDATED Consolidated entries under prefix, re-keyed
            %   relative to it (so child groups keep the fast path).
            sliced = containers.Map('KeyType', 'char', 'ValueType', 'any');
            paths = string(obj.meta.consolidated.keys())';
            pre = prefix + "/";
            for i = 1:numel(paths)
                if startsWith(paths(i), pre)
                    sliced(char(extractAfter(paths(i), strlength(pre)))) = ...
                        obj.meta.consolidated(char(paths(i)));
                end
            end
            if sliced.Count == 0
                sliced = [];
            end
        end

        function p = childPath(obj, name)
            name = zarr.internal.normalize_path(name);
            if strlength(obj.path) == 0
                p = name;
            else
                p = obj.path + "/" + name;
            end
        end

        function writeMetadata(obj)
            if strlength(obj.path) == 0
                key = "zarr.json";
            else
                key = obj.path + "/zarr.json";
            end
            obj.store.set(key, unicode2native(char(obj.meta.toJsonText()), 'UTF-8'));
        end
    end
end
