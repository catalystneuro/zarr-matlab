function out = gzip_java(mode, bytes, level)
%GZIP_JAVA Gzip (RFC 1952) compress/decompress via java.util.zip.
%   out = gzip_java('compress', bytes, level)
%   out = gzip_java('decompress', bytes)
%
%   Uses Deflater/InflaterOutputStream so data only ever flows MATLAB -> Java
%   (Java-filled byte buffers are not visible to MATLAB).
%
%   A gzip stream can hold several members one after another (RFC 1952,
%   section 2.2); decompress returns their concatenated contents.

bytes = uint8(bytes(:)');
switch mode
    case 'compress'
        deflater = java.util.zip.Deflater(level, true);  % raw deflate
        baos = java.io.ByteArrayOutputStream();
        dos = java.util.zip.DeflaterOutputStream(baos, deflater);
        if ~isempty(bytes)
            dos.write(typecast(bytes, 'int8'));
        end
        dos.close();
        javaMethod('end', deflater);
        raw = typecast(int8(baos.toByteArray())', 'uint8');

        crcObj = java.util.zip.CRC32();
        if ~isempty(bytes)
            crcObj.update(typecast(bytes, 'int8'));
        end
        crc = typecast(uint32(crcObj.getValue()), 'uint8');
        isize = typecast(uint32(mod(numel(bytes), 2^32)), 'uint8');
        % Header: magic, CM=deflate, no flags, mtime 0, XFL 0, OS 255 (unknown).
        header = uint8([31 139 8 0 0 0 0 0 0 255]);
        out = [header, raw, crc, isize];

    case 'decompress'
        out = decompressMembers(bytes);

    otherwise
        error("zarr:InternalError", "Unknown gzip_java mode '%s'.", mode);
end
end

function out = decompressMembers(bytes)
%DECOMPRESSMEMBERS Decompress each gzip member in bytes and concatenate them.
n = numel(bytes);
parts = {};
pos = 1;  % first byte of the current member (1-based)
while pos <= n
    [part, pos] = decompressMember(bytes, pos);
    parts{end + 1} = part; %#ok<AGROW>
end
if isempty(parts)
    error("zarr:CodecError", "Invalid gzip stream.");
end
out = [parts{:}];
end

function [out, next] = decompressMember(bytes, pos)
%DECOMPRESSMEMBER Decompress the gzip member that starts at bytes(pos).
%   next is the index of the first byte after the member's 8-byte trailer.
sliceBytes = 65536;  % input handed to the inflater per write
n = numel(bytes);
if n - pos + 1 < 18 || bytes(pos) ~= 31 || bytes(pos + 1) ~= 139 || bytes(pos + 2) ~= 8
    error("zarr:CodecError", "Invalid gzip stream.");
end
flg = bytes(pos + 3);
pos = pos + 10;  % first byte after the fixed 10-byte header
if bitand(flg, 4)  % FEXTRA
    xlen = double(bytes(pos)) + 256 * double(bytes(pos + 1));
    pos = pos + 2 + xlen;
end
if bitand(flg, 8)  % FNAME: zero-terminated
    pos = find(bytes(pos:end) == 0, 1) + pos;
end
if bitand(flg, 16)  % FCOMMENT
    pos = find(bytes(pos:end) == 0, 1) + pos;
end
if bitand(flg, 2)  % FHCRC
    pos = pos + 2;
end

% The inflater stops at the end of this member's deflate data and ignores
% the bytes after it; getBytesRead reports how many it consumed.
inflater = java.util.zip.Inflater(true);
baos = java.io.ByteArrayOutputStream();
ios = java.util.zip.InflaterOutputStream(baos, inflater);
try
    % Hand the inflater one slice at a time and stop once this member's
    % deflate data ends, so each member converts only its own bytes rather
    % than the whole rest of the stream.
    sliceStart = pos;
    while sliceStart <= n && ~inflater.finished()
        sliceEnd = min(sliceStart + sliceBytes - 1, n);
        ios.write(typecast(bytes(sliceStart:sliceEnd), 'int8'));
        sliceStart = sliceEnd + 1;
    end
    ios.close();
catch err
    javaMethod('end', inflater);
    % Deflate data that cannot be decoded makes the inflater throw a Java
    % ZipException; any other error is not about the data.
    if ~strcmp(err.identifier, "MATLAB:Java:GenericException")
        rethrow(err);
    end
    error("zarr:CodecError", "Gzip: invalid or corrupt deflate data.");
end
consumed = double(inflater.getBytesRead());
javaMethod('end', inflater);
out = typecast(int8(baos.toByteArray())', 'uint8');

trailer = pos + consumed;  % CRC32 then ISIZE, 4 bytes each
if trailer + 7 > n
    error("zarr:CodecError", "Invalid gzip stream.");
end
expectedCrc = typecast(bytes(trailer:trailer + 3), 'uint32');
crcObj = java.util.zip.CRC32();
if ~isempty(out)
    crcObj.update(typecast(out, 'int8'));
end
if uint32(crcObj.getValue()) ~= expectedCrc
    error("zarr:CodecError", "Gzip CRC mismatch: corrupt data.");
end
next = trailer + 8;
end
