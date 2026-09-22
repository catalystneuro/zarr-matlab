classdef Array < handle & matlab.mixin.indexing.RedefinesParen
    %ARRAY A Zarr v3 array. Supports MATLAB paren indexing for region I/O.
    %
    %   Rank mapping: a rank-1 Zarr array is a MATLAB column vector; a rank-0
    %   (scalar) array reads as a MATLAB scalar. For rank >= 2 the logical
    %   shape matches the Zarr/Python shape exactly (no dimension flipping).

    properties (SetAccess = private)
        store
        path (1,1) string
        meta
    end

    properties
        % When false (default, matching zarr-python), chunks whose content is
        % entirely the fill value are not stored (and are deleted on
        % overwrite); readers see the fill value either way.
        writeEmptyChunks (1,1) logical = false
    end

    properties (Dependent)
        shape        % Zarr shape (row vector; [] for rank 0)
        dtype        % Zarr data_type string
        chunkShape
        attrs        % cell-valued dictionary of user attributes; look up with attrs{"name"}
        dimensionNames
    end

    properties (Access = private)
        pipeline
        info
    end

    methods
        function obj = Array(store, path, meta)
            obj.store = store;
            obj.path = zarr.internal.normalize_path(path);
            obj.meta = meta;
            obj.info = zarr.internal.dtype_info(meta.dataType, meta.dataTypeConfig);
            obj.pipeline = zarr.codecs.Pipeline(meta.codecs, obj.info, ...
                meta.chunkShape, meta.fillValue);
        end

        % ------------------------------------------------------------------
        % Dependent properties
        function s = get.shape(obj), s = obj.meta.shape; end
        function s = get.dtype(obj), s = obj.meta.dataType; end
        function s = get.chunkShape(obj), s = obj.meta.chunkShape; end
        function a = get.attrs(obj), a = obj.meta.attributes; end
        function d = get.dimensionNames(obj), d = obj.meta.dimensionNames; end

        % ------------------------------------------------------------------
        % Core region I/O (1-based start)
        function out = read(obj, start, count)
            R = numel(obj.meta.shape);
            if nargin < 2, start = ones(1, R); end
            if nargin < 3, count = obj.meta.shape - start + 1; end
            start = reshape(double(start), 1, []);
            count = reshape(double(count), 1, []);
            count(isinf(count)) = obj.meta.shape(isinf(count)) - start(isinf(count)) + 1;
            obj.validateRegion(start, count);

            if R == 0
                out = obj.readScalar();
                return
            end

            out = zarr.internal.fill_array(obj.meta.fillValue, ...
                zarr.internal.mshape(count), obj.info);
            parts = zarr.internal.chunk_intersections(start - 1, count, obj.meta.chunkShape);
            sh = obj.pipeline.soleSharding();
            for t = 1:numel(parts)
                p = parts(t);
                key = obj.chunkStoreKey(p.coords);
                if ~isempty(sh)
                    out = obj.readFromShard(sh, key, p, out);
                    continue
                end
                [bytes, found] = obj.store.get(key);
                if ~found
                    continue  % output is pre-filled with fill value
                end
                chunk = obj.pipeline.decode(bytes);
                src = subsFor(p.inStart, p.inCount);
                dst = subsFor(p.outStart, p.inCount);
                out(dst{:}) = chunk(src{:});
            end
        end

        function write(obj, data, start)
            R = numel(obj.meta.shape);
            if nargin < 3, start = ones(1, R); end
            start = reshape(double(start), 1, []);

            if R == 0
                obj.writeScalar(data);
                return
            end

            if R == 1
                % Warn only when flattening interleaves, i.e. 2+ non-singleton
                % dimensions; degenerate vectors like 1x1xN squeeze losslessly.
                if sum(size(data) > 1) > 1
                    warning("zarr:ShapeFlattened", ...
                        "Data with %d dimensions is being flattened to a column vector for a rank-1 array write.", ...
                        ndims(data));
                end
                count = numel(data);
                data = data(:);
            else
                count = size(data, 1:R);
                if numel(data) ~= prod(count)
                    error("zarr:ShapeMismatch", ...
                        "Data with %d dimensions cannot be written to a rank-%d array.", ndims(data), R);
                end
            end
            obj.validateRegion(start, count);
            data = obj.coerce(data);

            cs = obj.meta.chunkShape;
            parts = zarr.internal.chunk_intersections(start - 1, count, cs);
            for t = 1:numel(parts)
                p = parts(t);
                key = obj.chunkStoreKey(p.coords);
                srcSubs = subsFor(p.outStart, p.inCount);  % region within data
                coversChunk = all(p.inStart == 0 & p.inCount == cs);
                if coversChunk
                    chunk = reshape(data(srcSubs{:}), zarr.internal.mshape(cs));
                else
                    [bytes, found] = obj.store.get(key);
                    if found
                        chunk = obj.pipeline.decode(bytes);
                    else
                        chunk = zarr.internal.fill_array(obj.meta.fillValue, ...
                            zarr.internal.mshape(cs), obj.info);
                    end
                    dstSubs = subsFor(p.inStart, p.inCount);
                    chunk(dstSubs{:}) = data(srcSubs{:});
                end
                if ~obj.writeEmptyChunks && isequaln(chunk, ...
                        zarr.internal.fill_array(obj.meta.fillValue, size(chunk), obj.info))
                    obj.store.erase(key);
                else
                    obj.store.set(key, obj.pipeline.encode(chunk));
                end
            end
        end

        function resize(obj, newShape)
            %RESIZE Change the array shape. Chunks fully outside the new shape
            %   are deleted (matching zarr-python).
            newShape = reshape(double(newShape), 1, []);
            R = numel(obj.meta.shape);
            if numel(newShape) ~= R
                error("zarr:ShapeMismatch", "resize cannot change array rank.");
            end
            old = obj.meta.shape;
            obj.meta.shape = newShape;
            obj.writeMetadata();
            if any(newShape < old)
                obj.deleteOutOfBoundsChunks();
            end
        end

        function append(obj, data, dim)
            %APPEND Grow the array along dimension dim and write data at the end.
            R = numel(obj.meta.shape);
            if nargin < 3, dim = 1; end
            if R == 0
                error("zarr:ShapeMismatch", "Cannot append to a rank-0 array.");
            end
            if R == 1
                n = numel(data);
            else
                n = size(data, dim);
            end
            old = obj.meta.shape;
            newShape = old;
            newShape(dim) = old(dim) + n;
            obj.resize(newShape);
            start = ones(1, R);
            start(dim) = old(dim) + 1;
            obj.write(data, start);
        end

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

        % ------------------------------------------------------------------
        % MATLAB conveniences
        function varargout = size(obj, varargin)
            s = zarr.internal.mshape(obj.meta.shape);
            if nargin > 1
                dims = [varargin{:}];
                padded = [s, ones(1, max([dims, numel(s)]) - numel(s))];
                s = padded(dims);
            end
            if nargout <= 1
                varargout = {s};
            else
                so = [s, ones(1, max(0, nargout - numel(s)))];
                if nargout < numel(so)
                    so = [so(1:nargout - 1), prod(so(nargout:end))];
                end
                varargout = num2cell(so(1:nargout));
            end
        end

        function n = ndims(obj)
            n = numel(zarr.internal.mshape(obj.meta.shape));
        end

        function n = numel(obj)
            n = prod(zarr.internal.mshape(obj.meta.shape));
        end

        function ind = end(obj, k, n)
            s = size(obj);
            s = [s, ones(1, max(0, n - numel(s)))];
            if k < n
                ind = s(k);
            else
                ind = prod(s(k:end));
            end
        end

        function disp(obj)
            if isempty(obj.meta.shape)
                shapeStr = "scalar";
            else
                shapeStr = strjoin(string(obj.meta.shape), "x");
            end
            codecNames = cellfun(@(c) string(c.name), obj.meta.codecs);
            fprintf('  zarr.Array  %s  %s\n', shapeStr, obj.meta.dataType);
            fprintf('     path: /%s   store: %s\n', obj.path, class(obj.store));
            sh = obj.pipeline.soleSharding();
            if ~isempty(sh)
                fprintf('    shard: [%s]   chunk: [%s]\n', ...
                    strjoin(string(obj.meta.chunkShape), " "), ...
                    strjoin(string(sh.chunkShape), " "));
            elseif ~isempty(obj.meta.chunkShape)
                fprintf('    chunk: [%s]\n', strjoin(string(obj.meta.chunkShape), " "));
            end
            fprintf('   codecs: %s\n', strjoin(codecNames, " -> "));
            names = keys(obj.meta.attributes);
            if ~isempty(names)
                fprintf('    attrs: %s\n', strjoin(names, ", "));
            end
            if ~isempty(obj.meta.dimensionNames)
                dn = obj.meta.dimensionNames;
                dn(ismissing(dn)) = "~";
                fprintf('     dims: %s\n', strjoin(dn, ", "));
            end
        end
    end

    % ----------------------------------------------------------------------
    % Paren indexing
    methods (Access = protected)
        function varargout = parenReference(obj, indexOp)
            if numel(indexOp) > 1
                error("zarr:Indexing", ...
                    "Chained indexing on a zarr.Array is not supported; read into a variable first.");
            end
            [idx, flatAll] = obj.resolveIndices(indexOp(1).Indices);
            if flatAll
                out = obj.read();
                out = out(:);
            elseif isempty(idx)  % rank 0: z()
                out = obj.read();
            else
                first = cellfun(@min, idx);
                last = cellfun(@max, idx);
                block = obj.read(first, last - first + 1);
                rel = cellfun(@(v, f) v - f + 1, idx, num2cell(first), 'UniformOutput', false);
                out = block(rel{:});
            end
            varargout = {out};
        end

        function obj = parenAssign(obj, indexOp, varargin)
            if numel(indexOp) > 1
                error("zarr:Indexing", "Chained assignment on a zarr.Array is not supported.");
            end
            value = varargin{1};
            [idx, flatAll] = obj.resolveIndices(indexOp(1).Indices);
            R = numel(obj.meta.shape);

            if flatAll
                if isscalar(value)
                    value = repmat(obj.coerce(value), zarr.internal.mshape(obj.meta.shape));
                end
                obj.write(reshape(value, zarr.internal.mshape(obj.meta.shape)));
                return
            end
            if isempty(idx)  % rank 0
                obj.write(value);
                return
            end

            counts = cellfun(@numel, idx);
            if isscalar(value) && prod(counts) > 1
                value = repmat(value, zarr.internal.mshape(counts));
            elseif numel(value) ~= prod(counts)
                error("zarr:ShapeMismatch", ...
                    "Assignment value has %d elements; index selects %d.", numel(value), prod(counts));
            end
            value = reshape(value, zarr.internal.mshape(counts));

            contiguous = all(cellfun(@(v) isequal(v, v(1):v(end)), idx));
            first = cellfun(@min, idx);
            if contiguous
                obj.write(value, first);
            else
                last = cellfun(@max, idx);
                block = obj.read(first, last - first + 1);
                rel = cellfun(@(v, f) v - f + 1, idx, num2cell(first), 'UniformOutput', false);
                block(rel{:}) = value;
                obj.write(block, first);
            end
        end

        function n = parenListLength(~, ~, ~)
            n = 1;
        end

        function obj = parenDelete(varargin) %#ok<STOUT>
            error("zarr:Indexing", "Deleting elements of a zarr.Array is not supported.");
        end
    end

    methods (Static)
        function out = empty(varargin) %#ok<STOUT>
            error("zarr:Indexing", "zarr.Array does not support empty().");
        end
    end

    methods
        function out = cat(varargin) %#ok<STOUT>
            error("zarr:Indexing", "Concatenation of zarr.Array objects is not supported.");
        end
    end

    % ----------------------------------------------------------------------
    methods (Access = private)
        function key = metaStoreKey(obj)
            if strlength(obj.path) == 0
                key = "zarr.json";
            else
                key = obj.path + "/zarr.json";
            end
        end

        function key = chunkStoreKey(obj, coords)
            rel = obj.meta.chunkKey(coords);
            if strlength(obj.path) == 0
                key = rel;
            else
                key = obj.path + "/" + rel;
            end
        end

        function writeMetadata(obj)
            obj.store.set(obj.metaStoreKey(), unicode2native(char(obj.meta.toJsonText()), 'UTF-8'));
        end

        function validateRegion(obj, start, count)
            shape = obj.meta.shape;
            if numel(start) ~= numel(shape) || numel(count) ~= numel(shape)
                error("zarr:Indexing", ...
                    "Expected %d subscripts for a rank-%d array.", numel(shape), numel(shape));
            end
            if any(start < 1) || any(count < 0) || any(start + count - 1 > shape)
                error("zarr:Indexing", ...
                    "Requested region [%s]+[%s] is out of bounds for shape [%s]. Use resize/append to grow the array.", ...
                    num2str(start), num2str(count), num2str(shape));
            end
        end

        function [idx, flatAll] = resolveIndices(obj, raw)
            shape = obj.meta.shape;
            R = numel(shape);
            flatAll = false;
            if R == 0
                if ~isempty(raw)
                    error("zarr:Indexing", "A rank-0 array takes no subscripts: use z().");
                end
                idx = {};
                return
            end
            if numel(raw) == 1 && R ~= 1
                if iscolon(raw{1})
                    idx = {};
                    flatAll = true;
                    return
                end
                error("zarr:Indexing", ...
                    "Linear indexing is not supported (except z(:)); use %d subscripts.", R);
            end
            if numel(raw) ~= R
                error("zarr:Indexing", ...
                    "Expected %d subscripts for a rank-%d array, got %d.", R, R, numel(raw));
            end
            idx = cell(1, R);
            for d = 1:R
                v = raw{d};
                if iscolon(v)
                    idx{d} = 1:shape(d);
                elseif islogical(v)
                    idx{d} = reshape(find(v), 1, []);
                else
                    v = reshape(double(v), 1, []);
                    if any(v < 1) || any(v > shape(d)) || any(v ~= floor(v))
                        error("zarr:Indexing", ...
                            "Subscript %d out of bounds for dimension of size %d.", d, shape(d));
                    end
                    idx{d} = v;
                end
                if isempty(idx{d})
                    error("zarr:Indexing", "Empty subscripts are not supported.");
                end
            end
        end

        function out = readFromShard(obj, sh, key, p, out)
            %READFROMSHARD Partial shard read: fetch the index, then only the
            %   inner chunks that intersect the requested region.
            if sh.indexLocation == "start"
                [ib, found] = obj.store.getPartial(key, 0, sh.indexLen);
            else
                [ib, found] = obj.store.getSuffix(key, sh.indexLen);
            end
            if ~found
                return  % whole shard missing -> fill (already prefilled)
            end
            if numel(ib) < sh.indexLen
                error("zarr:CodecError", "Shard '%s' is smaller than its index.", key);
            end
            I = sh.indexPipeline.decode(ib);
            sentinel = intmax('uint64');

            innerParts = zarr.internal.chunk_intersections(p.inStart, p.inCount, sh.chunkShape);
            for k = 1:numel(innerParts)
                ip = innerParts(k);
                cSubs = num2cell(ip.coords + 1);
                off = I(cSubs{:}, 1);
                len = I(cSubs{:}, 2);
                if off == sentinel && len == sentinel
                    continue  % missing inner chunk -> fill
                end
                [cb, cbFound] = obj.store.getPartial(key, double(off), double(len));
                if ~cbFound || numel(cb) < double(len)
                    error("zarr:CodecError", "Shard '%s' is truncated.", key);
                end
                chunk = sh.innerPipeline.decode(cb);
                src = subsFor(ip.inStart, ip.inCount);
                dst = subsFor(p.outStart + ip.outStart, ip.inCount);
                out(dst{:}) = chunk(src{:});
            end
        end

        function out = readScalar(obj)
            [bytes, found] = obj.store.get(obj.chunkStoreKey([]));
            if found
                out = obj.pipeline.decode(bytes);
            else
                out = obj.meta.fillValue;
            end
        end

        function writeScalar(obj, data)
            obj.store.set(obj.chunkStoreKey([]), obj.pipeline.encode(obj.coerce(data)));
        end

        function data = coerce(obj, data)
            cls = char(obj.info.matlabClass);
            if obj.info.zarrType == "bool"
                data = logical(data);
            elseif obj.info.zarrType == "string" || obj.info.zarrType == "fixed_length_utf32"
                data = string(data);
            elseif obj.info.zarrType == "variable_length_bytes"
                if ~iscell(data)
                    error("zarr:TypeMismatch", ...
                        "variable_length_bytes arrays take cell arrays of uint8 vectors.");
                end
            elseif obj.info.zarrType == "structured"
                if ~isstruct(data)
                    error("zarr:TypeMismatch", ...
                        "structured arrays take a struct array with one field per record field.");
                end
            elseif ~isa(data, cls)
                data = cast(data, cls);
            end
        end

        function deleteOutOfBoundsChunks(obj)
            shape = obj.meta.shape;
            cs = obj.meta.chunkShape;
            maxChunk = max(ceil(shape ./ cs) - 1, 0);  % last valid chunk coord
            ks = obj.store.list();
            if strlength(obj.path) > 0
                pre = obj.path + "/";
                ks = ks(startsWith(ks, pre));
                rel = extractAfter(ks, strlength(pre));
            else
                rel = ks;
            end
            for i = 1:numel(rel)
                coords = obj.parseChunkKey(rel(i));
                if ~isempty(coords) && any(coords > maxChunk)
                    obj.store.erase(ks(i));
                end
            end
        end

        function coords = parseChunkKey(obj, rel)
            %PARSECHUNKKEY Chunk coords from a node-relative key, or [] if not a chunk.
            coords = [];
            sep = obj.meta.keySeparator;
            if obj.meta.keyEncoding == "default"
                if ~startsWith(rel, "c" + sep)
                    return
                end
                partsStr = split(extractAfter(rel, strlength("c" + sep)), sep);
            else
                partsStr = split(rel, sep);
            end
            vals = str2double(partsStr);
            if numel(vals) ~= numel(obj.meta.shape) || any(isnan(vals))
                return
            end
            coords = reshape(vals, 1, []);
        end
    end
end

function subs = subsFor(start0, count)
subs = arrayfun(@(s, c) s + 1:s + c, start0, count, 'UniformOutput', false);
if isscalar(subs)
    subs{end + 1} = 1;  % rank-1 arrays are column vectors
end
end

function tf = iscolon(v)
tf = (ischar(v) && isequal(v, ':')) || (isstring(v) && v == ":");
end
