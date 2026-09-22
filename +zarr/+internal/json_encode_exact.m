function txt = json_encode_exact(value)
%JSON_ENCODE_EXACT Encode a MATLAB value as JSON, writing object keys exactly.
%   jsonencode builds an object out of a struct, so its keys are limited
%   to valid MATLAB identifiers and cannot carry a name such as "_DTYPE".
%   This encoder writes a dictionary's keys through unchanged, and is the
%   inverse of zarr.internal.json_decode_exact.
%
%   txt = json_encode_exact(value) maps, in this order:
%     dictionary     JSON object, keys in the order keys() returns them
%     scalar struct  JSON object, one member per field
%     struct array   JSON array of objects
%     cell           JSON array, one element per cell
%     0x0 numeric    null, the form json_decode_exact reads null back as
%     anything else  whatever jsonencode makes of it
%
%   An empty JSON array and null are distinct and stay distinct: the
%   array decodes to an empty cell and writes as [], null decodes to []
%   and writes as null.
%
%   Delegating the leaves keeps jsonencode's number formatting, string
%   escaping and array shapes. That includes writing a non-finite number
%   as null, which is what zarr-matlab has always done; zarr-python writes
%   the bare tokens NaN, Infinity and -Infinity instead, which
%   json_decode_exact reads but this encoder does not yet produce.
%
%   Example: A key jsonencode cannot represent
%       d = dictionary(string.empty, {});
%       d("_DTYPE") = {"object_reference"};
%       zarr.internal.json_encode_exact(d)   % {"_DTYPE":"object_reference"}
%
%   See also zarr.internal.json_decode_exact

if isa(value, 'dictionary')
    if ~isConfigured(value) || numEntries(value) == 0
        txt = "{}";
        return
    end
    names = keys(value);
    contents = zarr.internal.dictionary_contents(value);
    txt = objectText(names, contents);
elseif isstruct(value) && isscalar(value)
    names = string(fieldnames(value));
    contents = struct2cell(value);
    txt = objectText(names, contents);
elseif isstruct(value)
    txt = arrayText(num2cell(value(:)));
elseif iscell(value)
    txt = arrayText(value(:));
elseif isnumeric(value) && isequal(size(value), [0 0])
    % [] is how json_decode_exact represents null, so write it back as
    % null. An empty JSON *array* decodes to an empty cell, which
    % arrayText writes as [], so both stay distinguishable.
    txt = "null";
else
    txt = string(jsonencode(value));
end
end

function txt = objectText(names, contents)
%OBJECTTEXT A JSON object from matching key and value lists.

members = strings(numel(names), 1);
for i = 1:numel(names)
    members(i) = string(jsonencode(char(names(i)))) + ":" + ...
        zarr.internal.json_encode_exact(contents{i});
end
txt = "{" + strjoin(members, ",") + "}";
end

function txt = arrayText(contents)
%ARRAYTEXT A JSON array from a cell of element values.

if isempty(contents)
    txt = "[]";
    return
end
elements = strings(numel(contents), 1);
for i = 1:numel(contents)
    elements(i) = zarr.internal.json_encode_exact(contents{i});
end
txt = "[" + strjoin(elements, ",") + "]";
end
