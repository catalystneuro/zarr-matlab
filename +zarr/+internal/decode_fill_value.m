function v = decode_fill_value(raw, info)
%DECODE_FILL_VALUE JSON fill_value (as returned by jsondecode) -> MATLAB scalar.

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
elseif info.isStructured
    v = structuredFillValue(raw, info);
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
else  % integers
    if isnumeric(raw)
        v = cast(raw, cls);
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

function v = structuredFillValue(raw, info)
%STRUCTUREDFILLVALUE Fill value of a structured dtype, in either form.
%   The canonical "struct" name writes the fill_value as an object of
%   per-field fill values, which jsondecode returns as a scalar struct;
%   the legacy "structured" name writes base64 of the raw little-endian
%   element bytes (little-endian regardless of the array's configured
%   codec endianness, which is not yet known at metadata-parse time).
%   zarr-python reads both under either name, so accept both here.
%   See zarr.internal.dtype_info.

if isstruct(raw)
    v = struct();
    for k = 1:numel(info.fields)
        f = info.fields(k);
        [fieldRaw, found] = lookupField(raw, f.Name);
        if found
            v.(f.Name) = zarr.internal.decode_fill_value(fieldRaw, f.Info);
        else
            % Absent from the object: fall back to the field's own default,
            % as zarr-python does.
            v.(f.Name) = zarr.internal.default_scalar_fill_value(f.Info);
        end
    end
    return
end
rawBytes = reshape(matlab.net.base64decode(char(string(raw))), 1, []);
records = zarr.internal.decode_structured(rawBytes, info, 1, "little");
v = records(1);
end

function [value, found] = lookupField(raw, name)
%LOOKUPFIELD One field of a decoded fill_value object, if it has one.
%   jsondecode renames JSON keys that are not valid MATLAB identifiers, so
%   fall back to the same mangling before reporting the field absent.

found = true;
if isfield(raw, name)
    value = raw.(name);
    return
end
mangled = matlab.lang.makeValidName(name);
if isfield(raw, mangled)
    value = raw.(mangled);
    return
end
value = [];
found = false;
end
