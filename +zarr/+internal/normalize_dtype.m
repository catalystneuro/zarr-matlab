function z = normalize_dtype(name)
%NORMALIZE_DTYPE Accept MATLAB class names or Zarr names; return Zarr data_type.

name = string(name);
switch name
    case {"logical", "bool"},   z = "bool";
    case {"double", "float64"}, z = "float64";
    case {"single", "float32"}, z = "float32";
    case "float16",             z = "float16";
    case {"int8","int16","int32","int64","uint8","uint16","uint32","uint64"}
        z = name;
    case {"complex64", "complex128"}
        z = name;
    case "string"
        z = "string";
    case {"bytes", "variable_length_bytes"}
        z = "variable_length_bytes";
    case {"struct", "structured", "fixed_length_utf32"}
        % Named without a configuration, which these cannot do without.
        % Pass them through so zarr.internal.dtype_info reports precisely
        % what the configuration is missing.
        z = name;
    otherwise
        error("zarr:UnsupportedDataType", ...
            "Unsupported data type '%s'. Use a MATLAB class name (e.g. 'double') or a Zarr v3 data_type (e.g. 'float64').", name);
end
end
