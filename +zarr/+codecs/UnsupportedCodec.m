classdef UnsupportedCodec
    %UNSUPPORTEDCODEC A codec entry that zarr-matlab cannot apply.
    %   zarr.codecs.from_config returns one for a codec name it does not
    %   implement, so that the array can still be opened: its shape, data
    %   type and attributes can be read, and its metadata is written back
    %   with the entry unchanged. Building a codec pipeline that contains it
    %   raises zarr:UnsupportedCodec, so the error surfaces when the array's
    %   data is read or written.
    %
    %   The entry is kept as JSON re-encoded from the decoded metadata.

    properties (SetAccess = immutable)
        name (1,1) string
        entryJson (1,1) string  % the {"name": ..., "configuration": ...} entry
    end

    properties (Constant)
        kind = "unsupported"
    end

    methods
        function obj = UnsupportedCodec(name, entryJson)
            arguments
                name (1,1) string
                entryJson (1,1) string
            end
            obj.name = name;
            obj.entryJson = entryJson;
        end

        function txt = configJson(obj)
            txt = obj.entryJson;
        end

        function throwUnsupported(obj)
            error("zarr:UnsupportedCodec", "Unsupported codec '%s'.", obj.name);
        end
    end
end
