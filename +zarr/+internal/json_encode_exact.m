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
%   escaping and array shapes. The one thing taken back from it is the
%   non-finite number: jsonencode writes null, and zarr-python writes the
%   bare token NaN, Infinity or -Infinity, so this encoder writes the
%   token (see nonFiniteNumberText).
%
%   A fill_value is not an attribute and does not follow this rule: the
%   Zarr v3 specification gives it the quoted strings "NaN", "Infinity"
%   and "-Infinity", which zarr.internal.encode_fill_value_json writes.
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
elseif isfloat(value) && ~isempty(value) && ~all(isfinite(value(:)))
    txt = nonFiniteNumberText(value);
else
    txt = string(jsonencode(value));
end
end

function txt = nonFiniteNumberText(value)
%NONFINITENUMBERTEXT A float array holding NaN or Inf, as zarr-python writes it.
%   zarr-python writes a non-finite number as the bare token NaN,
%   Infinity or -Infinity. These are its extension to JSON rather than
%   part of the standard, so Python's json module reads a store
%   containing them and a strict parser rejects it. Writing them keeps a
%   float distinct from a string holding the same text.
%
%   jsonencode already nests an array the way the format wants but
%   renders every non-finite element as null, so the nesting is taken
%   from it and each null replaced. jsonencode emits elements in
%   row-major order -- v(:) after reversing the dimension order -- so the
%   k-th null is the k-th non-finite element in that order.

pieces = split(string(jsonencode(value)), "null");
ordered = reshape(permute(value, ndims(value):-1:1), [], 1);
tokens = arrayfun(@nonFiniteToken, ordered(~isfinite(ordered)));
if numel(pieces) ~= numel(tokens) + 1
    % Only a non-finite number makes jsonencode write null here, so the
    % counts match unless that stops being true in a future release.
    error("zarr:InvalidMetadata", ...
        "Expected %d null(s) from jsonencode, got %d.", numel(tokens), numel(pieces) - 1);
end
txt = pieces(1);
for i = 1:numel(tokens)
    txt = txt + tokens(i) + pieces(i + 1);
end
end

function token = nonFiniteToken(x)
if isnan(x)
    token = "NaN";
elseif x > 0
    token = "Infinity";
else
    token = "-Infinity";
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
