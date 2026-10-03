function fieldBytes = encode_scalar_field(values, fieldInfo, n, endian)
%ENCODE_SCALAR_FIELD Encode n "structured" record field values into raw bytes.
%   values is a 1-by-n (or n-by-1) array of one field's values, one per
%   record (numeric/logical/string, or an n-element struct array for a
%   nested "structured" field). Returns a fieldInfo.itemsize-by-n uint8
%   matrix, one column of raw bytes per record.
%
%   Encoding a whole field column at once, rather than one record at a
%   time, turns the n*numel(fields) scalar encode calls a naive per-record
%   loop would need into one call per field -- encode_structured relies on
%   this to stay fast on tables with many rows (e.g. NWB pixel_mask/
%   voxel_mask columns).
%
%   Shared by zarr.internal.encode_structured (each record's fields) and,
%   recursively, by a nested "structured" or "fixed_length_utf32" field.

    arguments
        values
        fieldInfo (1,1) struct
        n (1,1) double {mustBeNonnegative, mustBeInteger}
        endian (1,1) string {mustBeMember(endian, ["little", "big"])} = "little"
    end

    if fieldInfo.isStructured
        fieldBytes = reshape(zarr.internal.encode_structured(values, fieldInfo, endian), fieldInfo.itemsize, n);
        return
    end
    if fieldInfo.zarrType == "fixed_length_utf32"
        fieldBytes = reshape(zarr.internal.encode_fixed_utf32(string(values), fieldInfo, endian), fieldInfo.itemsize, n);
        return
    end

    values = reshape(values, 1, n);
    switch true
        case fieldInfo.zarrType == "bool"
            raw = uint8(values);
        case fieldInfo.isFloat16
            raw = zarr.internal.single2half(single(values));
        case fieldInfo.isComplex
            raw = zeros(1, 2 * n, char(fieldInfo.matlabClass));
            raw(1:2:end) = real(values);
            raw(2:2:end) = imag(values);
        otherwise
            raw = cast(values, char(fieldInfo.matlabClass));
    end
    if endian == "big" && fieldInfo.itemsize > 1
        raw = swapbytes(raw);
    end
    fieldBytes = reshape(typecast(raw, 'uint8'), fieldInfo.itemsize, n);
end
