function contents = dictionary_contents(d)
%DICTIONARY_CONTENTS The values of a dictionary as a cell, whatever its value type.
%   values(d) returns a cell for a cell-valued dictionary and a typed
%   array otherwise, and values(d,"cell") wraps a cell-valued dictionary's
%   values a second time rather than leaving them alone. This returns one
%   cell per entry holding the stored value itself, in key order, for
%   either kind.
%
%   See also zarr.internal.attribute_dictionary

if ~isConfigured(d) || numEntries(d) == 0
    contents = cell(0, 1);
    return
end
contents = values(d);
if ~iscell(contents)
    contents = num2cell(contents);
end
contents = reshape(contents, [], 1);
end
