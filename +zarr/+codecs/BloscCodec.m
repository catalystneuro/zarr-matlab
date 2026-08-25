classdef BloscCodec < zarr.codecs.Codec
    %BLOSCCODEC The Zarr v3 "blosc" codec (MEX-backed).
    %   zarr.codecs.BloscCodec(cname="zstd", clevel=5, shuffle="shuffle", ...
    %                          typesize=0, blocksize=0)
    %   typesize 0 means "fill in from the array dtype at create time".

    properties (Constant)
        name = "blosc"
        kind = "bytes_bytes"
    end

    properties
        cname (1,1) string {mustBeMember(cname, ["lz4", "lz4hc", "blosclz", "zstd", "snappy", "zlib"])} = "zstd"
        clevel (1,1) double {mustBeInteger, mustBeInRange(clevel, 0, 9)} = 5
        shuffle (1,1) string {mustBeMember(shuffle, ["noshuffle", "shuffle", "bitshuffle"])} = "shuffle"
        typesize (1,1) double {mustBeInteger, mustBeNonnegative} = 0
        blocksize (1,1) double {mustBeInteger, mustBeNonnegative} = 0
    end

    methods
        function obj = BloscCodec(opts)
            arguments
                opts.cname (1,1) string = "zstd"
                opts.clevel (1,1) double = 5
                opts.shuffle (1,1) string = "shuffle"
                opts.typesize (1,1) double = 0
                opts.blocksize (1,1) double = 0
            end
            obj.cname = opts.cname;
            obj.clevel = opts.clevel;
            obj.shuffle = opts.shuffle;
            obj.typesize = opts.typesize;
            obj.blocksize = opts.blocksize;
        end

        function cfg = configuration(obj)
            cfg = struct('cname', obj.cname, 'clevel', obj.clevel, ...
                'shuffle', obj.shuffle, 'typesize', obj.typesize, ...
                'blocksize', obj.blocksize);
        end

        function out = encode(obj, bytes)
            zarr.codecs.BloscCodec.ensureMex();
            if obj.typesize < 1
                error("zarr:InvalidCodecs", ...
                    "Blosc typesize is unset; create the codec with typesize=... or let zarr.create fill it from the dtype.");
            end
            shuffleInt = find(obj.shuffle == ["noshuffle", "shuffle", "bitshuffle"]) - 1;
            out = zarr.internal.blosc_mex('compress', uint8(bytes(:)'), ...
                char(obj.cname), obj.clevel, shuffleInt, obj.typesize);
        end

        function out = decode(~, bytes)
            zarr.codecs.BloscCodec.ensureMex();
            out = zarr.internal.blosc_mex('decompress', uint8(bytes(:)'));
        end
    end

    methods (Static)
        function obj = fromConfig(cfg)
            args = {};
            for f = ["cname", "clevel", "shuffle", "typesize", "blocksize"]
                if isfield(cfg, f)
                    v = cfg.(f);
                    if isnumeric(v), v = double(v); else, v = string(v); end
                    args = [args, {char(f), v}]; %#ok<AGROW>
                end
            end
            obj = zarr.codecs.BloscCodec(args{:});
        end

        function ensureMex()
            % which() costs several milliseconds, which dominates per-chunk
            % codec time, so cache the positive result. A negative result is
            % never cached: that path errors out anyway, and re-checking lets
            % a MEX built mid-session be picked up without clearing functions.
            persistent isBuilt
            if isempty(isBuilt) || ~isBuilt
                isBuilt = ~isempty(which('zarr.internal.blosc_mex'));
            end
            if ~isBuilt
                error("zarr:MissingMex", ...
                    "The blosc codec needs the zarr-matlab MEX extension. Build it with tools/build_mex.m (requires libblosc).");
            end
        end
    end
end
