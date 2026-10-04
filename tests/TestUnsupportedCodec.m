classdef TestUnsupportedCodec < matlab.unittest.TestCase
    %An array whose codec chain holds a codec zarr-matlab does not implement.
    %   Such an array opens, and its metadata can be read and written back;
    %   reading or writing its data raises zarr:UnsupportedCodec.

    properties (Constant)
        % numcodecs.lz4, as zarr-python writes it for numcodecs.LZ4().
        Lz4Entry = "{""name"":""numcodecs.lz4"",""configuration"":{""acceleration"":1}}"
        GzipEntry = "{""name"":""gzip"",""configuration"":{""level"":5}}"
    end

    methods (Static)
        function store = storeWithLz4Array(codecs)
            %STOREWITHLZ4ARRAY A store whose array "a" uses lz4 in place of gzip.
            store = zarr.stores.MemoryStore();
            zarr.create(store, [4 6], "double", Path="a", ChunkShape=[2 3], ...
                Codecs=codecs, Attributes=struct('units', "mV")).write(reshape(1:24, 4, 6));
            text = native2unicode(store.get("a/zarr.json"), 'UTF-8');
            assert(contains(text, TestUnsupportedCodec.GzipEntry));
            text = replace(text, TestUnsupportedCodec.GzipEntry, TestUnsupportedCodec.Lz4Entry);
            store.set("a/zarr.json", unicode2native(text, 'UTF-8'));
        end
    end

    methods (Test)
        function arrayOpensWithMetadata(tc)
            store = tc.storeWithLz4Array({zarr.codecs.GzipCodec(5)});

            a = zarr.open(store, Path="a");

            tc.verifyEqual(a.shape, [4 6]);
            tc.verifyEqual(a.dtype, "float64");
            tc.verifyEqual(a.attrs{"units"}, "mV");
            tc.verifyClass(a.meta.codecs{2}, "zarr.codecs.UnsupportedCodec");
            tc.verifyEqual(a.meta.codecs{2}.name, "numcodecs.lz4");
        end

        function readAndWriteRaise(tc)
            store = tc.storeWithLz4Array({zarr.codecs.GzipCodec(5)});
            a = zarr.open(store, Path="a");

            tc.verifyError(@() a.read(), "zarr:UnsupportedCodec");
            % Data other than the fill value, so that chunks are encoded.
            tc.verifyError(@() a.write(ones(4, 6)), "zarr:UnsupportedCodec");
        end

        function groupBrowsingIsUnaffected(tc)
        % Walking a hierarchy parses every array's metadata, so one array
        % with an unsupported codec must not stop it.
            store = tc.storeWithLz4Array({zarr.codecs.GzipCodec(5)});
            zarr.create_group(store);

            [arrays, groups] = zarr.open(store).children();

            tc.verifyEqual(arrays, "a");
            tc.verifyEmpty(groups);
        end

        function setAttrKeepsTheCodecEntry(tc)
            store = tc.storeWithLz4Array({zarr.codecs.GzipCodec(5)});
            a = zarr.open(store, Path="a");

            a.setAttr("units", "uV");

            reopened = zarr.open(store, Path="a");
            tc.verifyEqual(reopened.attrs{"units"}, "uV");
            tc.verifyEqual(reopened.meta.codecs{2}.name, "numcodecs.lz4");
            m = jsondecode(native2unicode(store.get("a/zarr.json"), 'UTF-8'));
            tc.verifyEqual(m.codecs(2).configuration.acceleration, 1);
        end

        function unsupportedInnerShardingCodec(tc)
        % The inner chain of a sharding codec is parsed the same way, and
        % is not completed with a serializer it may already contain.
            sharding = zarr.codecs.ShardingCodec([1 3], ...
                Codecs={zarr.codecs.BytesCodec(), zarr.codecs.GzipCodec(5)});
            store = tc.storeWithLz4Array({sharding});

            a = zarr.open(store, Path="a");

            inner = a.meta.codecs{1}.codecs;
            tc.verifyEqual(numel(inner), 2);
            tc.verifyClass(inner{2}, "zarr.codecs.UnsupportedCodec");
            tc.verifyError(@() a.read(), "zarr:UnsupportedCodec");
        end

        function pipelineRejectsUnsupportedCodec(tc)
            codecs = {zarr.codecs.BytesCodec(), ...
                zarr.codecs.UnsupportedCodec("numcodecs.lz4", TestUnsupportedCodec.Lz4Entry)};

            tc.verifyError(@() zarr.codecs.Pipeline(codecs, zarr.internal.dtype_info("float64"), 4), ...
                "zarr:UnsupportedCodec");
        end
    end
end
