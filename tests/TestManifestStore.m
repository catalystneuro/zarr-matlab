classdef TestManifestStore < matlab.unittest.TestCase
    %ManifestStore: virtual chunk resolution via byte ranges and inline data.

    properties
        work
    end

    methods (TestMethodSetup)
        function makeWork(tc)
            tc.work = fullfile(tempdir, "zm_manifest_" + string(feature('getpid')) + ...
                "_" + string(randi(1e9)));
            mkdir(tc.work);
        end
    end

    methods (TestMethodTeardown)
        function rmWork(tc)
            if isfolder(tc.work), rmdir(tc.work, 's'); end
        end
    end

    methods (Static)
        function [indexDir, d] = buildIndexed(work, useShards)
            %"Kerchunk" a real zarr store: chunks packed into one blob file
            %at nonzero offsets, one chunk inlined, metadata copied.
            src = zarr.stores.MemoryStore();
            if useShards
                z = zarr.create(src, [8 8], "int32", Path="a", ChunkShape=[2 2], ...
                    ShardShape=[4 4], Codecs={zarr.codecs.GzipCodec(5)});
            else
                z = zarr.create(src, [8 8], "int32", Path="a", ChunkShape=[4 4], ...
                    Codecs={zarr.codecs.GzipCodec(5)});
            end
            d = reshape(int32(1:64), [8 8]);
            z.write(d);

            indexDir = fullfile(work, "index.zarr");
            mkdir(fullfile(indexDir, "a"));
            blobPath = fullfile(work, "data.bin");
            bfid = fopen(blobPath, 'w');
            fwrite(bfid, uint8(7) * ones(1, 13, 'uint8'));  % padding: offsets != 0
            entries = strings(0, 1);
            inlined = false;
            for key = reshape(src.list(), 1, [])
                [bytes, ~] = src.get(key);
                if endsWith(key, "zarr.json")
                    fid = fopen(fullfile(indexDir, strjoin(split(key, "/"), filesep)), 'w');
                    fwrite(fid, bytes);
                    fclose(fid);
                elseif ~inlined
                    inlined = true;  % first chunk: inline
                    entries(end + 1) = """" + key + """:{""inline"":""" + ...
                        string(matlab.net.base64encode(bytes)) + """}"; %#ok<AGROW>
                else
                    offset = ftell(bfid);
                    fwrite(bfid, bytes);
                    entries(end + 1) = """" + key + """:{""path"":""../data.bin""," + ...
                        """offset"":" + offset + ",""length"":" + numel(bytes) + "}"; %#ok<AGROW>
                end
            end
            fclose(bfid);
            mfid = fopen(fullfile(indexDir, "manifest.json"), 'w');
            fwrite(mfid, unicode2native(char("{""manifest_format"":1,""chunks"":{" + ...
                strjoin(entries, ",") + "}}"), 'UTF-8'));
            fclose(mfid);
        end
    end

    methods (Test)
        function virtualReadMatchesOriginal(tc)
            [indexDir, d] = TestManifestStore.buildIndexed(tc.work, false);
            store = zarr.stores.ManifestStore(indexDir);
            z = zarr.open(store, Path="a");
            tc.verifyEqual(z(:, :), d);
            tc.verifyEqual(z(3:6, 2:7), d(3:6, 2:7));
        end

        function shardedPartialReadsThroughManifest(tc)
            % exercises getPartial/getSuffix against byte-range entries
            [indexDir, d] = TestManifestStore.buildIndexed(tc.work, true);
            store = zarr.stores.ManifestStore(indexDir);
            z = zarr.open(store, Path="a");
            tc.verifyEqual(z(1:2, 1:2), d(1:2, 1:2));
            tc.verifyEqual(z(:, :), d);
        end

        function readOnlyAndMissing(tc)
            [indexDir, ~] = TestManifestStore.buildIndexed(tc.work, false);
            store = zarr.stores.ManifestStore(indexDir);
            tc.verifyError(@() store.set("x", uint8(1)), "zarr:StoreError");
            [~, found] = store.get("nope");
            tc.verifyFalse(found);
            tc.verifyError(@() zarr.stores.ManifestStore(fullfile(tc.work, "absent")), ...
                "zarr:StoreError");
        end

        function relativePathResolution(tc)
            tc.verifyEqual(zarr.internal.resolve_relative("/a/b/index", "../data.bin"), ...
                "/a/b/data.bin");
            tc.verifyEqual(zarr.internal.resolve_relative( ...
                "https://h.com/x/index", "../y/d.bin"), "https://h.com/x/y/d.bin");
            tc.verifyEqual(zarr.internal.resolve_relative("/a", "https://h.com/d"), ...
                "https://h.com/d");
            % pop-to-empty then append (sidecar-next-to-file layout)
            tc.verifyEqual(zarr.internal.resolve_relative( ...
                "https://h.com:8080/data.mat.zarr", "../data.mat"), ...
                "https://h.com:8080/data.mat");
            tc.verifyError(@() zarr.internal.resolve_relative("https://h.com/x", ...
                "../../../d"), "zarr:StoreError");
        end

        function relativeBaseKeepsLeadingParents(tc)
            % A relative base resolves against the current folder, so ".."
            % past its first segment stays in the result.
            tc.verifyEqual(zarr.internal.resolve_relative("../idx.zarr", "../../data.bin"), ...
                "../../data.bin");
            tc.verifyEqual(zarr.internal.resolve_relative("idx.zarr", "../../data.bin"), ...
                "../data.bin");
            tc.verifyEqual(zarr.internal.resolve_relative("./idx.zarr", "../../data.bin"), ...
                "../data.bin");
            tc.verifyEqual(zarr.internal.resolve_relative("a/idx.zarr", "../data.bin"), ...
                "a/data.bin");
            tc.verifyError(@() zarr.internal.resolve_relative("/idx.zarr", "../../data.bin"), ...
                "zarr:StoreError");
        end

        function dotDotInBaseIsResolved(tc)
            % A ".." inside the base names its parent, as it does in rel.
            tc.verifyEqual(zarr.internal.resolve_relative("/a/b/../idx.zarr", "../../x"), "/x");
            tc.verifyEqual(zarr.internal.resolve_relative( ...
                "https://h.com/a/b/../idx", "../../x"), "https://h.com/x");
            tc.verifyEqual(zarr.internal.resolve_relative("a/../idx.zarr", "../../x"), "../x");
            tc.verifyError(@() zarr.internal.resolve_relative( ...
                "https://h.com/a/../idx", "../../x"), "zarr:StoreError");
        end

        function driveIsTheRootOfAWindowsPath(tc)
            % A ".." cannot climb above the drive.
            tc.verifyEqual(zarr.internal.resolve_relative("C:\data\idx.zarr", "../x"), "C:/data/x");
            tc.verifyEqual(zarr.internal.resolve_relative("C:/data/idx.zarr", "../../x"), "C:/x");
            tc.verifyError(@() zarr.internal.resolve_relative("C:/data/idx.zarr", "../../../x"), ...
                "zarr:StoreError");
        end

        function uncShareIsTheRootOfAPath(tc)
            % A UNC path keeps its leading "//", and ".." cannot climb above
            % the share.
            tc.verifyEqual(zarr.internal.resolve_relative("\\server\share\idx.zarr", "data.bin"), ...
                "//server/share/idx.zarr/data.bin");
            tc.verifyEqual(zarr.internal.resolve_relative("//server/share/a/idx.zarr", "../../x"), ...
                "//server/share/x");
            tc.verifyError(@() zarr.internal.resolve_relative("\\server\share\idx.zarr", "../../x"), ...
                "zarr:StoreError");
        end
    end
end
