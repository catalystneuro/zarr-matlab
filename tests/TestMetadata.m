classdef TestMetadata < matlab.unittest.TestCase
    %zarr.json parse/serialize fidelity.

    methods (Static)
        function meta2 = roundTrip(meta)
            meta2 = zarr.metadata.ArrayMetadata.fromJsonText(meta.toJsonText());
        end
    end

    methods (Test)
        function basicRoundTrip(tc)
            meta = zarr.metadata.ArrayMetadata();
            meta.shape = [10 20];
            meta.dataType = "float64";
            meta.chunkShape = [5 5];
            meta.fillValue = 0;
            meta.codecs = {zarr.codecs.BytesCodec(), zarr.codecs.GzipCodec(5)};
            m2 = tc.roundTrip(meta);
            tc.verifyEqual(m2.shape, meta.shape);
            tc.verifyEqual(m2.chunkShape, meta.chunkShape);
            tc.verifyEqual(m2.dataType, meta.dataType);
            tc.verifyEqual(numel(m2.codecs), 2);
            tc.verifyEqual(m2.codecs{2}.level, 5);
        end

        function specialFillValues(tc)
            cases = {
                "float64", NaN
                "float64", Inf
                "float64", -Inf
                "float32", single(NaN)
                "float16", single(0.5)
                "bool", true
                "int64", int64(-9007199254740993)     % below -2^53
                "uint64", uint64(2)^60
                "complex128", complex(NaN, -Inf)
                "complex64", complex(single(1.5), single(-2.5))
                };
            for i = 1:size(cases, 1)
                meta = zarr.metadata.ArrayMetadata();
                meta.shape = 4;
                meta.dataType = cases{i, 1};
                meta.chunkShape = 2;
                meta.fillValue = cases{i, 2};
                meta.codecs = {zarr.codecs.BytesCodec()};
                m2 = tc.roundTrip(meta);
                tc.verifyEqual(m2.fillValue, cases{i, 2}, ...
                    sprintf('%s fill', cases{i, 1}));
            end
        end

        function hexFillValue(tc)
            % NaN with payload, as zarr-python may write it
            txt = ['{"zarr_format":3,"node_type":"array","shape":[2],' ...
                '"data_type":"float64",' ...
                '"chunk_grid":{"name":"regular","configuration":{"chunk_shape":[2]}},' ...
                '"chunk_key_encoding":{"name":"default"},' ...
                '"fill_value":"0x7ff8000000000001",' ...
                '"codecs":[{"name":"bytes","configuration":{"endian":"little"}}]}'];
            meta = zarr.metadata.ArrayMetadata.fromJsonText(txt);
            tc.verifyTrue(isnan(meta.fillValue));
        end

        function intFillValueNotConfusedByAttributeKey(tc)
            % An attribute literally named "fill_value" (placed before the
            % real fill_value in the document) must not be picked up by the
            % exact-token re-extraction used for out-of-double-precision
            % int64 fill values.
            expected = int64(9007199254740992) + int64(3);  % 2^53 + 3
            txt = ['{"zarr_format":3,"node_type":"array","shape":[2],' ...
                '"attributes":{"fill_value":7},' ...
                '"data_type":"int64",' ...
                '"chunk_grid":{"name":"regular","configuration":{"chunk_shape":[2]}},' ...
                '"chunk_key_encoding":{"name":"default","configuration":{"separator":"/"}},' ...
                '"fill_value":9007199254740995,' ...
                '"codecs":[{"name":"bytes","configuration":{"endian":"little"}}]}'];
            meta = zarr.metadata.ArrayMetadata.fromJsonText(txt);
            tc.verifyEqual(meta.fillValue, expected);
        end

        function intFillValueToleratesNonIntegerTokens(tc)
            % Lenient writers may spell an integer fill_value as 3.0, 1e16,
            % or null; those files must stay openable (the value falls back
            % to the jsondecode result) rather than erroring at parse.
            base = ['{"zarr_format":3,"node_type":"array","shape":[2],' ...
                '"data_type":"int64",' ...
                '"chunk_grid":{"name":"regular","configuration":{"chunk_shape":[2]}},' ...
                '"chunk_key_encoding":{"name":"default","configuration":{"separator":"/"}},' ...
                '"fill_value":%s,' ...
                '"codecs":[{"name":"bytes","configuration":{"endian":"little"}}]}'];
            meta = zarr.metadata.ArrayMetadata.fromJsonText(sprintf(base, '3.0'));
            tc.verifyEqual(meta.fillValue, int64(3));
            meta = zarr.metadata.ArrayMetadata.fromJsonText(sprintf(base, '1e16'));
            tc.verifyEqual(meta.fillValue, int64(1e16));
            tc.verifyWarningFree(@() zarr.metadata.ArrayMetadata.fromJsonText(sprintf(base, 'null')));
        end

        function negativeZeroFill(tc)
            meta = zarr.metadata.ArrayMetadata();
            meta.shape = 2;
            meta.dataType = "float64";
            meta.chunkShape = 2;
            meta.fillValue = -0.0;
            meta.codecs = {zarr.codecs.BytesCodec()};
            m2 = tc.roundTrip(meta);
            tc.verifyEqual(typecast(m2.fillValue, 'uint64'), ...
                typecast(-0.0, 'uint64'), 'sign bit preserved');
        end

        function dimensionNamesWithNull(tc)
            meta = zarr.metadata.ArrayMetadata();
            meta.shape = [2 3];
            meta.dataType = "int8";
            meta.chunkShape = [2 3];
            meta.fillValue = int8(0);
            meta.codecs = {zarr.codecs.BytesCodec()};
            meta.dimensionNames = ["time" missing];
            m2 = tc.roundTrip(meta);
            tc.verifyEqual(m2.dimensionNames(1), "time");
            tc.verifyTrue(ismissing(m2.dimensionNames(2)));
        end

        function singletonShapeStaysList(tc)
            % the classic jsonencode trap: [5] must not serialize as 5
            meta = zarr.metadata.ArrayMetadata();
            meta.shape = 5;
            meta.dataType = "int8";
            meta.chunkShape = 5;
            meta.fillValue = int8(0);
            meta.codecs = {zarr.codecs.BytesCodec()};
            txt = meta.toJsonText();
            tc.verifySubstring(char(txt), '"shape":[5]');
            tc.verifySubstring(char(txt), '"chunk_shape":[5]');
        end

        function rankZeroShape(tc)
            meta = zarr.metadata.ArrayMetadata();
            meta.shape = zeros(1, 0);
            meta.dataType = "float64";
            meta.chunkShape = zeros(1, 0);
            meta.fillValue = 0;
            meta.codecs = {zarr.codecs.BytesCodec()};
            txt = meta.toJsonText();
            tc.verifySubstring(char(txt), '"shape":[]');
            m2 = tc.roundTrip(meta);
            tc.verifyEmpty(m2.shape);
        end

        function rejectsWrongFormat(tc)
            tc.verifyError(@() zarr.metadata.ArrayMetadata.fromJsonText( ...
                '{"zarr_format":2,"node_type":"array"}'), "zarr:InvalidMetadata");
            tc.verifyError(@() zarr.metadata.ArrayMetadata.fromJsonText( ...
                '{"zarr_format":3,"node_type":"group"}'), "zarr:InvalidMetadata");
        end

        function groupMetadata(tc)
            gm = zarr.metadata.GroupMetadata();
            gm.attributes = struct('a', 1, 'b', "text");
            gm2 = zarr.metadata.GroupMetadata.fromJsonText(gm.toJsonText());
            tc.verifyEqual(gm2.attributes{"a"}, 1);
            tc.verifyEqual(gm2.attributes{"b"}, "text");
        end

        function datetimeDtypeRoundTrip(tc)
            txt = ['{"zarr_format":3,"node_type":"array","shape":[4],' ...
                '"data_type":{"name":"numpy.datetime64","configuration":' ...
                '{"unit":"ns","scale_factor":1}},' ...
                '"chunk_grid":{"name":"regular","configuration":{"chunk_shape":[2]}},' ...
                '"chunk_key_encoding":{"name":"default"},' ...
                '"fill_value":-9223372036854775808,' ...
                '"codecs":[{"name":"bytes","configuration":{"endian":"little"}}]}'];
            meta = zarr.metadata.ArrayMetadata.fromJsonText(txt);
            tc.verifyEqual(meta.dataType, "numpy.datetime64");
            tc.verifyEqual(string(meta.dataTypeConfig.unit), "ns");
            tc.verifyEqual(meta.fillValue, intmin('int64'), 'NaT fill is exact');
            m2 = tc.roundTrip(meta);
            tc.verifyEqual(m2.dataType, "numpy.datetime64");
            tc.verifyEqual(m2.fillValue, intmin('int64'));
            tc.verifySubstring(char(meta.toJsonText()), '"name":"numpy.datetime64"');
        end

        function chunkKeys(tc)
            meta = zarr.metadata.ArrayMetadata();
            meta.keyEncoding = "default";
            meta.keySeparator = "/";
            tc.verifyEqual(meta.chunkKey([0 2 5]), "c/0/2/5");
            tc.verifyEqual(meta.chunkKey([]), "c");
            meta.keyEncoding = "v2";
            meta.keySeparator = ".";
            tc.verifyEqual(meta.chunkKey([0 2 5]), "0.2.5");
            tc.verifyEqual(meta.chunkKey([]), "0");
        end
    end
end
