function mustBeDataType(dtype)
%MUSTBEDATATYPE Validate a dtype argument: one data type name or one data_type struct.
%   mustBeDataType(dtype) returns when dtype is a string scalar or a
%   character row vector, either of which names a data type, or a scalar
%   struct, which gives a data_type in the {name, configuration} shape it
%   has in zarr.json. Anything else raises zarr:UnsupportedDataType.
%
%   Whether the name is a supported data type, and whether the struct has
%   both fields, is checked where zarr.create resolves the data type.
%
%   Used as an argument validator by zarr.create and Group.createArray.

isName = isStringScalar(dtype) || (ischar(dtype) && isrow(dtype));
if ~isName && ~(isstruct(dtype) && isscalar(dtype))
    error("zarr:UnsupportedDataType", ...
        "dtype must be one data type name, such as ""double"", or a scalar struct " + ...
        "with fields name and configuration.");
end
end
