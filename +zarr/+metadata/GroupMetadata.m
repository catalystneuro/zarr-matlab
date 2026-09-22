classdef GroupMetadata
    %GROUPMETADATA Parsed Zarr v3 group metadata (zarr.json).

    properties
        % Cell-valued dictionary so that attribute keys survive exactly;
        % assigning a struct converts it (see set.attributes).
        attributes = dictionary(string.empty, {})
        consolidated = []   % containers.Map: node path -> raw zarr.json text, or []
    end

    methods (Static)
        function obj = fromJsonText(txt)
            txt = char(txt);
            m = jsondecode(txt);
            if ~isfield(m, 'zarr_format') || m.zarr_format ~= 3
                error("zarr:InvalidMetadata", "Only zarr_format 3 is supported.");
            end
            if ~isfield(m, 'node_type') || ~strcmp(m.node_type, 'group')
                error("zarr:InvalidMetadata", "Expected node_type 'group'.");
            end
            obj = zarr.metadata.GroupMetadata();

            % Attributes and consolidated paths both carry keys jsondecode
            % would rename, so read both from the source text instead.
            [rk, rv] = zarr.internal.json_object_entries(txt);
            aIdx = find(rk == "attributes", 1);
            if ~isempty(aIdx)
                obj.attributes = zarr.internal.json_decode_exact(rv(aIdx));
            end
            if isfield(m, 'consolidated_metadata') && ~isempty(m.consolidated_metadata)
                cIdx = find(rk == "consolidated_metadata", 1);
                [ck, cv] = zarr.internal.json_object_entries(rv(cIdx));
                mIdx = find(ck == "metadata", 1);
                if ~isempty(mIdx)
                    [paths, texts] = zarr.internal.json_object_entries(cv(mIdx));
                    obj.consolidated = containers.Map('KeyType', 'char', 'ValueType', 'any');
                    for i = 1:numel(paths)
                        obj.consolidated(char(paths(i))) = texts(i);
                    end
                end
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
            txt = """zarr_format"":3,""node_type"":""group""";
            if numEntries(obj.attributes) > 0
                txt = txt + ",""attributes"":" + zarr.internal.json_encode_exact(obj.attributes);
            end
            if ~isempty(obj.consolidated)
                paths = sort(string(obj.consolidated.keys())');
                entries = strings(numel(paths), 1);
                for i = 1:numel(paths)
                    entries(i) = string(jsonencode(char(paths(i)))) + ":" + ...
                        string(obj.consolidated(char(paths(i))));
                end
                txt = txt + ",""consolidated_metadata"":{""kind"":""inline""," + ...
                    """must_understand"":false,""metadata"":{" + ...
                    strjoin(entries, ",") + "}}";
            end
            txt = "{" + txt + "}";
        end
    end
end
