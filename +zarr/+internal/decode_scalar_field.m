function values = decode_scalar_field(fieldBytes, fieldInfo, n, endian)
%DECODE_SCALAR_FIELD Decode n "structured" record field values from raw bytes.
%   fieldBytes is a fieldInfo.itemsize-by-n uint8 matrix (one column of raw
%   bytes per record). Returns an n-by-1 column (or n-by-1 struct array for
%   a nested "structured" field) of decoded values.
%
%   Decoding a whole field column at once, rather than one record at a
%   time, turns the n*numel(fields) scalar decode calls a naive per-record
%   loop would need into one call per field -- decode_structured relies on
%   this to stay fast on tables with many rows (e.g. NWB pixel_mask/
%   voxel_mask columns).
%
%   Shared by zarr.internal.decode_structured (each record's fields) and,
%   recursively, by a nested "structured" or "fixed_length_utf32" field.

    arguments
        fieldBytes (:,:) uint8
        fieldInfo (1,1) struct
        n (1,1) double {mustBeNonnegative, mustBeInteger}
        endian (1,1) string {mustBeMember(endian, ["little", "big"])} = "little"
    end

    if fieldInfo.isStructured
        values = zarr.internal.decode_structured(reshape(fieldBytes, 1, []), fieldInfo, n, endian);
        return
    end
    if fieldInfo.zarrType == "fixed_length_utf32"
        values = zarr.internal.decode_fixed_utf32(reshape(fieldBytes, 1, []), fieldInfo, n, endian);
        return
    end

    b = fieldBytes(:);
    switch true
        case fieldInfo.zarrType == "bool"
            values = logical(b);
        case fieldInfo.isFloat16
            u = typecast(b, 'uint16');
            if endian == "big", u = swapbytes(u); end
            values = zarr.internal.half2single(u);
        case fieldInfo.isComplex
            raw = typecast(b, char(fieldInfo.matlabClass));
            if endian == "big", raw = swapbytes(raw); end
            values = complex(raw(1:2:end), raw(2:2:end));
        otherwise
            values = typecast(b, char(fieldInfo.matlabClass));
            if endian == "big" && fieldInfo.itemsize > 1
                values = swapbytes(values);
            end
    end
    values = reshape(values, n, 1);
end
