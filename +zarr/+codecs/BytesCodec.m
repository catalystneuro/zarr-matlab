classdef BytesCodec < zarr.codecs.Codec
    %BYTESCODEC The Zarr v3 "bytes" codec: array <-> C-order bytes with endianness.

    properties (Constant)
        name = "bytes"
        kind = "array_bytes"
    end

    properties
        endian (1,1) string {mustBeMember(endian, ["little", "big"])} = "little"
    end

    methods
        function obj = BytesCodec(endian)
            if nargin > 0
                obj.endian = endian;
            end
        end

        function cfg = configuration(obj)
            cfg = struct('endian', obj.endian);
        end

        function bytes = encode(obj, A, info, shape)
            if info.isVlen
                error("zarr:InvalidCodecs", ...
                    "The bytes codec cannot serialize %s data; use vlen-utf8/vlen-bytes.", info.zarrType);
            end
            if info.isStructured || info.zarrType == "fixed_length_utf32"
                R = numel(shape);
                if R >= 2
                    A = permute(A, R:-1:1);  % emit C order
                end
                if info.isStructured
                    bytes = zarr.internal.encode_structured(A(:), info, obj.endian);
                else
                    bytes = zarr.internal.encode_fixed_utf32(A(:), info, obj.endian);
                end
                return
            end
            R = numel(shape);
            if R >= 2
                A = permute(A, R:-1:1);  % emit C order
            end
            v = A(:);
            switch true
                case info.zarrType == "bool"
                    raw = uint8(v);
                case info.isFloat16
                    raw = zarr.internal.single2half(single(v));
                case info.isComplex
                    n = numel(v);
                    raw = zeros(2 * n, 1, char(info.matlabClass));
                    raw(1:2:end) = real(v);
                    raw(2:2:end) = imag(v);
                otherwise
                    raw = v;
            end
            if obj.endian == "big" && info.itemsize > 1
                raw = swapbytes(raw);
            end
            bytes = typecast(raw, 'uint8')';
        end

        function A = decode(obj, bytes, info, shape, ~)
            R = numel(shape);
            n = prod(shape);  % prod([]) == 1 handles rank 0
            expected = n * info.itemsize;
            if numel(bytes) ~= expected
                error("zarr:CodecError", ...
                    "Chunk has %d bytes; expected %d for shape [%s] of %s.", ...
                    numel(bytes), expected, num2str(reshape(shape, 1, [])), info.zarrType);
            end

            if info.isStructured || info.zarrType == "fixed_length_utf32"
                if info.isStructured
                    v = zarr.internal.decode_structured(bytes(:)', info, n, obj.endian);
                else
                    v = zarr.internal.decode_fixed_utf32(bytes(:)', info, n, obj.endian);
                end
                if R >= 2
                    A = permute(reshape(v, flip(reshape(shape, 1, []))), R:-1:1);
                else
                    A = v;
                end
                return
            end

            b = bytes(:);
            switch true
                case info.zarrType == "bool"
                    v = logical(b);
                case info.isFloat16
                    u = typecast(b, 'uint16');
                    if obj.endian == "big", u = swapbytes(u); end
                    v = zarr.internal.half2single(u);
                case info.isComplex
                    raw = typecast(b, char(info.matlabClass));
                    if obj.endian == "big", raw = swapbytes(raw); end
                    v = complex(raw(1:2:end), raw(2:2:end));
                otherwise
                    v = typecast(b, char(info.matlabClass));
                    if obj.endian == "big" && info.itemsize > 1
                        v = swapbytes(v);
                    end
            end
            if R >= 2
                A = permute(reshape(v, flip(reshape(shape, 1, []))), R:-1:1);
            else
                A = v;  % rank 0 -> scalar, rank 1 -> column vector
            end
        end
    end

    methods (Static)
        function obj = fromConfig(cfg)
            if isfield(cfg, 'endian')
                obj = zarr.codecs.BytesCodec(string(cfg.endian));
            else
                obj = zarr.codecs.BytesCodec();
            end
        end
    end
end
