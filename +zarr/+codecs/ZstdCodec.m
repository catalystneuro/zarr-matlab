classdef ZstdCodec < zarr.codecs.Codec
    %ZSTDCODEC The Zarr v3 "zstd" codec (MEX-backed).
    %   zarr.codecs.ZstdCodec(level, checksum)

    properties (Constant)
        name = "zstd"
        kind = "bytes_bytes"
    end

    properties
        level (1,1) double {mustBeInteger, mustBeInRange(level, -131072, 22)} = 0
        checksum (1,1) logical = false
    end

    methods
        function obj = ZstdCodec(level, checksum)
            if nargin > 0, obj.level = level; end
            if nargin > 1, obj.checksum = checksum; end
        end

        function cfg = configuration(obj)
            cfg = struct('level', obj.level, 'checksum', obj.checksum);
        end

        function out = encode(obj, bytes)
            zarr.codecs.ZstdCodec.ensureMex();
            out = zarr.internal.zstd_mex('compress', uint8(bytes(:)'), obj.level, obj.checksum);
        end

        function out = decode(~, bytes)
            zarr.codecs.ZstdCodec.ensureMex();
            out = zarr.internal.zstd_mex('decompress', uint8(bytes(:)'));
        end
    end

    methods (Static)
        function obj = fromConfig(cfg)
            obj = zarr.codecs.ZstdCodec();
            if isfield(cfg, 'level'), obj.level = double(cfg.level); end
            if isfield(cfg, 'checksum'), obj.checksum = logical(cfg.checksum); end
        end

        function ensureMex()
            % which() costs several milliseconds, which dominates per-chunk
            % codec time, so cache the positive result. A negative result is
            % never cached: that path errors out anyway, and re-checking lets
            % a MEX built mid-session be picked up without clearing functions.
            persistent isBuilt
            if isempty(isBuilt) || ~isBuilt
                isBuilt = ~isempty(which('zarr.internal.zstd_mex'));
            end
            if ~isBuilt
                error("zarr:MissingMex", ...
                    "The zstd codec needs the zarr-matlab MEX extension. Build it with tools/build_mex.m (requires libzstd).");
            end
        end
    end
end
