classdef ArrayMetadata
    %ARRAYMETADATA Parsed Zarr v3 array metadata (zarr.json).

    properties
        shape (1,:) double
        dataType (1,1) string
        dataTypeConfig = []   % extension dtype configuration struct, or []
        chunkShape (1,:) double
        keyEncoding (1,1) string {mustBeMember(keyEncoding, ["default", "v2"])} = "default"
        keySeparator (1,1) string = "/"
        fillValue
        codecs cell
        % Cell-valued dictionary so that attribute keys survive exactly;
        % assigning a struct converts it (see set.attributes).
        attributes = dictionary(string.empty, {})
        dimensionNames string = string.empty  % may contain missing for null
    end

    methods (Static)
        function obj = fromJsonText(txt)
            m = jsondecode(char(txt));
            if ~isfield(m, 'zarr_format') || m.zarr_format ~= 3
                error("zarr:InvalidMetadata", "Only zarr_format 3 is supported.");
            end
            if ~isfield(m, 'node_type') || ~strcmp(m.node_type, 'array')
                error("zarr:InvalidMetadata", "Expected node_type 'array'.");
            end
            if isfield(m, 'storage_transformers') && ~isempty(m.storage_transformers)
                error("zarr:UnsupportedFeature", "storage_transformers are not supported.");
            end

            obj = zarr.metadata.ArrayMetadata();
            obj.shape = reshape(m.shape, 1, []);
            if isstruct(m.data_type)  % extension dtype: {"name": ..., "configuration": ...}
                obj.dataType = string(m.data_type.name);
            else
                obj.dataType = string(m.data_type);
            end

            if ~strcmp(m.chunk_grid.name, 'regular')
                error("zarr:UnsupportedFeature", ...
                    "Unsupported chunk grid '%s'.", m.chunk_grid.name);
            end
            obj.chunkShape = reshape(m.chunk_grid.configuration.chunk_shape, 1, []);
            if numel(obj.chunkShape) ~= numel(obj.shape)
                error("zarr:InvalidMetadata", "chunk_shape rank does not match shape rank.");
            end

            if isfield(m, 'chunk_key_encoding')
                cke = m.chunk_key_encoding;
                obj.keyEncoding = string(cke.name);
                if obj.keyEncoding == "v2"
                    obj.keySeparator = ".";
                else
                    obj.keySeparator = "/";
                end
                if isfield(cke, 'configuration') && isfield(cke.configuration, 'separator')
                    obj.keySeparator = string(cke.configuration.separator);
                end
            end

            info = zarr.internal.dtype_info(m.data_type);
            obj.dataTypeConfig = info.config;
            obj.fillValue = zarr.internal.decode_fill_value(m.fill_value, info);
            if (info.matlabClass == "int64" || info.matlabClass == "uint64") ...
                    && ~info.isVlen && isnumeric(m.fill_value) ...
                    && isscalar(m.fill_value) && abs(m.fill_value) >= 2^53
                % jsondecode went through double and may have lost precision
                % beyond 2^53 (values below that are exact, so skip the
                % re-scan); re-extract the exact token. A regex over the
                % whole document could match a same-named key nested inside
                % "attributes", so tokenize top-level keys instead.
                [topKeys, topVals] = zarr.internal.json_object_entries(txt);
                idx = find(topKeys == "fill_value", 1);
                if ~isempty(idx)
                    tok = char(topVals(idx));
                    % Only pure integer literals parse exactly; other numeric
                    % spellings (1e18, 9.1e15) keep the decoded value rather
                    % than turning a readable file into a hard error.
                    if ~isempty(regexp(tok, '^-?\d+$', 'once'))
                        obj.fillValue = zarr.internal.parse_int64_token(tok, ...
                            info.matlabClass == "int64");
                    end
                end
            end

            entries = zarr.metadata.ArrayMetadata.asList(m.codecs);
            obj.codecs = cellfun(@zarr.codecs.from_config, entries, 'UniformOutput', false);

            % Attribute keys are read from the source text: jsondecode
            % renames any key that is not a valid MATLAB identifier.
            [attrKeys, attrVals] = zarr.internal.json_object_entries(txt);
            aIdx = find(attrKeys == "attributes", 1);
            if ~isempty(aIdx)
                obj.attributes = zarr.internal.json_decode_exact(attrVals(aIdx));
            end

            if isfield(m, 'dimension_names') && ~isempty(m.dimension_names)
                names = zarr.metadata.ArrayMetadata.asList(m.dimension_names);
                dn = strings(1, numel(names));
                for i = 1:numel(names)
                    if isempty(names{i})
                        dn(i) = missing;
                    else
                        dn(i) = string(names{i});
                    end
                end
                obj.dimensionNames = dn;
            end
        end

        function entries = asList(v)
            %ASLIST Normalize jsondecode output (cell / struct array / scalar) to a cell.
            if iscell(v)
                entries = reshape(v, 1, []);
            elseif isstruct(v)
                entries = num2cell(reshape(v, 1, []));
            else
                entries = num2cell(reshape(v, 1, []));
            end
        end
    end

    methods
        function obj = set.attributes(obj, value)
            % Accepts a dictionary or a scalar struct; always stores a
            % cell-valued dictionary, so callers can keep passing structs
            % for keys that are valid MATLAB identifiers.
            obj.attributes = zarr.internal.attribute_dictionary(value);
        end

        function txt = toJsonText(obj)
            info = zarr.internal.dtype_info(obj.dataType, obj.dataTypeConfig);
            pipeline = zarr.codecs.Pipeline(obj.codecs, info, obj.chunkShape);

            parts = strings(0, 1);
            parts(end + 1) = """zarr_format"":3";
            parts(end + 1) = """node_type"":""array""";
            parts(end + 1) = """shape"":" + jsonIntList(obj.shape);
            if isempty(obj.dataTypeConfig)
                parts(end + 1) = """data_type"":""" + obj.dataType + """";
            else
                parts(end + 1) = """data_type"":{""name"":""" + obj.dataType + ...
                    """,""configuration"":" + string(jsonencode(obj.dataTypeConfig)) + "}";
            end
            parts(end + 1) = """chunk_grid"":{""name"":""regular"",""configuration"":{""chunk_shape"":" + ...
                jsonIntList(obj.chunkShape) + "}}";
            parts(end + 1) = """chunk_key_encoding"":{""name"":""" + obj.keyEncoding + ...
                """,""configuration"":{""separator"":""" + obj.keySeparator + """}}";
            parts(end + 1) = """fill_value"":" + zarr.internal.encode_fill_value_json(obj.fillValue, info);
            parts(end + 1) = """codecs"":" + pipeline.toJson();
            if numEntries(obj.attributes) > 0
                parts(end + 1) = """attributes"":" + zarr.internal.json_encode_exact(obj.attributes);
            end
            if ~isempty(obj.dimensionNames)
                names = strings(1, numel(obj.dimensionNames));
                for i = 1:numel(obj.dimensionNames)
                    if ismissing(obj.dimensionNames(i))
                        names(i) = "null";
                    else
                        names(i) = string(jsonencode(char(obj.dimensionNames(i))));
                    end
                end
                parts(end + 1) = """dimension_names"":[" + strjoin(names, ",") + "]";
            end
            txt = "{" + strjoin(parts, ",") + "}";
        end

        function key = chunkKey(obj, coords)
            %CHUNKKEY Store key (relative to the node) for 0-based chunk coords.
            coords = reshape(coords, 1, []);
            if obj.keyEncoding == "default"
                if isempty(coords)
                    key = "c";
                else
                    key = strjoin(["c", compose("%d", coords)], obj.keySeparator);
                end
            else  % v2
                if isempty(coords)
                    key = "0";
                else
                    key = strjoin(compose("%d", coords), obj.keySeparator);
                end
            end
        end
    end
end

function s = jsonIntList(v)
if isempty(v)
    s = "[]";
else
    s = "[" + strjoin(compose("%d", reshape(v, 1, [])), ",") + "]";
end
end
