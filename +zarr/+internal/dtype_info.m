function info = dtype_info(dtype, config)
%DTYPE_INFO Map a Zarr v3 data_type to MATLAB type information.
%   dtype is the data_type name (string), or the decoded JSON value for
%   extension dtypes (a struct with fields name/configuration).
%   info fields:
%     zarrType    - zarr data_type name (string)
%     matlabClass - MATLAB class used to represent values in memory
%     itemsize    - bytes per element on disk
%     isComplex   - true for complex64/complex128
%     isFloat16   - true for float16 (represented as single in memory)
%     isVlen      - true for variable-length types (string, bytes)
%     isStructured - true for a structured data type, i.e. zarrType
%                   "struct" or "structured" (see below)
%     config      - extension dtype configuration struct, or []
%     fields      - when isStructured, a struct array (one entry per
%                   field) with fields Name, Info (this same dtype_info
%                   struct, recursively), Offset (0-based byte offset
%                   within the element); [] otherwise
%
%   A structured data type -- one whose elements are structs of named
%   fields, what HDF5 and hdmf call a compound type -- has two data_type
%   names on disk. "struct" is the canonical one, specified in
%   zarr-extensions and written by zarr-python from 3.3 on; its fields
%   configuration is a list of {"name": ..., "data_type": ...} objects.
%   "structured" is the legacy name that earlier zarr-python versions
%   wrote, with fields as [name, data_type] pairs. Both names are
%   accepted here, each with either field shape, because zarr-python
%   itself reads pair-style fields under the canonical name. The two
%   differ in how a fill_value is written -- see
%   zarr.internal.decode_fill_value -- so zarrType reports the name as
%   found rather than collapsing the two; test with isStructured.
%
%   The "fixed_length_utf32" field sub-type is NOT part of the Zarr v3
%   specification -- it is an unstable, unspecified zarr-python extension
%   (a UnstableSpecificationWarning is raised when writing one), as is
%   the legacy "structured" name. Support here exists to read real-world
%   files that use them (e.g. NWB Zarr v3 exports via hdmf-zarr); the
%   on-disk representation may change in a future zarr-python release.

if isstruct(dtype)
    config = struct();
    if isfield(dtype, 'configuration')
        config = dtype.configuration;
    end
    dtype = string(dtype.name);
elseif nargin < 2
    config = [];
end

dtype = string(dtype);
isComplex = false;
isFloat16 = false;
isVlen = false;

% numpy extension dtypes: int64 ticks of (scale_factor x unit); NaT = intmin.
% Represented in MATLAB as exact int64 (datetime is double-backed and would
% lose sub-microsecond precision for nanosecond timestamps).
if ismember(dtype, ["numpy.datetime64", "numpy.timedelta64"])
    if ~isstruct(config) || ~isfield(config, 'unit')
        error("zarr:InvalidMetadata", "%s requires a unit configuration.", dtype);
    end
    if ~isfield(config, 'scale_factor')
        config.scale_factor = 1;
    end
    info = struct( ...
        'zarrType', dtype, ...
        'matlabClass', "int64", ...
        'itemsize', 8, ...
        'isComplex', false, ...
        'isFloat16', false, ...
        'isVlen', false, ...
        'isStructured', false, ...
        'config', config, ...
        'fields', []);
    return
end

if dtype == "fixed_length_utf32"
    if ~isstruct(config) || ~isfield(config, 'length_bytes')
        error("zarr:InvalidMetadata", "fixed_length_utf32 requires a length_bytes configuration.");
    end
    info = struct( ...
        'zarrType', dtype, ...
        'matlabClass', "string", ...
        'itemsize', double(config.length_bytes), ...
        'isComplex', false, ...
        'isFloat16', false, ...
        'isVlen', false, ...
        'isStructured', false, ...
        'config', config, ...
        'fields', []);
    return
end

if ismember(dtype, ["struct", "structured"])
    if ~isstruct(config) || ~isfield(config, 'fields')
        error("zarr:InvalidMetadata", "%s requires a fields configuration.", dtype);
    end
    fields = structuredFieldInfo(config.fields, dtype);
    itemsize = 0;
    if ~isempty(fields)
        itemsize = fields(end).Offset + fields(end).Info.itemsize;
    end
    info = struct( ...
        'zarrType', dtype, ...
        'matlabClass', "struct", ...
        'itemsize', itemsize, ...
        'isComplex', false, ...
        'isFloat16', false, ...
        'isVlen', false, ...
        'isStructured', true, ...
        'config', config, ...
        'fields', fields);
    return
end

switch dtype
    case "bool",       cls = "logical"; itemsize = 1;
    case "int8",       cls = "int8";    itemsize = 1;
    case "int16",      cls = "int16";   itemsize = 2;
    case "int32",      cls = "int32";   itemsize = 4;
    case "int64",      cls = "int64";   itemsize = 8;
    case "uint8",      cls = "uint8";   itemsize = 1;
    case "uint16",     cls = "uint16";  itemsize = 2;
    case "uint32",     cls = "uint32";  itemsize = 4;
    case "uint64",     cls = "uint64";  itemsize = 8;
    case "float16",    cls = "single";  itemsize = 2; isFloat16 = true;
    case "float32",    cls = "single";  itemsize = 4;
    case "float64",    cls = "double";  itemsize = 8;
    case "complex64",  cls = "single";  itemsize = 8;  isComplex = true;
    case "complex128", cls = "double";  itemsize = 16; isComplex = true;
    case "string",                 cls = "string"; itemsize = NaN; isVlen = true;
    case "variable_length_bytes",  cls = "cell";   itemsize = NaN; isVlen = true;
    otherwise
        error("zarr:UnsupportedDataType", ...
            "Unsupported Zarr data type '%s'.", dtype);
end
info = struct( ...
    'zarrType', dtype, ...
    'matlabClass', string(cls), ...
    'itemsize', itemsize, ...
    'isComplex', isComplex, ...
    'isFloat16', isFloat16, ...
    'isVlen', isVlen, ...
    'isStructured', false, ...
    'config', [], ...
    'fields', []);
end

function fields = structuredFieldInfo(rawFields, dtype)
%STRUCTUREDFIELDINFO Normalize a structured dtype's fields configuration.
%   rawFields is jsondecode's output for the fields list, in either of the
%   two shapes a structured dtype uses on disk (see
%   zarr.internal.dtype_info):
%     - {"name": ..., "data_type": ...} objects, the canonical "struct"
%       shape, which jsondecode returns as an Nx1 struct array (or a cell
%       array of scalar structs when the entries do not share field names);
%     - [name, data_type] pairs, the legacy "structured" shape, which
%       jsondecode returns as a cell array of 2-element cell arrays (the
%       pair elements are not type-uniform).
%   Either shape is accepted under either name: zarr-python's canonical
%   reader also falls back to pair-style entries. dtype names the data
%   type in error messages.
%
%   In both shapes a field's data_type is either a data_type name (char)
%   or a nested extension-dtype struct with name/configuration.

fields = struct('Name', {}, 'Info', {}, 'Offset', {});
offset = 0;
for i = 1:numel(rawFields)
    if isstruct(rawFields)
        entry = rawFields(i);
    else
        entry = rawFields{i};
    end
    [name, fieldType] = fieldNameAndType(entry, i, dtype);
    subInfo = zarr.internal.dtype_info(fieldType);
    if isnan(subInfo.itemsize)
        error("zarr:UnsupportedDataType", ...
            "Field '%s' of a %s data type has the variable-length type '%s'; " + ...
            "its fields must have a fixed size.", name, dtype, subInfo.zarrType);
    end
    fields(end + 1) = struct('Name', name, 'Info', subInfo, 'Offset', offset); %#ok<AGROW>
    offset = offset + subInfo.itemsize;
end
end

function [name, fieldType] = fieldNameAndType(entry, index, dtype)
%FIELDNAMEANDTYPE Split one fields entry, in either on-disk shape.

if isstruct(entry) && isfield(entry, 'name') && isfield(entry, 'data_type')
    name = string(entry.name);
    fieldType = entry.data_type;
elseif iscell(entry) && numel(entry) == 2
    name = string(entry{1});
    fieldType = entry{2};
else
    error("zarr:InvalidMetadata", ...
        "Field %d of a %s data type is neither a {name, data_type} object " + ...
        "nor a [name, data_type] pair.", index, dtype);
end
end
