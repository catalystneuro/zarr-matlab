function d = attribute_dictionary(value)
%ATTRIBUTE_DICTIONARY Normalize user attributes to a cell-valued dictionary.
%   Attributes are held as a dictionary so that keys survive exactly (see
%   zarr.internal.json_decode_exact), and as a *cell-valued* one so that
%   values of different types can sit side by side. A dictionary whose
%   values have a type coerces on assignment -- inserting 3 into one that
%   already holds a string stores "3" -- which would silently rewrite an
%   attribute, so the cell-valued form is the only safe one here.
%
%   d = attribute_dictionary(value) accepts:
%     dictionary     returned as a cell-valued dictionary with the same
%                    entries; keys must be text
%     scalar struct  field names become the keys, so a struct can only
%                    express keys that are valid MATLAB identifiers
%     [] or struct() no attributes; an empty dictionary
%
%   Values are taken as they are: a struct value stays a struct, and is
%   written as a JSON object by zarr.internal.json_encode_exact. Reading
%   that file back returns it as a dictionary.
%
%   See also zarr.internal.json_decode_exact, zarr.internal.json_encode_exact

d = dictionary(string.empty, {});

if isa(value, 'dictionary')
    if ~isConfigured(value) || numEntries(value) == 0
        return
    end
    names = keys(value);
    if ~isstring(names)
        error("zarr:InvalidAttributes", ...
            "Attribute keys must be text, but the dictionary is keyed by %s.", class(names));
    end
    contents = zarr.internal.dictionary_contents(value);
    for i = 1:numel(names)
        d(names(i)) = contents(i);
    end
elseif isstruct(value)
    if ~isscalar(value)
        error("zarr:InvalidAttributes", ...
            "Attributes must be a scalar struct or a dictionary, but this struct is %s.", ...
            join(string(size(value)), "x"));
    end
    names = string(fieldnames(value));
    for i = 1:numel(names)
        d(names(i)) = {value.(names(i))};
    end
elseif ~isempty(value)
    error("zarr:InvalidAttributes", ...
        "Attributes must be a dictionary, a scalar struct or empty, not %s.", class(value));
end
end
