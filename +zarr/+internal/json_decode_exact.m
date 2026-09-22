function value = json_decode_exact(txt)
%JSON_DECODE_EXACT Decode JSON text, preserving object keys exactly.
%   jsondecode renames any key that is not a valid MATLAB identifier
%   ("_DTYPE" becomes "x_DTYPE", "chunk size" becomes "chunk_size") and
%   offers no way back, so a decoded key cannot be written out again.
%   This decoder returns objects as dictionaries, whose keys are strings
%   and need no such renaming.
%
%   value = json_decode_exact(txt) returns, for each JSON type:
%     object   cell-valued dictionary, keys exactly as written and in
%              document order
%     array    cell column, one element per JSON element, always -- see
%              below
%     string   string scalar
%     number   double, including the bare NaN, Infinity and -Infinity
%              tokens that zarr-python writes for non-finite values
%     boolean  logical scalar
%     null     []
%
%   Objects nested in arrays and in other objects decode the same way, so
%   a key is exact at any depth.
%
%   An array decodes to a cell whatever it holds, so that reading a file
%   and writing it back leaves it unchanged. Collapsing an array of
%   numbers to a double vector would read ["electrode"] -- hdmf-zarr's
%   _REFERENCE_FIELDS with one field, or any other one-element list --
%   back as a bare string and write it out as one, turning a list into a
%   scalar. Use cell2mat on a list of numbers where a vector is wanted.
%
%   Numbers go through double, so an integer beyond 2^53 loses precision
%   the same way it does in jsondecode. Metadata fields where that matters
%   (a uint64 fill value) are re-read from the token by their own parser.
%
%   Example: A key jsondecode cannot represent
%       d = zarr.internal.json_decode_exact('{"_DTYPE":"object_reference"}');
%       d{"_DTYPE"}   % "object_reference"
%
%   See also zarr.internal.json_encode_exact, zarr.internal.json_object_entries

txt = char(txt);
first = skipWs(txt, 1);
if first > numel(txt)
    error("zarr:InvalidMetadata", "Expected JSON text, got a blank string.");
end

switch txt(first)
    case '{'
        [names, texts] = zarr.internal.json_object_entries(txt);
        value = dictionary(string.empty, {});
        for i = 1:numel(names)
            value(names(i)) = {zarr.internal.json_decode_exact(texts(i))};
        end
    case '['
        texts = arrayElements(txt, first);
        value = cell(numel(texts), 1);
        for i = 1:numel(texts)
            value{i} = zarr.internal.json_decode_exact(texts(i));
        end
    case '"'
        value = string(jsondecode(txt(first:end)));
    otherwise
        value = decodeLiteral(strtrim(txt(first:end)));
end
end

function value = decodeLiteral(txt)
%DECODELITERAL A JSON true/false/null/number token as a MATLAB value.
%   NaN, Infinity and -Infinity are a zarr-python extension to JSON rather
%   than part of the standard; they are accepted here because zarr-python
%   writes them for non-finite attribute values and fill values.

switch string(txt)
    case "true",      value = true;
    case "false",     value = false;
    case "null",      value = [];
    case "NaN",       value = NaN;
    case "Infinity",  value = Inf;
    case "-Infinity", value = -Inf;
    otherwise
        value = str2double(txt);
        if isnan(value)
            error("zarr:InvalidMetadata", "'%s' is not a JSON value.", txt);
        end
end
end

function texts = arrayElements(txt, pos)
%ARRAYELEMENTS Source text of each element of the JSON array at txt(pos).

n = numel(txt);
texts = strings(0, 1);
pos = skipWs(txt, pos + 1);
if pos <= n && txt(pos) == ']'
    return
end
depth = 0;
start = pos;
while pos <= n
    c = txt(pos);
    if c == '"'
        pos = skipString(txt, pos);
        continue
    elseif c == '{' || c == '['
        depth = depth + 1;
    elseif c == '}'
        depth = depth - 1;
    elseif c == ']'
        if depth == 0
            texts(end + 1, 1) = strtrim(string(txt(start:pos - 1))); %#ok<AGROW>
            return
        end
        depth = depth - 1;
    elseif c == ',' && depth == 0
        texts(end + 1, 1) = strtrim(string(txt(start:pos - 1))); %#ok<AGROW>
        start = pos + 1;
    end
    pos = pos + 1;
end
error("zarr:InvalidMetadata", "Unterminated JSON array.");
end

function pos = skipString(txt, pos)
%SKIPSTRING Index just past the JSON string starting at txt(pos).

n = numel(txt);
pos = pos + 1;
while pos <= n
    if txt(pos) == '\'
        pos = pos + 2;
    elseif txt(pos) == '"'
        pos = pos + 1;
        return
    else
        pos = pos + 1;
    end
end
error("zarr:InvalidMetadata", "Unterminated JSON string.");
end

function pos = skipWs(txt, pos)
n = numel(txt);
while pos <= n && any(txt(pos) == sprintf(' \t\r\n'))
    pos = pos + 1;
end
end
