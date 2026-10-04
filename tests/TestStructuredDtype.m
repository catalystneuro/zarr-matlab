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

        function fields = writtenFieldsList(metaText)
            % The data_type fields list of a zarr.json text. JSON arrays stay
            % cells here, where jsondecode returns a 1x1 struct for both a
            % one-element list and a bare object.
            meta = zarr.internal.json_decode_exact(metaText);
            dataType = meta{"data_type"};
            configuration = dataType{"configuration"};
            fields = configuration{"fields"};
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
            back = zarr.internal.decode_fill_value(txt, info);
            tc.verifyEqual(back.a, fv.a);
            tc.verifyEqual(back.b, fv.b);
            tc.verifyEqual(back.c, fv.c);
        end

        function legacyFillValueStaysBase64(tc)
            info = tc.structInfo();
            fv = struct('a', int32(7), 'b', -1.5, 'c', "hi");
            txt = zarr.internal.encode_fill_value_json(fv, info);
            tc.verifyTrue(startsWith(txt, """"));
            back = zarr.internal.decode_fill_value(txt, info);
            tc.verifyEqual(back.a, fv.a);
            tc.verifyEqual(back.c, fv.c);
        end

        function canonicalFillValueAcceptsBase64(tc)
            % zarr-python reads either encoding under either name.
            canonical = zarr.internal.dtype_info(tc.canonicalDtypeJson());
            fv = struct('a', int32(3), 'b', 2.5, 'c', "x");
            legacyText = zarr.internal.encode_fill_value_json(fv, tc.structInfo());
            back = zarr.internal.decode_fill_value(legacyText, canonical);
            tc.verifyEqual(back.a, fv.a);
            tc.verifyEqual(back.c, fv.c);
        end

        function fillValueFieldAbsentFallsBackToDefault(tc)
            % hdmf-zarr writes "0" into string fields (the record default is
            % 0 cast field-wise); a field left out entirely defaults too.
            info = zarr.internal.dtype_info(tc.canonicalDtypeJson());
            back = zarr.internal.decode_fill_value('{"a":4}', info);
            tc.verifyEqual(back.a, int32(4));
            tc.verifyEqual(back.b, 0);
            tc.verifyEqual(back.c, "");
        end

        function fillValueKeysMatchExactly(tc)
            % The object carries "x-y", which is not a field. jsondecode would
            % rename it to x_y and move the real "x_y" key to x_y_1.
            dtypeJson = struct('name', "struct", 'configuration', struct('fields', ...
                struct('name', {'a'; 'x_y'}, 'data_type', {'int32'; 'int32'})));
            info = zarr.internal.dtype_info(dtypeJson);
            back = zarr.internal.decode_fill_value('{"a":1,"x-y":9,"x_y":5}', info);
            tc.verifyEqual(back.x_y, int32(5));
        end

        function fillValueFieldsKeepExactNumbers(tc)
            % Each field is decoded from its own text, as a scalar fill value
            % is: 64-bit integers beyond 2^53 and the sign of negative zero.
            fields = struct('name', {'big'; 'ubig'; 'neg'}, ...
                'data_type', {'int64'; 'uint64'; 'float64'});
            dtype = struct('name', "struct", 'configuration', struct('fields', fields));
            fillValue = struct('big', int64(-9007199254740993), ...
                'ubig', uint64(18446744073709551611), 'neg', -0.0);
            store = zarr.stores.MemoryStore();
            zarr.create(store, 2, dtype, FillValue=fillValue);

            back = zarr.open(store).meta.fillValue;
            tc.verifyEqual(back.big, fillValue.big);
            tc.verifyEqual(back.ubig, fillValue.ubig);
            tc.verifyEqual(typecast(back.neg, 'uint64'), typecast(-0.0, 'uint64'));
        end

        function malformedFillValueErrors(tc)
            % Neither an object nor a string, or a string of the wrong size.
            info = zarr.internal.dtype_info(tc.canonicalDtypeJson());
            for fillText = ["[7, 1.5, ""x""]", "0", "null", """AAAA"""]
                tc.verifyError(@() zarr.internal.decode_fill_value(fillText, info), ...
                    "zarr:InvalidFillValue", fillText);
            end
        end

        function createStructArrayEndToEnd(tc)
            % The public creation path: a data_type struct passed to
            % zarr.create, written and read back through zarr.open.
            import matlab.unittest.fixtures.TemporaryFolderFixture
            tempFixture = tc.applyFixture(TemporaryFolderFixture());
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

        function createFixedUtf32ArrayEndToEnd(tc)
            % The data_type struct form also creates a top-level
            % fixed_length_utf32 array; its unwritten element reads as "".
            store = zarr.stores.MemoryStore();
            dtype = struct('name', "fixed_length_utf32", 'configuration', struct('length_bytes', 16));
            z = zarr.create(store, 3, dtype, ChunkShape=2);
            z.write(["ab"; "cd"], 1);

            back = zarr.open(store).read();
            tc.verifyEqual(back, ["ab"; "cd"; ""]);
            [bytes, ~] = store.get("zarr.json");
            meta = jsondecode(native2unicode(bytes, 'UTF-8'));
            tc.verifyEqual(string(meta.data_type.name), "fixed_length_utf32");
            tc.verifyEqual(meta.data_type.configuration.length_bytes, 16);
        end

        function createRejectsNonStructRecordData(tc)
            import matlab.unittest.fixtures.TemporaryFolderFixture
            tempFixture = tc.applyFixture(TemporaryFolderFixture());
            storePath = fullfile(tempFixture.Folder, "rejects.zarr");
            fields = struct('name', {'id'}, 'data_type', {'int32'});
            dtype = struct('name', "struct", 'configuration', struct('fields', fields));
            z = zarr.create(storePath, 2, dtype);
            tc.verifyError(@() z.write([1 2]), "zarr:TypeMismatch");
        end

        function createRejectsIncompleteStructFillValue(tc)
            % FillValue must be a scalar struct with every field, at every level.
            store = zarr.stores.MemoryStore();
            dtype = tc.canonicalDtypeJson();
            tc.verifyError(@() zarr.create(store, 2, dtype, FillValue=struct('a', int32(1))), ...
                "zarr:TypeMismatch");
            twoRecords = struct('a', {int32(1); int32(2)}, 'b', 0, 'c', "");
            tc.verifyError(@() zarr.create(store, 2, dtype, FillValue=twoRecords), ...
                "zarr:TypeMismatch");

            pointType = struct('name', "struct", 'configuration', struct( ...
                'fields', struct('name', {'p'}, 'data_type', {'int16'})));
            nestedType = struct('name', "struct", 'configuration', struct( ...
                'fields', struct('name', {'pt'}, 'data_type', {pointType})));
            tc.verifyError(@() zarr.create(store, 2, nestedType, FillValue=struct('pt', struct())), ...
                "zarr:TypeMismatch");
            z = zarr.create(store, 2, nestedType, FillValue=struct('pt', struct('p', int16(5))));
            tc.verifyEqual(z.meta.fillValue.pt.p, int16(5));
        end

        function createRejectsMalformedDtype(tc)
            % dtype is one name or one struct, through zarr.create or a group.
            store = zarr.stores.MemoryStore();
            dtype = tc.canonicalDtypeJson();
            tc.verifyError(@() zarr.create(store, 2, [dtype; dtype]), "zarr:UnsupportedDataType");
            tc.verifyError(@() zarr.create(store, 2, ["int32", "int8"]), "zarr:UnsupportedDataType");
            tc.verifyError(@() zarr.create(store, 2, 42), "zarr:UnsupportedDataType");
            g = zarr.create_group(store);
            tc.verifyError(@() g.createArray("x", 2, [dtype; dtype]), "zarr:UnsupportedDataType");
        end

        function createRejectsConfiguredDtypeNamedWithoutConfig(tc)
            import matlab.unittest.fixtures.TemporaryFolderFixture
            tempFixture = tc.applyFixture(TemporaryFolderFixture());
            storePath = fullfile(tempFixture.Folder, "noconfig.zarr");
            tc.verifyError(@() zarr.create(storePath, 2, "struct"), ...
                "zarr:InvalidMetadata");
        end

        function oneFieldStructWritesFieldsAsList(tc)
            % A fields list with one entry is written as a one-element list,
            % at the top level and in a nested structured field.
            store = zarr.stores.MemoryStore();
            inner = struct('name', "struct", 'configuration', struct( ...
                'fields', struct('name', {'p'}, 'data_type', {'int16'})));
            dtype = struct('name', "struct", 'configuration', struct( ...
                'fields', struct('name', {'pt'}, 'data_type', {inner})));
            z = zarr.create(store, 2, dtype);
            z.write(struct('pt', {struct('p', int16(3)); struct('p', int16(4))}));

            [bytes, ~] = store.get("zarr.json");
            outerFields = tc.writtenFieldsList(native2unicode(bytes, 'UTF-8'));
            tc.verifyClass(outerFields, 'cell');
            tc.verifyNumElements(outerFields, 1);
            outerEntry = outerFields{1};
            innerType = outerEntry{"data_type"};
            innerConfiguration = innerType{"configuration"};
            innerFields = innerConfiguration{"fields"};
            tc.verifyClass(innerFields, 'cell');
            tc.verifyNumElements(innerFields, 1);

            back = zarr.open(store).read();
            tc.verifyEqual(back(2).pt.p, int16(4));
        end

        function metadataRewriteKeepsOneFieldList(tc)
            % zarr-python writes a one-field list, which jsondecode reads as a
            % 1x1 struct. Rewriting the metadata must keep it a list.
            store = zarr.stores.MemoryStore();
            metaText = ['{"zarr_format":3,"node_type":"array","shape":[2],', ...
                '"data_type":{"name":"struct","configuration":{"fields":[{"name":"id","data_type":"int32"}]}},', ...
                '"chunk_grid":{"name":"regular","configuration":{"chunk_shape":[2]}},', ...
                '"chunk_key_encoding":{"name":"default","configuration":{"separator":"/"}},', ...
                '"fill_value":{"id":0},"codecs":[{"name":"bytes","configuration":{"endian":"little"}}]}'];
            store.set("zarr.json", unicode2native(metaText, 'UTF-8'));

            z = zarr.open(store);
            z.setAttrs(struct('note', "rewritten"));

            [bytes, ~] = store.get("zarr.json");
            fields = tc.writtenFieldsList(native2unicode(bytes, 'UTF-8'));
            tc.verifyClass(fields, 'cell');
            tc.verifyNumElements(fields, 1);
        end

        function handBuiltMetadataWritesOneFieldList(tc)
            % ArrayMetadata built directly, with the fields list as the 1x1
            % struct jsondecode would give, is written with a list too.
            meta = zarr.metadata.ArrayMetadata();
            meta.shape = 2;
            meta.dataType = "struct";
            meta.dataTypeConfig = struct('fields', struct('name', {'id'}, 'data_type', {'int32'}));
            meta.chunkShape = 2;
            meta.fillValue = struct('id', int32(0));
            meta.codecs = {zarr.codecs.BytesCodec()};

            fields = tc.writtenFieldsList(meta.toJsonText());
            tc.verifyClass(fields, 'cell');
            tc.verifyNumElements(fields, 1);
        end

        function fieldNamesThatAreNotIdentifiers(tc)
            % "x-y" is not a MATLAB identifier. Its valid name, "x_y", is also
            % the second field's name, so the second field gets a distinct one.
            dtypeJson = struct('name', "structured", 'configuration', struct( ...
                'fields', {{{'x-y', 'int32'}; {'x_y', 'int16'}}}));
            info = zarr.internal.dtype_info(dtypeJson);
            tc.verifyEqual([info.fields.Name], ["x-y", "x_y"]);
            tc.verifyEqual([info.fields.MatlabName], ["x_y", "x_y_1"]);

            meta = zarr.metadata.ArrayMetadata();
            meta.shape = 2;
            meta.dataType = "structured";
            meta.dataTypeConfig = info.config;
            meta.chunkShape = 2;
            meta.fillValue = zarr.internal.default_structured_fill_value(info);
            meta.codecs = {zarr.codecs.BytesCodec()};
            store = zarr.stores.MemoryStore();
            store.set("zarr.json", unicode2native(char(meta.toJsonText()), 'UTF-8'));

            records = struct('x_y', {int32(1); int32(2)}, 'x_y_1', {int16(-1); int16(-2)});
            zarr.Array(store, "", meta).write(records);
            back = zarr.open(store).read();
            tc.verifyEqual([back.x_y], int32([1 2]));
            tc.verifyEqual([back.x_y_1], int16([-1 -2]));

            % The metadata keeps the original names.
            [bytes, ~] = store.get("zarr.json");
            tc.verifySubstring(native2unicode(bytes, 'UTF-8'), '"x-y"');
        end

        function canonicalNonIdentifierFieldNames(tc)
            % FillValue and the decoded fill value use the MATLAB names, while
            % the fill_value object in zarr.json keeps the names as written.
            fields = struct('name', {'x-y'; 'x_y'}, 'data_type', {'int32'; 'int16'});
            dtype = struct('name', "struct", 'configuration', struct('fields', fields));
            store = zarr.stores.MemoryStore();
            tc.verifyError(@() zarr.create(store, 3, dtype, FillValue=struct('x_y', int32(7))), ...
                "zarr:TypeMismatch");
            z = zarr.create(store, 3, dtype, FillValue=struct('x_y', int32(7), 'x_y_1', int16(-1)));
            z.write(struct('x_y', {int32(1); int32(2)}, 'x_y_1', {int16(3); int16(4)}), 1);

            back = zarr.open(store).read();
            tc.verifyEqual([back.x_y], int32([1 2 7]));
            tc.verifyEqual([back.x_y_1], int16([3 4 -1]));
            [bytes, ~] = store.get("zarr.json");
            meta = zarr.internal.json_decode_exact(native2unicode(bytes, 'UTF-8'));
            fillValue = meta{"fill_value"};
            tc.verifyEqual(fillValue{"x-y"}, 7);
            tc.verifyEqual(fillValue{"x_y"}, -1);
        end
    end

    properties (TestParameter)
        endianCase = {"little", "big"};
    end
end
