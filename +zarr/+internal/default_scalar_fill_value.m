function fillValue = default_scalar_fill_value(info)
%DEFAULT_SCALAR_FILL_VALUE Zero/empty-valued default for a scalar dtype.
%   Shared by zarr.codecs.Pipeline (whole-array default FillValue) and
%   zarr.internal.default_structured_fill_value (per-field default within a
%   "structured" record).

    arguments
        info (1,1) struct
    end

    if info.zarrType == "bool"
        fillValue = false;
    elseif info.zarrType == "string" || info.zarrType == "fixed_length_utf32"
        fillValue = "";
    elseif info.zarrType == "variable_length_bytes"
        fillValue = uint8.empty(1, 0);
    elseif info.isStructured
        fillValue = zarr.internal.default_structured_fill_value(info);
    elseif info.isComplex
        fillValue = complex(cast(0, char(info.matlabClass)));
    else
        fillValue = cast(0, char(info.matlabClass));
    end
end
