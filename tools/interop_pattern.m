function A = interop_pattern(shape, dtype)
%INTEROP_PATTERN MATLAB mirror of tools/interop_cases.py pattern().

n = prod(shape);  % prod([]) == 1 for rank 0
base = mod(0:n - 1, 251);
if isstruct(dtype)
    info = zarr.internal.dtype_info(dtype);
elseif contains(dtype, "datetime64") || contains(dtype, "timedelta64")
    % numpy extension dtypes: exact int64 ticks in MATLAB
    info = struct('zarrType', "int64_ticks", 'matlabClass', "int64", ...
        'isComplex', false, 'isVlen', false);
else
    info = zarr.internal.dtype_info(zarr.internal.normalize_dtype(dtype));
end
cls = char(info.matlabClass);
if info.zarrType == "int64_ticks"
    v = int64(base);
elseif info.isStructured
    v = structPattern(info, base);
elseif info.zarrType == "string"
    v = "s" + string(base);
elseif info.zarrType == "variable_length_bytes"
    v = arrayfun(@(x) uint8(0:mod(x, 5) - 1), base, 'UniformOutput', false);
elseif info.zarrType == "bool"
    v = logical(mod(base, 2));
elseif info.isComplex
    v = complex(cast(base / 4, cls), cast(base / 4 + 0.5, cls));
elseif startsWith(info.zarrType, "float")
    v = cast(base / 4, cls);
else
    v = cast(base, cls);
end
R = numel(shape);
if R >= 2
    A = permute(reshape(v, flip(reshape(shape, 1, []))), R:-1:1);  % C-order fill
elseif R == 1
    A = v(:);
else
    A = v;
end
end

function records = structPattern(info, base)
%STRUCTPATTERN Mirror of _struct_pattern in tools/interop_cases.py.
args = cell(1, 2 * numel(info.fields));
for k = 1:numel(info.fields)
    f = info.fields(k);
    if f.Info.isStructured
        values = structPattern(f.Info, base);
    elseif f.Info.zarrType == "fixed_length_utf32"
        values = "s" + string(base);
    elseif startsWith(f.Info.zarrType, "float")
        values = cast(base / 4, char(f.Info.matlabClass));
    else
        values = cast(base, char(f.Info.matlabClass));
    end
    args{2 * k - 1} = char(f.Name);
    args{2 * k} = num2cell(values);
end
records = struct(args{:});
end
