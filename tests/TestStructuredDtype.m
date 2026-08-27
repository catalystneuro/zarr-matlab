classdef TestStructuredDtype < matlab.unittest.TestCase
    %Structured ("struct"/"structured") and "fixed_length_utf32" types.
    %
    %   A structured data type -- elements are structs of named fields,
    %   what HDF5 and hdmf call a compound type -- has two data_type
    %   names on disk: the canonical
    %   "struct", specified in zarr-extensions and written by zarr-python
    %   from 3.3 on, whose fields are {name, data_type} objects; and the
    %   legacy "structured", written by earlier versions, whose fields are
    %   [name, data_type] pairs. Both names are read here, each with either
    %   field shape, and each keeps its own fill_value encoding.
    %
    %   "fixed_length_utf32" is not part of the Zarr v3 specification, nor
    %   is the legacy "structured" name -- both are unstable zarr-python
    %   extensions (zarr-python raises UnstableSpecificationWarning when
    %   writing them). Support exists here to read real-world files that use
    %   them (observed in NWB Zarr v3 exports via hdmf-zarr, e.g.
    %   IntracellularRecordingsTable index columns, PlaneSegmentation
    %   pixel_mask/voxel_mask columns, and DynamicTable columns whose rows
    %   mix values with object references).

    methods (Static)
        function info = structInfo()
            % Legacy "structured": {a: int32, b: float64, c: utf32(32 bytes)}
            info = zarr.internal.dtype_info(TestStructuredDtype.legacyDtypeJson());
        end

        function dtypeJson = legacyDtypeJson()
            % The legacy name, with fields as [name, data_type] pairs -- the
            % shape jsondecode returns for them (a cell of 2-element cells,
            % because the pair elements are not type-uniform).
            dtypeJson = struct('name', "structured", 'configuration', struct( ...
                'fields', {{ ...
                    {'a', 'int32'}; ...
                    {'b', 'float64'}; ...
                    {'c', struct('name', 'fixed_length_utf32', 'configuration', struct('length_bytes', 32))} ...
                }}));
        end

        function dtypeJson = canonicalDtypeJson()
            % The same data type under the canonical name, with fields as
            % {name, data_type} objects -- the shape jsondecode returns for
            % them (an Nx1 struct array).
            fields = struct( ...
                'name', {'a'; 'b'; 'c'}, ...
                'data_type', {'int32'; 'float64'; ...
                    struct('name', 'fixed_length_utf32', 'configuration', struct('length_bytes', 32))});
            dtypeJson = struct('name', "struct", 'configuration', struct('fields', fields));
        end
    end

    methods (Test)
        function fixedUtf32Itemsize(tc)
            dtypeJson = struct('name', "fixed_length_utf32", 'configuration', struct('length_bytes', 16));
            info = zarr.internal.dtype_info(dtypeJson);
            tc.verifyEqual(info.itemsize, 16);
            tc.verifyEqual(info.matlabClass, "string");
            tc.verifyFalse(info.isVlen);
        end

        function structuredFieldLayout(tc)
            info = tc.structInfo();
            tc.verifyEqual(info.itemsize, 4 + 8 + 32);
            tc.verifyEqual([info.fields.Name], ["a", "b", "c"]);
            tc.verifyEqual([info.fields.Offset], [0, 4, 12]);
        end

        function unsupportedFixedUtf32ConfigErrors(tc)
            tc.verifyError(@() zarr.internal.dtype_info( ...
                struct('name', "fixed_length_utf32", 'configuration', struct())), ...
                "zarr:InvalidMetadata");
        end

        function fixedUtf32RoundTrip(tc, endianCase)
            info = zarr.internal.dtype_info( ...
                struct('name', "fixed_length_utf32", 'configuration', struct('length_bytes', 64)));
            codec = zarr.codecs.BytesCodec(endianCase);
            values = ["hi"; "utf32 test"; ""];
            bytes = codec.encode(values, info, 3);
            back = codec.decode(bytes, info, 3, []);
            tc.verifyEqual(back, values);
        end

        function fixedUtf32ExceedingCapacityErrors(tc)
            info = zarr.internal.dtype_info( ...
                struct('name', "fixed_length_utf32", 'configuration', struct('length_bytes', 8)));
            codec = zarr.codecs.BytesCodec();
            tc.verifyError(@() codec.encode("way too long for capacity", info, 1), ...
                "zarr:ValueError");
        end

        function structuredRoundTrip(tc, endianCase)
            info = tc.structInfo();
            records(1, 1).a = int32(10);
            records(1, 1).b = 3.5;
            records(1, 1).c = "hi";
            records(2, 1).a = int32(-5);
            records(2, 1).b = -2.25;
            records(2, 1).c = "world";

            codec = zarr.codecs.BytesCodec(endianCase);
            bytes = codec.encode(records, info, [2]);
            tc.verifyEqual(numel(bytes), 2 * info.itemsize);

            back = codec.decode(bytes, info, [2], []);
            tc.verifyEqual(back(1).a, records(1).a);
            tc.verifyEqual(back(1).b, records(1).b);
            tc.verifyEqual(back(1).c, records(1).c);
            tc.verifyEqual(back(2).a, records(2).a);
            tc.verifyEqual(back(2).b, records(2).b);
            tc.verifyEqual(back(2).c, records(2).c);
        end

        function structuredFillValueRoundTrip(tc)
            info = tc.structInfo();
            fv = struct('a', int32(0), 'b', 0.0, 'c', "");
            meta = zarr.metadata.ArrayMetadata();
            meta.shape = 3;
            meta.dataType = "structured";
            meta.dataTypeConfig = info.config;
            meta.chunkShape = 3;
            meta.fillValue = fv;
            meta.codecs = {zarr.codecs.BytesCodec()};

            meta2 = zarr.metadata.ArrayMetadata.fromJsonText(meta.toJsonText());
            tc.verifyEqual(meta2.fillValue.a, fv.a);
            tc.verifyEqual(meta2.fillValue.b, fv.b);
            tc.verifyEqual(meta2.fillValue.c, fv.c);
        end

        function arrayMetadataRoundTripPreservesStructuredDataType(tc)
            info = tc.structInfo();
            meta = zarr.metadata.ArrayMetadata();
            meta.shape = 2;
            meta.dataType = "structured";
            meta.dataTypeConfig = info.config;
            meta.chunkShape = 2;
            meta.fillValue = struct('a', int32(0), 'b', 0.0, 'c', "");
            meta.codecs = {zarr.codecs.BytesCodec()};

            meta2 = zarr.metadata.ArrayMetadata.fromJsonText(meta.toJsonText());
            info2 = zarr.internal.dtype_info(meta2.dataType, meta2.dataTypeConfig);
            tc.verifyEqual(info2.itemsize, info.itemsize);
            tc.verifyEqual([info2.fields.Name], [info.fields.Name]);
        end

        function nestedStructuredField(tc)
            % A structured field that is itself structured.
            innerJson = struct('name', "structured", 'configuration', struct( ...
                'fields', {{{'x', 'int16'}; {'y', 'int16'}}}));
            outerJson = struct('name', "structured", 'configuration', struct( ...
                'fields', {{{'point', innerJson}; {'label', struct('name', 'fixed_length_utf32', ...
                    'configuration', struct('length_bytes', 8))}}}));
            info = zarr.internal.dtype_info(outerJson);
            tc.verifyEqual(info.itemsize, 4 + 8);

            record.point = struct('x', int16(1), 'y', int16(-2));
            record.label = "pt";
            codec = zarr.codecs.BytesCodec();
            bytes = codec.encode(record, info, []);
            back = codec.decode(bytes, info, [], []);
            tc.verifyEqual(back.point.x, record.point.x);
            tc.verifyEqual(back.point.y, record.point.y);
            tc.verifyEqual(back.label, record.label);
        end

        function structuredArrayEndToEnd(tc)
            import matlab.unittest.fixtures.TemporaryFolderFixture
            tempFixture = tc.applyFixture(TemporaryFolderFixture);
            storePath = fullfile(tempFixture.Folder, "structured.zarr");

            info = tc.structInfo();
            meta = zarr.metadata.ArrayMetadata();
            meta.shape = 2;
            meta.dataType = "structured";
            meta.dataTypeConfig = info.config;
            meta.chunkShape = 2;
            meta.fillValue = struct('a', int32(0), 'b', 0.0, 'c', "");
            meta.codecs = {zarr.codecs.BytesCodec()};

            store = zarr.stores.LocalStore(storePath);
            store.set("zarr.json", unicode2native(char(meta.toJsonText()), 'UTF-8'));

            records(1, 1).a = int32(1);
            records(1, 1).b = 1.5;
            records(1, 1).c = "one";
            records(2, 1).a = int32(2);
            records(2, 1).b = 2.5;
            records(2, 1).c = "two";

            z = zarr.Array(store, "", meta);
            z.write(records);

            reopened = zarr.open(storePath);
            back = reopened.read();
            tc.verifyEqual(back(1).a, records(1).a);
            tc.verifyEqual(back(1).c, records(1).c);
            tc.verifyEqual(back(2).b, records(2).b);
        end

        function canonicalNameMatchesLegacyLayout(tc)
            % The two on-disk names describe the same field layout.
            legacy = zarr.internal.dtype_info(tc.legacyDtypeJson());
            canonical = zarr.internal.dtype_info(tc.canonicalDtypeJson());
            tc.verifyTrue(canonical.isStructured);
            tc.verifyEqual(canonical.zarrType, "struct");
            tc.verifyEqual(canonical.itemsize, legacy.itemsize);
            tc.verifyEqual([canonical.fields.Name], [legacy.fields.Name]);
            tc.verifyEqual([canonical.fields.Offset], [legacy.fields.Offset]);
        end

        function canonicalNameAcceptsPairFields(tc)
            % zarr-python's canonical reader falls back to pair-style
            % entries, so a "struct" carrying them must not be rejected.
            dtypeJson = tc.legacyDtypeJson();
            dtypeJson.name = "struct";
            info = zarr.internal.dtype_info(dtypeJson);
            tc.verifyEqual(info.itemsize, tc.structInfo().itemsize);
            tc.verifyEqual([info.fields.Name], ["a", "b", "c"]);
        end

        function fieldsAsCellOfObjects(tc)
            % jsondecode returns a cell of scalar structs, rather than a
            % struct array, when the field entries do not share key sets.
            fields = {struct('name', 'a', 'data_type', 'int32'); ...
                      struct('name', 'b', 'data_type', 'float64', 'note', 'ignored')};
            info = zarr.internal.dtype_info(struct('name', "struct", ...
                'configuration', struct('fields', {fields})));
            tc.verifyEqual([info.fields.Name], ["a", "b"]);
            tc.verifyEqual(info.itemsize, 12);
        end

        function malformedFieldEntryErrors(tc)
            tc.verifyError(@() zarr.internal.dtype_info(struct('name', "struct", ...
                'configuration', struct('fields', {{{'a', 'int32', 'extra'}}}))), ...
                "zarr:InvalidMetadata");
        end

        function variableLengthFieldErrors(tc)
            % Elements have a fixed byte layout, so a vlen field has no size.
            fields = struct('name', {'a'; 'b'}, 'data_type', {'int32'; 'string'});
            tc.verifyError(@() zarr.internal.dtype_info(struct('name', "struct", ...
                'configuration', struct('fields', fields))), ...
                "zarr:UnsupportedDataType");
        end

        function missingFieldsConfigErrors(tc)
            tc.verifyError(@() zarr.internal.dtype_info( ...
                struct('name', "struct", 'configuration', struct())), ...
                "zarr:InvalidMetadata");
        end

        function canonicalFillValueIsPerFieldObject(tc)
            % The canonical name writes fill_value as an object of per-field
            % values; the legacy name writes base64 of the record bytes.
            info = zarr.internal.dtype_info(tc.canonicalDtypeJson());
            fv = struct('a', int32(7), 'b', -1.5, 'c', "hi");
            txt = zarr.internal.encode_fill_value_json(fv, info);
            tc.verifyEqual(txt, "{""a"":7,""b"":-1.5,""c"":""hi""}");
            back = zarr.internal.decode_fill_value(jsondecode(char(txt)), info);
            tc.verifyEqual(back.a, fv.a);
            tc.verifyEqual(back.b, fv.b);
            tc.verifyEqual(back.c, fv.c);
        end

        function legacyFillValueStaysBase64(tc)
            info = tc.structInfo();
            fv = struct('a', int32(7), 'b', -1.5, 'c', "hi");
            txt = zarr.internal.encode_fill_value_json(fv, info);
            tc.verifyTrue(startsWith(txt, """"));
            back = zarr.internal.decode_fill_value(jsondecode(char(txt)), info);
            tc.verifyEqual(back.a, fv.a);
            tc.verifyEqual(back.c, fv.c);
        end

        function canonicalFillValueAcceptsBase64(tc)
            % zarr-python reads either encoding under either name.
            canonical = zarr.internal.dtype_info(tc.canonicalDtypeJson());
            fv = struct('a', int32(3), 'b', 2.5, 'c', "x");
            legacyText = zarr.internal.encode_fill_value_json(fv, tc.structInfo());
            back = zarr.internal.decode_fill_value(jsondecode(char(legacyText)), canonical);
            tc.verifyEqual(back.a, fv.a);
            tc.verifyEqual(back.c, fv.c);
        end

        function fillValueFieldAbsentFallsBackToDefault(tc)
            % hdmf-zarr writes "0" into string fields (the record default is
            % 0 cast field-wise); a field left out entirely defaults too.
            info = zarr.internal.dtype_info(tc.canonicalDtypeJson());
            back = zarr.internal.decode_fill_value(struct('a', 4), info);
            tc.verifyEqual(back.a, int32(4));
            tc.verifyEqual(back.b, 0);
            tc.verifyEqual(back.c, "");
        end

        function createStructArrayEndToEnd(tc)
            % The public creation path: a data_type struct passed to
            % zarr.create, written and read back through zarr.open.
            import matlab.unittest.fixtures.TemporaryFolderFixture
            tempFixture = tc.applyFixture(TemporaryFolderFixture);
            storePath = fullfile(tempFixture.Folder, "created.zarr");

            fields = struct('name', {'id'; 'label'}, 'data_type', ...
                {'int32'; struct('name', 'fixed_length_utf32', ...
                    'configuration', struct('length_bytes', 64))});
            dtype = struct('name', "struct", 'configuration', struct('fields', fields));

            records = struct('id', {int32(1); int32(2); int32(3)}, ...
                             'label', {"alpha"; "beta"; "gamma"});
            z = zarr.create(storePath, 3, dtype, ChunkShape=2);
            z.write(records);

            back = zarr.open(storePath).read();
            tc.verifyEqual([back.id], int32([1, 2, 3]));
            tc.verifyEqual([back.label], ["alpha", "beta", "gamma"]);

            % Chunked across the record boundary, so the second chunk is
            % partial: its unwritten tail must read back as the fill value.
            meta = jsondecode(fileread(fullfile(storePath, "zarr.json")));
            tc.verifyEqual(string(meta.data_type.name), "struct");
            tc.verifyEqual(string(meta.fill_value.label), "");
        end

        function createRejectsNonStructRecordData(tc)
            import matlab.unittest.fixtures.TemporaryFolderFixture
            tempFixture = tc.applyFixture(TemporaryFolderFixture);
            storePath = fullfile(tempFixture.Folder, "rejects.zarr");
            fields = struct('name', {'id'}, 'data_type', {'int32'});
            dtype = struct('name', "struct", 'configuration', struct('fields', fields));
            z = zarr.create(storePath, 2, dtype);
            tc.verifyError(@() z.write([1 2]), "zarr:TypeMismatch");
        end

        function createRejectsConfiguredDtypeNamedWithoutConfig(tc)
            import matlab.unittest.fixtures.TemporaryFolderFixture
            tempFixture = tc.applyFixture(TemporaryFolderFixture);
            storePath = fullfile(tempFixture.Folder, "noconfig.zarr");
            tc.verifyError(@() zarr.create(storePath, 2, "struct"), ...
                "zarr:InvalidMetadata");
        end
    end

    properties (TestParameter)
        endianCase = {"little", "big"};
    end
end
