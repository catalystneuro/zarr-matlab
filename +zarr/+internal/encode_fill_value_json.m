function txt = encode_fill_value_json(v, info)
%ENCODE_FILL_VALUE_JSON MATLAB scalar -> JSON text for the fill_value field.

if info.zarrType == "string" || info.zarrType == "fixed_length_utf32"
    if ismissing(v), v = ""; end
    txt = string(jsonencode(char(v)));
elseif info.zarrType == "variable_length_bytes"
    txt = """" + string(matlab.net.base64encode(uint8(v(:)'))) + """";
elseif info.isStructured
    txt = structuredFillValueJson(v, info);
elseif info.isComplex
    txt = "[" + floatJson(real(double(v))) + "," + floatJson(imag(double(v))) + "]";
elseif info.zarrType == "bool"
    if logical(v), txt = "true"; else, txt = "false"; end
elseif startsWith(info.zarrType, "float")
    txt = floatJson(double(v));
elseif startsWith(info.zarrType, "uint")
    txt = string(sprintf('%u', uint64(v)));
else  % signed integers
    txt = string(sprintf('%d', int64(v)));
end
end

function s = floatJson(x)
if isnan(x)
    s = """NaN""";
elseif isinf(x)
    if x > 0, s = """Infinity"""; else, s = """-Infinity"""; end
else
    s = string(sprintf('%.17g', x));
end
end

function txt = structuredFillValueJson(v, info)
%STRUCTUREDFILLVALUEJSON fill_value text, in the form its name uses.
%   The canonical "struct" name writes an object of per-field fill values;
%   the legacy "structured" name writes base64 of the raw little-endian
%   element bytes. See zarr.internal.decode_fill_value, which reads both.

if info.zarrType == "structured"
    bytes = zarr.internal.encode_structured(v, info, "little");
    txt = """" + string(matlab.net.base64encode(bytes)) + """";
    return
end
parts = strings(1, numel(info.fields));
for k = 1:numel(info.fields)
    f = info.fields(k);
    parts(k) = string(jsonencode(char(f.Name))) + ":" + ...
        zarr.internal.encode_fill_value_json(v.(f.Name), f.Info);
end
txt = "{" + strjoin(parts, ",") + "}";
end
