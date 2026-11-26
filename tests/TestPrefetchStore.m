classdef TestPrefetchStore < matlab.unittest.TestCase
    %Store wrapper that serves reads from values fetched in advance.

    properties
        inner
        store
    end

    methods (TestMethodSetup)
        function createStores(tc)
            tc.inner = CountingStore();
            tc.inner.set("a", uint8([1 2 3]));
            tc.inner.set("b", uint8([4 5]));
            tc.store = zarr.stores.PrefetchStore(tc.inner);
        end
    end

    methods (Test)
        function prefetchedValuesAnswerReads(tc)
            % A prefetched key is read once, and a later change to the
            % inner store is not seen.
            tc.store.prefetch(["a", "b"]);
            tc.inner.set("a", uint8(9));
            readsAfterPrefetch = tc.inner.nFullGets;

            [data, found] = tc.store.get("a");

            tc.verifyTrue(found);
            tc.verifyEqual(data, uint8([1 2 3]));
            tc.verifyEqual(tc.inner.nFullGets, readsAfterPrefetch);
        end

        function prefetchingTwiceFetchesOnce(tc)
            tc.store.prefetch("a");
            tc.store.prefetch(["a", "b"]);

            tc.verifyEqual(tc.inner.nFullGets, 2);
        end

        function keyRepeatedInOneCallIsFetchedOnce(tc)
            tc.store.prefetch(["a", "a", "b", "a"]);

            tc.verifyEqual(tc.inner.nFullGets, 2);
        end

        function absentKeyIsRememberedAsAbsent(tc)
            tc.store.prefetch("missing");

            [data, found] = tc.store.get("missing");

            tc.verifyFalse(found);
            tc.verifyEmpty(data);
        end

        function keyNotPrefetchedIsReadFromInnerStore(tc)
            tc.store.prefetch("a");

            [data, found] = tc.store.get("b");

            tc.verifyTrue(found);
            tc.verifyEqual(data, uint8([4 5]));
        end

        function writesDropPrefetchedValues(tc)
            tc.store.prefetch(["a", "b"]);

            tc.store.set("a", uint8(7));
            tc.store.erase("b");

            tc.verifyEqual(tc.store.get("a"), uint8(7));
            [~, found] = tc.store.get("b");
            tc.verifyFalse(found);
        end

        function getManyMixesPrefetchedAndOtherKeys(tc)
            tc.store.prefetch(["a", "missing"]);

            [values, found] = tc.store.getMany(["b", "a", "missing"]);

            tc.verifyEqual(found, [true true false]);
            tc.verifyEqual(values{1}, uint8([4 5]));
            tc.verifyEqual(values{2}, uint8([1 2 3]));
        end

        function existsIsAnsweredFromPrefetchedValue(tc)
            % exists agrees with get: a later change to the inner store
            % is not seen for a prefetched key.
            tc.store.prefetch(["a", "missing"]);
            tc.inner.erase("a");
            tc.inner.set("missing", uint8(1));

            tc.verifyTrue(tc.store.exists("a"));
            tc.verifyFalse(tc.store.exists("missing"));
            tc.verifyTrue(tc.store.exists("b"));
        end

        function byteRangeReadsOfPrefetchedKeyUsePrefetchedValue(tc)
            % The ranges are taken from the prefetched value: the inner
            % store is not read, and a later change to it is not seen.
            tc.store.prefetch(["a", "missing"]);
            tc.inner.set("a", uint8([7 8 9]));

            part = tc.store.getPartial("a", 1, 2);
            suffix = tc.store.getSuffix("a", 1);
            [~, partFound] = tc.store.getPartial("missing", 0, 1);
            [~, suffixFound] = tc.store.getSuffix("missing", 1);

            tc.verifyEqual(part, uint8([2 3]));
            tc.verifyEqual(suffix, uint8(3));
            tc.verifyFalse(partFound);
            tc.verifyFalse(suffixFound);
            tc.verifyEqual(tc.inner.nPartialGets, 0);
            tc.verifyEqual(tc.inner.nSuffixGets, 0);
        end

        function byteRangeReadsOfOtherKeysGoToInnerStore(tc)
            tc.store.prefetch("a");

            part = tc.store.getPartial("b", 1, 1);
            suffix = tc.store.getSuffix("b", 1);

            tc.verifyEqual(part, uint8(5));
            tc.verifyEqual(suffix, uint8(5));
            tc.verifyEqual(tc.inner.nPartialGets, 1);
            tc.verifyEqual(tc.inner.nSuffixGets, 1);
        end

        function getPartialManyMixesPrefetchedAndOtherKeys(tc)
            tc.store.prefetch(["a", "missing"]);

            [values, found] = tc.store.getPartialMany(["b", "a", "missing"], [1 0 0], [1 2 1]);

            tc.verifyEqual(found, [true true false]);
            tc.verifyEqual(values{1}, uint8(5));
            tc.verifyEqual(values{2}, uint8([1 2]));
            tc.verifyEmpty(values{3});
            tc.verifyEqual(tc.inner.nPartialGets, 1);
        end

        function arrayReadsPrefetchedChunk(tc)
            zarr.create(tc.inner, [4 1], "int16", Path="x").write(int16((1:4)'));
            tc.store.prefetch("x/c/0/0");
            readsAfterPrefetch = tc.inner.nFullGets;

            array = zarr.open(tc.store, Path="x");

            tc.verifyEqual(array(:), int16((1:4)'));
            tc.verifyEqual(tc.inner.nFullGets, readsAfterPrefetch);
        end

        function arrayReadsPartOfPrefetchedChunk(tc)
            % A region that covers part of an uncompressed chunk is read
            % with a byte-range read.
            zarr.create(tc.inner, [8 1], "int16", Path="x").write(int16((1:8)'));
            tc.store.prefetch("x/c/0/0");
            tc.inner.resetCounts();

            array = zarr.open(tc.store, Path="x");

            tc.verifyEqual(array(1:2, 1), int16([1; 2]));
            tc.verifyEqual(tc.inner.nPartialGets, 0);
            tc.verifyEqual(tc.inner.nFullGets, 0);
        end

        function arrayReadsPrefetchedShard(tc)
            % Every read of a sharded array is a byte-range read of a shard.
            expected = int32(reshape(1:64, 8, 8));
            sharded = zarr.create(tc.inner, [8 8], "int32", ChunkShape=[2 2], ShardShape=[8 8], Path="s");
            sharded.write(expected);
            tc.store.prefetch("s/c/0/0");
            tc.inner.resetCounts();

            array = zarr.open(tc.store, Path="s");

            tc.verifyEqual(array(:, :), expected);
            tc.verifyEqual(tc.inner.nPartialGets, 0);
            tc.verifyEqual(tc.inner.nSuffixGets, 0);
            tc.verifyEqual(tc.inner.nFullGets, 0);
        end

        function listingGoesToInnerStore(tc)
            tc.verifyEqual(sort(tc.store.list()), sort(tc.inner.list()));
            tc.verifyTrue(tc.store.exists("a"));
        end
    end
end
