classdef TestAttributes < matlab.unittest.TestCase
    %Attribute keys that jsondecode/jsonencode cannot represent.
    %
    %   Attributes are exposed as a cell-valued dictionary rather than a
    %   struct so that a key is whatever the file says. Keys beginning with
    %   an underscore are the case that matters in practice: the hdmf-zarr
    %   Zarr v3 convention names every reserved attribute that way
    %   (_DTYPE, _LINKS, _REFERENCE_FIELDS, and _REFERENCE inside an
    %   attribute value), and a struct cannot hold any of them.

    properties (Constant)
        % One attribute of each kind the hdmf-zarr convention uses.
        ConventionJson = ['{"_DTYPE":"object_reference",' ...
            '"_REFERENCE_FIELDS":["electrode"],' ...
            '"_LINKS":[{"name":"device","source":".","path":"/general/devices/probe"}],' ...
            '"table":{"_REFERENCE":{"path":"/general/electrodes","source":"."}},' ...
            '"units":"mV"}']
    end

    methods (Test)
        function decodeKeepsKeysExactly(tc)
            d = zarr.internal.json_decode_exact(tc.ConventionJson);
            tc.verifyEqual(keys(d), ...
                ["_DTYPE"; "_REFERENCE_FIELDS"; "_LINKS"; "table"; "units"]);
            tc.verifyEqual(d{"_DTYPE"}, "object_reference");
            tc.verifyEqual(keys(d{"table"}), "_REFERENCE", ...
                'a key nested inside an attribute value is exact too');
            tc.verifyEqual(d{"table"}{"_REFERENCE"}{"path"}, "/general/electrodes");
        end

        function jsondecodeMangledTheseKeys(tc)
            % The behaviour this class exists to replace: without the exact
            % decoder every reserved name comes back renamed, and there is
            % no way to get the original back.
            mangled = jsondecode(tc.ConventionJson);
            tc.verifyTrue(isfield(mangled, 'x_DTYPE'));
            tc.verifyFalse(isfield(mangled, '_DTYPE'));
        end

        function roundTripIsByteIdentical(tc)
            d = zarr.internal.json_decode_exact(tc.ConventionJson);
            tc.verifyEqual(char(zarr.internal.json_encode_exact(d)), tc.ConventionJson);
        end

        function singleElementListStaysAList(tc)
            % _REFERENCE_FIELDS with one field must not read back as a bare
            % string and write out as one: hdmf-zarr expects a JSON list.
            d = zarr.internal.json_decode_exact(tc.ConventionJson);
            tc.verifyClass(d{"_REFERENCE_FIELDS"}, 'cell');
            tc.verifySubstring(char(zarr.internal.json_encode_exact(d)), ...
                '"_REFERENCE_FIELDS":["electrode"]');
        end

        function nullAndEmptyListStayDistinct(tc)
            txt = '{"nothing":null,"emptylist":[]}';
            d = zarr.internal.json_decode_exact(txt);
            tc.verifyEqual(d{"nothing"}, []);
            tc.verifyEqual(d{"emptylist"}, cell(0, 1));
            tc.verifyEqual(char(zarr.internal.json_encode_exact(d)), txt);
        end

        function nonFiniteNumbersDecode(tc)
            % zarr-python writes bare NaN/Infinity tokens, which are its
            % extension to JSON rather than part of the standard.
            d = zarr.internal.json_decode_exact('{"a":NaN,"b":Infinity,"c":-Infinity}');
            tc.verifyEqual([d{"a"}, d{"b"}, d{"c"}], [NaN, Inf, -Inf]);
        end

        function nonFiniteNumbersEncodeAsTokens(tc)
            % Written as bare tokens, not null: null reads back as None in
            % zarr-python, losing the value, and a quoted "NaN" would read
            % back as a string rather than a float.
            txt = '{"a":NaN,"b":Infinity,"c":-Infinity}';
            tc.verifyEqual(char(zarr.internal.json_encode_exact( ...
                zarr.internal.json_decode_exact(txt))), txt);
        end

        function nonFiniteInsideAnArray(tc)
            d = dictionary(string.empty, {});
            d("series") = {[1 NaN 3]};
            tc.verifyEqual(char(zarr.internal.json_encode_exact(d)), ...
                '{"series":[1,NaN,3]}');
        end

        function nonFiniteKeepsJsonencodeNesting(tc, ndShape)
            % Non-finite values are substituted into jsonencode's own
            % output, so the nesting must be untouched at any rank. Mapping
            % the tokens back to null has to reproduce jsonencode exactly.
            v = reshape(1:prod(ndShape), ndShape);
            v(2) = NaN;
            v(end) = Inf;
            written = char(zarr.internal.json_encode_exact(v));
            asNull = strrep(strrep(written, 'NaN', 'null'), 'Infinity', 'null');
            tc.verifyEqual(asNull, char(jsonencode(v)));
        end

        function finiteNumbersAreUntouched(tc)
            % The non-finite path must not capture ordinary numbers.
            v = [1 2.5 -3];
            tc.verifyEqual(char(zarr.internal.json_encode_exact(v)), char(jsonencode(v)));
        end

        function fillValueKeepsQuotedForm(tc)
            % A fill_value is not an attribute: the Zarr v3 specification
            % gives it quoted "NaN", so it must not follow the bare-token
            % rule that applies to attributes.
            info = zarr.internal.dtype_info("float64");
            tc.verifyEqual(char(zarr.internal.encode_fill_value_json(NaN, info)), '"NaN"');
            tc.verifyEqual(char(zarr.internal.encode_fill_value_json(Inf, info)), '"Infinity"');
        end

        function setAttrWritesUnderscoreKey(tc)
            store = tc.tempStore();
            g = zarr.create_group(store);
            g.setAttr("_DTYPE", "object_reference");
            tc.verifySubstring(tc.readJson(store), '"_DTYPE":"object_reference"');
            tc.verifyEqual(zarr.open(store).attrs{"_DTYPE"}, "object_reference");
        end

        function createAcceptsDictionaryAttributes(tc)
            store = tc.tempStore();
            attrs = dictionary(string.empty, {});
            attrs("_DTYPE") = {"object_reference"};
            attrs("_REFERENCE_FIELDS") = {{"electrode"}};
            zarr.create(store, 2, "string", Attributes=attrs);
            back = zarr.open(store).attrs;
            tc.verifyEqual(back{"_DTYPE"}, "object_reference");
            tc.verifyEqual(back{"_REFERENCE_FIELDS"}, {"electrode"});
        end

        function structAttributesStillAccepted(tc)
            % Existing callers pass a struct; keys that are valid MATLAB
            % identifiers must keep working unchanged.
            store = tc.tempStore();
            zarr.create_group(store, Attributes=struct('units', 'mV', 'n', 3));
            back = zarr.open(store).attrs;
            tc.verifyEqual(back{"units"}, "mV");
            tc.verifyEqual(back{"n"}, 3);
        end

        function readModifyWriteLeavesFileUnchanged(tc)
            % The round trip a caller performs when adding a link: read the
            % attributes, hand them straight back, and the file must match.
            store = tc.tempStore();
            g = zarr.create_group(store);
            g.setAttrs(zarr.internal.json_decode_exact(tc.ConventionJson));
            before = tc.readJson(store);
            g2 = zarr.open(store);
            g2.setAttrs(g2.attrs);
            tc.verifyEqual(tc.readJson(store), before);
        end

        function keysNeedingNoIdentifierAreExactToo(tc)
            store = tc.tempStore();
            g = zarr.create_group(store);
            awkward = ["chunk size", "2d-extent", "1st", "µ units"];
            for k = awkward
                g.setAttr(k, "v");
            end
            tc.verifyEqual(sort(keys(zarr.open(store).attrs)), sort(awkward(:)));
        end
    end

    properties (TestParameter)
        % Shapes that pin jsonencode's nesting: a singleton middle
        % dimension stays a nesting level ([2 1 2]) while an array with one
        % non-singleton dimension flattens ([1 1 2]).
        ndShape = {[2 2], [2 3], [2 2 2], [2 1 2], [1 1 2], [3 2 2], [2 2 2 2]}
    end

    methods
        function store = tempStore(tc)
            import matlab.unittest.fixtures.TemporaryFolderFixture
            f = tc.applyFixture(TemporaryFolderFixture);
            store = fullfile(f.Folder, "attrs.zarr");
        end

        function txt = readJson(~, store)
            txt = string(fileread(fullfile(store, "zarr.json")));
        end
    end
end
