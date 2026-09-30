function records = decode_structured(bytes, info, n, endian)
%DECODE_STRUCTURED Decode n consecutive "structured" (compound record) elements.
%   bytes is a 1-by-(n*info.itemsize) uint8 vector. Returns an n-by-1
%   struct array with one field per info.fields entry (info.fields(k).MatlabName),
%   each holding that field's decoded scalar value.
%
%   Decodes one field at a time across all n records (via
%   zarr.internal.decode_scalar_field), rather than looping record by
%   record -- for a table with many rows this cuts the scalar decode calls
%   from n*numel(fields) down to numel(fields).
%
%   "structured" is not part of the Zarr v3 specification -- see
%   zarr.internal.dtype_info.

    arguments
        bytes (1,:) uint8
        info (1,1) struct
        n (1,1) double {mustBeNonnegative, mustBeInteger}
        endian (1,1) string {mustBeMember(endian, ["little", "big"])} = "little"
    end

    numFields = numel(info.fields);
    if numFields == 0
        records = repmat(struct(), n, 1);
        return
    end

    b = reshape(bytes, info.itemsize, n);  % one column of raw record bytes per record
    args = cell(1, 2 * numFields);
    for k = 1:numFields
        f = info.fields(k);
        fieldBytes = b(f.Offset + 1 : f.Offset + f.Info.itemsize, :);
        values = zarr.internal.decode_scalar_field(fieldBytes, f.Info, n, endian);
        args{2 * k - 1} = char(f.MatlabName);
        args{2 * k} = num2cell(reshape(values, n, 1));
    end
    records = struct(args{:});
end
