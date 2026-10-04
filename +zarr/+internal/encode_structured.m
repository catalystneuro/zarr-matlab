function bytes = encode_structured(records, info, endian)
%ENCODE_STRUCTURED Encode n "structured" (compound record) elements as raw bytes.
%   records is an n-by-1 (or 1-by-n) struct array with one field per
%   info.fields entry (info.fields(k).MatlabName).
%
%   Encodes one field at a time across all n records (via
%   zarr.internal.encode_scalar_field), rather than looping record by
%   record -- for a table with many rows this cuts the scalar encode calls
%   from n*numel(fields) down to numel(fields).
%
%   "structured" is not part of the Zarr v3 specification -- see
%   zarr.internal.dtype_info.

    arguments
        records struct
        info (1,1) struct
        endian (1,1) string {mustBeMember(endian, ["little", "big"])} = "little"
    end

    records = reshape(records, [], 1);
    n = numel(records);
    if n == 0
        bytes = zeros(1, 0, 'uint8');
        return
    end

    b = zeros(info.itemsize, n, 'uint8');
    for k = 1:numel(info.fields)
        f = info.fields(k);
        values = reshape([records.(f.MatlabName)], n, 1);
        b(f.Offset + 1 : f.Offset + f.Info.itemsize, :) = zarr.internal.encode_scalar_field(values, f.Info, n, endian);
    end
    bytes = reshape(b, 1, []);
end
