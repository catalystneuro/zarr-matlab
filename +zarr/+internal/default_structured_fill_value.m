function fv = default_structured_fill_value(info)
%DEFAULT_STRUCTURED_FILL_VALUE Zero/empty-valued record for a "structured" dtype.
%   Used when a "structured" array is created without an explicit
%   FillValue, mirroring the zero-defaulting zarr.codecs.Pipeline already
%   does per-scalar-dtype.
%
%   "structured" is not part of the Zarr v3 specification -- see
%   zarr.internal.dtype_info.

    arguments
        info (1,1) struct
    end

    fv = struct();
    for k = 1:numel(info.fields)
        f = info.fields(k);
        fv.(f.MatlabName) = zarr.internal.default_scalar_fill_value(f.Info);
    end
end
