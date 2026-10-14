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

        function byteRangeReadsGoToInnerStore(tc)
            tc.store.prefetch("a");

            part = tc.store.getPartial("a", 1, 2);
            parts = tc.store.getPartialMany(["a", "b"], [0 1], [1 1]);
            suffix = tc.store.getSuffix("a", 1);

            tc.verifyEqual(part, uint8([2 3]));
            tc.verifyEqual(parts, {uint8(1), uint8(5)});
            tc.verifyEqual(suffix, uint8(3));
            tc.verifyEqual(tc.inner.nPartialGets, 3);
            tc.verifyEqual(tc.inner.nSuffixGets, 1);
        end

        function arrayReadsPrefetchedChunk(tc)
            zarr.create(tc.inner, [4 1], "int16", Path="x").write(int16((1:4)'));
            tc.store.prefetch("x/c/0/0");
            readsAfterPrefetch = tc.inner.nFullGets;

            values = zarr.open(tc.store, Path="x");

            tc.verifyEqual(values(:), int16((1:4)'));
            tc.verifyEqual(tc.inner.nFullGets, readsAfterPrefetch);
        end

        function listingGoesToInnerStore(tc)
            tc.verifyEqual(sort(tc.store.list()), sort(tc.inner.list()));
            tc.verifyTrue(tc.store.exists("a"));
        end
    end
end
