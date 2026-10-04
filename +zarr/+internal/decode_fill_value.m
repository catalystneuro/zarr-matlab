function v = decode_fill_value(fillText, info)
%DECODE_FILL_VALUE fill_value JSON text -> MATLAB scalar.
%   fillText is the fill_value's source text in zarr.json, as
%   zarr.internal.json_object_entries returns it. Some values survive
%   only there: jsondecode goes through double for integers, renames
%   object keys that are not valid MATLAB identifiers, and the sign of a
%   negative-zero token is not something every number parser keeps. Each
%   field of a structured fill value is decoded from its own text the
%   same way.

fillText = strtrim(string(fillText));
if info.isStructured
    v = structuredFillValue(fillText, info);
    return
end
raw = jsondecode(char(fillText));
cls = char(info.matlabClass);
if info.zarrType == "string" || info.zarrType == "fixed_length_utf32"
    v = string(raw);
    return
elseif info.zarrType == "variable_length_bytes"
    if strlength(string(raw)) == 0
        v = uint8.empty(1, 0);
    else
        v = reshape(matlab.net.base64decode(char(string(raw))), 1, []);
    end
    return
end
if info.isComplex
    if iscell(raw)
        re = raw{1}; im = raw{2};
    else
        re = raw(1); im = raw(2);
    end
    v = complex(cast(scalarFloat(re, info.itemsize / 2, info), cls), ...
                cast(scalarFloat(im, info.itemsize / 2, info), cls));
elseif info.zarrType == "bool"
    v = logical(raw);
elseif startsWith(info.zarrType, "float")
    v = cast(scalarFloat(raw, info.itemsize, info), cls);
    if isnumeric(raw) && isscalar(raw) && raw == 0 && startsWith(fillText, "-")
        % "-0", "-0.0" and "-0e0" all mean negative zero.
        v = -abs(v);
    end
else  % integers
    if isnumeric(raw)
        v = cast(raw, cls);
        if ismember(info.matlabClass, ["int64", "uint64"]) && isscalar(raw) && abs(raw) >= 2^53 ...
                && ~isempty(regexp(fillText, '^-?\d+$', 'once'))
            % Values below 2^53 decode exactly, so only re-read the token
            % beyond that. Only pure integer literals parse exactly; other
            % numeric spellings (1e18, 9.1e15) keep the decoded value
            % rather than turning a readable file into a hard error.
            v = zarr.internal.parse_int64_token(char(fillText), info.matlabClass == "int64");
        end
    else
        v = cast(sscanf(char(string(raw)), '%ld'), cls);
    end
end
end

function x = scalarFloat(raw, nbytes, info)
if isnumeric(raw)
    x = double(raw);
    return
end
s = string(raw);
switch s
    case "NaN",       x = NaN;
    case "Infinity",  x = Inf;
    case "-Infinity", x = -Inf;
    otherwise
        if startsWith(s, "0x")
            bits = zarr.internal.hex2uint64(extractAfter(s, 2));
            switch nbytes
                case 2, x = double(zarr.internal.half2single(uint16(bits)));
                case 4, x = double(typecast(uint32(bits), 'single'));
                case 8, x = typecast(bits, 'double');
                otherwise
                    error("zarr:InvalidFillValue", ...
                        "Hex fill value not supported for %d-byte type.", nbytes);
            end
        else
            error("zarr:InvalidFillValue", ...
                "Cannot interpret fill value '%s' for data type '%s'.", s, info.zarrType);
        end
end
end

function v = structuredFillValue(fillText, info)
%STRUCTUREDFILLVALUE Fill value of a structured dtype, from its JSON text.
%   The canonical "struct" name writes the fill_value as an object of
%   per-field fill values; the legacy "structured" name writes a string,
%   base64 of the raw little-endian element bytes (little-endian
%   regardless of the array's configured codec endianness, which is not
%   yet known at metadata-parse time). zarr-python reads both under
%   either name, so accept both here. See zarr.internal.dtype_info.

if startsWith(fillText, "{")
    [names, valueTexts] = zarr.internal.json_object_entries(fillText);
    v = struct();
    for k = 1:numel(info.fields)
        f = info.fields(k);
        idx = find(names == f.Name, 1);
        if isempty(idx)
            % Absent from the object: fall back to the field's own default,
            % as zarr-python does.
            v.(f.MatlabName) = zarr.internal.default_scalar_fill_value(f.Info);
        else
            v.(f.MatlabName) = zarr.internal.decode_fill_value(valueTexts(idx), f.Info);
        end
    end
    return
end
if ~startsWith(fillText, """")
    error("zarr:InvalidFillValue", ...
        "The fill_value of a %s data type must be an object of field values " + ...
        "or a base64 string, not %s.", info.zarrType, fillText);
end
rawBytes = reshape(matlab.net.base64decode(jsondecode(char(fillText))), 1, []);
if numel(rawBytes) ~= info.itemsize
    error("zarr:InvalidFillValue", ...
        "The base64 fill_value of a %s data type holds %d bytes, but its " + ...
        "elements are %d bytes.", info.zarrType, numel(rawBytes), info.itemsize);
end
records = zarr.internal.decode_structured(rawBytes, info, 1, "little");
v = records(1);
end
