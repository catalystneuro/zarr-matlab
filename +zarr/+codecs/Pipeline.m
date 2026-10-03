classdef Pipeline
    %PIPELINE An ordered, validated Zarr v3 codec chain for one array.

    properties (SetAccess = immutable)
        codecs cell          % array_array*, then one array_bytes, then bytes_bytes*
        info                 % dtype_info struct
        chunkShape (1,:) double
        fillValue            % scalar fill value (used by sharding for missing inner chunks)
    end

    properties (Access = private)
        abIndex (1,1) double            % position of the array->bytes codec
        shapes cell                     % chunk shape seen by codec i (pre-encode)
    end

    methods
        function obj = Pipeline(codecs, info, chunkShape, fillValue)
            if nargin < 4
                fillValue = zarr.internal.default_scalar_fill_value(info);
            end
            unsupported = zarr.internal.find_unsupported_codec(codecs);
            if ~isempty(unsupported)
                unsupported.throwUnsupported();
            end
            obj.info = info;
            obj.chunkShape = reshape(chunkShape, 1, []);
            obj.fillValue = fillValue;

            kinds = strings(1, numel(codecs));
            for i = 1:numel(codecs)
                kinds(i) = codecs{i}.kind;
            end
            ab = find(kinds == "array_bytes");
            if numel(ab) ~= 1
                error("zarr:InvalidMetadata", ...
                    "Codec chain must contain exactly one array->bytes codec (found %d).", numel(ab));
            end
            if any(kinds(1:ab - 1) ~= "array_array") || any(kinds(ab + 1:end) ~= "bytes_bytes")
                error("zarr:InvalidMetadata", ...
                    "Codec chain must be array->array codecs, then one array->bytes codec, then bytes->bytes codecs.");
            end
            obj.abIndex = ab;

            % Chunk shape as seen by each codec up to and including array->bytes.
            obj.shapes = cell(1, ab);
            s = obj.chunkShape;
            for i = 1:ab - 1
                obj.shapes{i} = s;
                s = codecs{i}.shapeTransform(s);
            end
            obj.shapes{ab} = s;

            % Let stateful array->bytes codecs (sharding) precompute geometry.
            if ismethod(codecs{ab}, 'bind')
                codecs{ab} = codecs{ab}.bind(info, s, fillValue);
            end
            obj.codecs = codecs;
        end

        function bytes = encode(obj, A)
            for i = 1:obj.abIndex - 1
                [A, ~] = obj.codecs{i}.encode(A, obj.shapes{i});
            end
            bytes = obj.codecs{obj.abIndex}.encode(A, obj.info, obj.shapes{obj.abIndex});
            for i = obj.abIndex + 1:numel(obj.codecs)
                bytes = obj.codecs{i}.encode(bytes);
            end
        end

        function A = decode(obj, bytes)
            for i = numel(obj.codecs):-1:obj.abIndex + 1
                bytes = obj.codecs{i}.decode(bytes);
            end
            A = obj.codecs{obj.abIndex}.decode(bytes, obj.info, ...
                obj.shapes{obj.abIndex}, obj.fillValue);
            for i = obj.abIndex - 1:-1:1
                A = obj.codecs{i}.decode(A, obj.shapes{i});
            end
        end

        function sh = soleSharding(obj)
            %SOLESHARDING The bound ShardingCodec if it is the entire chain
            %   (the partial-read fast path applies), otherwise [].
            if isscalar(obj.codecs) && isa(obj.codecs{1}, 'zarr.codecs.ShardingCodec')
                sh = obj.codecs{1};
            else
                sh = [];
            end
        end

        function txt = toJson(obj)
            entries = strings(1, numel(obj.codecs));
            for i = 1:numel(obj.codecs)
                entries(i) = obj.codecs{i}.configJson();
            end
            txt = "[" + strjoin(entries, ",") + "]";
        end
    end
end
