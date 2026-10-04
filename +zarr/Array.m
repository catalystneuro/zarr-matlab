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
        % pipelineCache - Codec pipeline, built when the array is opened.
        % An array whose chain holds a codec zarr-matlab does not implement
        % opens without one, and codecPipeline raises zarr:UnsupportedCodec
        % when its data is read or written.
        pipelineCache = []
        info
    end

    properties (Constant, Access = private)
        % ChunkBatchSize - Chunks read fetches through one getMany call.
        ChunkBatchSize = 64
    end

    methods
        function obj = Array(store, path, meta)
            obj.store = store;
            obj.path = zarr.internal.normalize_path(path);
            obj.meta = meta;
            obj.info = zarr.internal.dtype_info(meta.dataType, meta.dataTypeConfig);
            if isempty(zarr.internal.find_unsupported_codec(meta.codecs))
                obj.pipelineCache = obj.codecPipeline();
            end
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
            sh = obj.codecPipeline().soleSharding();
            if ~isempty(sh)
                for t = 1:numel(parts)
                    out = obj.readFromShard(sh, obj.chunkStoreKey(parts(t).coords), parts(t), out);
                end
                return
            end

            % Chunks are fetched a batch at a time through getMany, which a
            % store such as HttpStore serves with concurrent requests. The
            % batch bounds how many encoded chunks are held at once.
            for first = 1:obj.ChunkBatchSize:numel(parts)
                batch = parts(first:min(first + obj.ChunkBatchSize - 1, numel(parts)));
                keys = strings(1, numel(batch));
                for t = 1:numel(batch)
                    keys(t) = obj.chunkStoreKey(batch(t).coords);
                end
                [encoded, found] = obj.store.getMany(keys);
                for t = find(found)  % absent chunks keep the fill value
                    p = batch(t);
                    chunk = obj.codecPipeline().decode(encoded{t});
                    encoded{t} = [];
                    src = subsFor(p.inStart, p.inCount);
                    dst = subsFor(p.outStart, p.inCount);
                    out(dst{:}) = chunk(src{:});
                end
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
                        chunk = obj.codecPipeline().decode(bytes);
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
                    obj.store.set(key, obj.codecPipeline().encode(chunk));
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
            sh = [];
            if ~isempty(obj.pipelineCache)
                sh = obj.pipelineCache.soleSharding();
            end
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
            subscripts = indexOp(1).Indices;
            [idx, flatAll] = obj.resolveIndices(subscripts);
            if flatAll
                out = obj.read();
                out = out(:);
            elseif isempty(idx)  % rank 0: z()
                out = obj.read();
            elseif any(cellfun(@isempty, idx))
                out = zarr.internal.fill_array(obj.meta.fillValue, ...
                    emptySelectionSize(subscripts, idx, numel(obj)), obj.info);
            else
                R = numel(obj.meta.shape);
                first = cellfun(@min, idx(1:R));
                last = cellfun(@max, idx(1:R));
                block = obj.read(first, last - first + 1);
                rel = idx;  % subscripts beyond the rank index singleton dimensions of block
                rel(1:R) = cellfun(@(v, f) v - f + 1, idx(1:R), num2cell(first), 'UniformOutput', false);
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

            counts = cellfun(@numel, idx);
            if isscalar(value)
                value = repmat(value, zarr.internal.mshape(counts));
            elseif numel(value) ~= prod(counts)
                error("zarr:ShapeMismatch", ...
                    "Assignment value has %d elements; index selects %d.", numel(value), prod(counts));
            end
            if any(counts == 0)
                return  % the subscripts select no elements, so there is nothing to write
            end
            value = reshape(value, zarr.internal.mshape(counts));

            contiguous = all(cellfun(@(v) isequal(v, v(1):v(end)), idx));
            first = cellfun(@min, idx(1:R));
            if contiguous
                obj.write(value, first);
            else
                last = cellfun(@max, idx(1:R));
                block = obj.read(first, last - first + 1);
                rel = idx;  % subscripts beyond the rank index singleton dimensions of block
                rel(1:R) = cellfun(@(v, f) v - f + 1, idx(1:R), num2cell(first), 'UniformOutput', false);
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
        function p = codecPipeline(obj)
            %CODECPIPELINE The array's codec pipeline, built on first use.
            if isempty(obj.pipelineCache)
                obj.pipelineCache = zarr.codecs.Pipeline(obj.meta.codecs, obj.info, ...
                    obj.meta.chunkShape, obj.meta.fillValue);
            end
            p = obj.pipelineCache;
        end

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
            %RESOLVEINDICES Index vectors for paren subscripts, one per subscript.
            %   Subscripts address the MATLAB size of the array (see size);
            %   every dimension beyond that size has length 1. An index
            %   vector is empty when its subscript selects nothing.
            R = numel(obj.meta.shape);
            N = numel(raw);
            idx = {};
            flatAll = false;
            if N == 0 && R == 0
                return
            end
            if N == 1 && R >= 2
                if iscolon(raw{1})
                    flatAll = true;
                    return
                end
                error("zarr:Indexing", ...
                    "Linear indexing is not supported (except z(:)); use %d subscripts.", R);
            end
            if N < R
                error("zarr:Indexing", ...
                    "Expected at least %d subscripts for a rank-%d array, got %d.", R, R, N);
            end
            extent = zarr.internal.mshape(obj.meta.shape);
            extent = [extent, ones(1, N - numel(extent))];
            idx = cell(1, N);
            for d = 1:N
                v = raw{d};
                if iscolon(v)
                    idx{d} = 1:extent(d);
                else
                    if islogical(v)
                        v = find(v);
                    end
                    v = reshape(double(v), 1, []);
                    if any(v < 1) || any(v > extent(d)) || any(v ~= floor(v))
                        error("zarr:Indexing", ...
                            "Subscript %d out of bounds for dimension of size %d.", d, extent(d));
                    end
                    idx{d} = v;
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
                out = obj.codecPipeline().decode(bytes);
            else
                out = obj.meta.fillValue;
            end
        end

        function writeScalar(obj, data)
            obj.store.set(obj.chunkStoreKey([]), obj.codecPipeline().encode(obj.coerce(data)));
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
            elseif obj.info.isStructured
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

function sz = emptySelectionSize(subscripts, idx, numElements)
%EMPTYSELECTIONSIZE Size of the result when subscripts select no elements.
%   Follows MATLAB indexing of an in-memory array. Two or more subscripts
%   give one dimension per subscript. A single subscript indexes the
%   numElements-by-1 array linearly: the result is a column when the
%   subscript is a vector and the array is not a scalar, and has the shape
%   of the subscript otherwise.
if ~isscalar(subscripts)
    sz = cellfun(@numel, idx);
    return
end
subscript = subscripts{1};
if islogical(subscript)
    subscript = find(subscript);  % a mask selects as the indices of its true elements do
end
if iscolon(subscript) || (isvector(subscript) && numElements ~= 1)
    sz = [0 1];
else
    sz = size(subscript);
end
end
