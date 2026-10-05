classdef TestPartialRead < matlab.unittest.TestCase
    %Partial reads of uncompressed chunks: only the rows along the first
    %axis that a region touches are fetched, with one ranged request. A
    %region that touches a single row is narrowed along the next axis.

    methods (Test)
        function readsOnlyTouchedRows(tc)
            [z, probe, d] = TestPartialRead.int16Array([10000 10], [10000 10]);
            tc.verifyEqual(z(501:600, 4), d(501:600, 4));
            tc.verifyEqual(probe.nFullGets, 0);
            tc.verifyEqual(probe.nPartialGets, 1);
            tc.verifyEqual(probe.bytesRead, 100 * 10 * 2);
        end

        function singleElementReadsOneItem(tc)
            [z, probe, d] = TestPartialRead.int16Array([10000 10], [10000 10]);
            tc.verifyEqual(z(778, 6), d(778, 6));
            tc.verifyEqual(probe.partialRanges, [(777 * 10 + 5) * 2, 2]);
        end

        function singleRowReadsOnlyTouchedColumns(tc)
            [z, probe, d] = TestPartialRead.int16Array([10000 10], [10000 10]);
            tc.verifyEqual(z(778, 3:6), d(778, 3:6));
            tc.verifyEqual(probe.partialRanges, [(777 * 10 + 2) * 2, 4 * 2]);
        end

        function singleFrameIsNarrowedAlongNextAxis(tc)
            % A [20 30 10] chunk of int16: a frame is 600 bytes, a row 20.
            frame = 7 * 600;
            cases = {
                {8, 11:20, 6:9},  [frame + 10 * 20, 10 * 20]       % rows of a frame
                {8, 11:20, ':'},  [frame + 10 * 20, 10 * 20]
                {8, 11, 6:9},     [frame + 10 * 20 + 5 * 2, 4 * 2]  % columns of a row
                {8, 11, 6},       [frame + 10 * 20 + 5 * 2, 2]      % a point
                {8, ':', 6:9},    [frame, 600]                      % a whole frame
                {8:9, 11:20, 6:9}, [frame, 2 * 600]                 % two frames, read whole
                {8, 11:3:20, 6},  [frame + 10 * 20, 10 * 20]        % rows 11 to 20
            };
            [z, probe, d] = TestPartialRead.int16Array([20 30 10], [20 30 10]);
            for k = 1:size(cases, 1)
                idx = cases{k, 1};
                probe.resetCounts();
                tc.verifyEqual(z(idx{:}), d(idx{:}), sprintf("case %d", k));
                tc.verifyEqual(probe.nFullGets, 0, sprintf("case %d", k));
                tc.verifyEqual(probe.partialRanges, cases{k, 2}, sprintf("case %d", k));
            end
        end

        function narrowsEachChunkARegionSpans(tc)
            % Chunks of [5 4 6]: a frame is 24 items, a row 6.
            [z, probe, d] = TestPartialRead.int16Array([10 8 6], [5 4 6]);
            tc.verifyEqual(z(7, 3:6, 2), d(7, 3:6, 2));
            % Frame 7 is index 1 of its chunks; rows 3:4 and 5:6 fall in two chunks.
            tc.verifyEqual(probe.nFullGets, 0);
            tc.verifyEqual(sortrows(probe.partialRanges), ...
                [(24 + 0) * 2, 2 * 6 * 2; (24 + 2 * 6) * 2, 2 * 6 * 2]);
        end

        function blocksAreReadInBatches(tc)
            % One column of 100 single-row chunks: each chunk is covered in
            % part, which is more than one batch of ranged reads.
            [z, probe, d] = TestPartialRead.int16Array([100 4], [1 4]);
            tc.verifyEqual(z.read([1 2], [100 1]), d(:, 2));
            tc.verifyEqual(probe.nFullGets, 0);
            tc.verifyEqual(probe.partialRanges, repmat([2 2], 100, 1));
        end

        function partialAndWholeChunksInOneRead(tc)
            % Rows 2 to 199 of two-row chunks: the first and last chunk are
            % covered in part, and the 98 between them are read whole.
            [z, probe, d] = TestPartialRead.int16Array([200 4], [2 4]);
            tc.verifyEqual(z.read([2 1], [198 4]), d(2:199, :));
            tc.verifyEqual(probe.nPartialGets, 2);
            tc.verifyEqual(probe.nFullGets, 98);
        end

        function axesOfLengthOneArePassedThrough(tc)
            [z, probe, d] = TestPartialRead.int16Array([1 30 10], [1 30 10]);
            tc.verifyEqual(z(1, 11:20, 6:9), d(1, 11:20, 6:9));
            tc.verifyEqual(probe.partialRanges, [10 * 20, 10 * 20]);
            probe.resetCounts();
            tc.verifyEqual(z(1, :, 6:9), d(1, :, 6:9));  % the whole chunk
            tc.verifyEqual(probe.nFullGets, 1);
            tc.verifyEqual(probe.nPartialGets, 0);
        end

        function missingChunkIsFillWhenNarrowed(tc)
            z = zarr.create(CountingStore(), [10 6 4], "int16", ChunkShape=[10 6 4], ...
                FillValue=7);
            tc.verifyEqual(z(4, 2:3, :), repmat(int16(7), 1, 2, 4));
        end

        function steppedIndexReadsBoundingRows(tc)
            [z, probe, d] = TestPartialRead.int16Array([10000 10], [10000 10]);
            tc.verifyEqual(z(11:3:20, :), d(11:3:20, :));
            tc.verifyEqual(probe.bytesRead, 10 * 10 * 2);  % rows 11 to 20
        end

        function allRowsReadWhole(tc)
            [z, probe, d] = TestPartialRead.int16Array([1000 10], [1000 10]);
            tc.verifyEqual(z(:, 3), d(:, 3));
            tc.verifyEqual(probe.nFullGets, 1);
            tc.verifyEqual(probe.nPartialGets, 0);
        end

        function readsTouchedRowsOfEachChunk(tc)
            [z, probe, d] = TestPartialRead.int16Array([4000 10], [1000 10]);
            tc.verifyEqual(z(991:1010, 3), d(991:1010, 3));
            tc.verifyEqual(probe.nFullGets, 0);
            tc.verifyEqual(probe.nPartialGets, 2);
            tc.verifyEqual(probe.bytesRead, 2 * 10 * 10 * 2);
        end

        function compressedChunksReadWhole(tc)
            [z, probe, d] = TestPartialRead.int16Array([1000 10], [1000 10], ...
                {zarr.codecs.GzipCodec(5)});
            tc.verifyEqual(z(11:20, 1), d(11:20, 1));
            tc.verifyEqual(probe.nFullGets, 1);
            tc.verifyEqual(probe.nPartialGets, 0);
        end

        function missingChunkIsFill(tc)
            z = zarr.create(CountingStore(), [100 4], "int16", ChunkShape=[100 4], ...
                FillValue=7);
            tc.verifyEqual(z(11:20, :), repmat(int16(7), 10, 4));
        end

        function valuesMatchWholeChunkReads(tc)
            % Same data written with and without a compressor; the gzip
            % array reads whole chunks, so it is the reference.
            dtypes = ["int16", "float64", "uint8", "bool"];
            shapes = {37, [23 5], [31 4 3]};
            chunks = {10, [8 5], [10 4 2]};
            regions = {
                {4:9, 20, 31:37}
                {{4:9, ':'}, {12, 2:4}, {1:3:23, 5}, {12, ':'}, {23, 5}, {9, 1:2:5}}
                {{4:9, ':', ':'}, {17, 2, 3}, {11:2:30, 1:3, 2}, {17, 2:3, ':'}, ...
                    {17, ':', 2}, {5, 3, 1:2}, {31, 4, 3}, {10:11, 2, 3}, {20, 1:4, 1:2:3}}
            };
            for k = 1:numel(dtypes)
                for r = 1:numel(shapes)
                    shape = shapes{r};
                    rawStore = CountingStore();
                    gzStore = zarr.stores.MemoryStore();
                    raw = zarr.create(rawStore, shape, dtypes(k), ChunkShape=chunks{r});
                    gz = zarr.create(gzStore, shape, dtypes(k), ChunkShape=chunks{r}, ...
                        Codecs={zarr.codecs.GzipCodec(1)});
                    d = TestPartialRead.sampleData(shape, dtypes(k));
                    whole = repmat({':'}, 1, numel(shape));
                    raw(whole{:}) = d;
                    gz(whole{:}) = d;
                    for q = 1:numel(regions{r})
                        idx = regions{r}{q};
                        if ~iscell(idx)
                            idx = {idx};
                        end
                        label = sprintf("%s rank %d region %d", dtypes(k), numel(shape), q);
                        rawStore.resetCounts();
                        tc.verifyEqual(raw(idx{:}), gz(idx{:}), label);
                        tc.verifyEqual(raw(idx{:}), d(idx{:}), label);
                    end
                    tc.verifyGreaterThan(rawStore.nPartialGets, 0);
                end
            end
        end

        function bigEndian(tc)
            [z, probe, d] = TestPartialRead.int16Array([500 3], [500 3], ...
                {zarr.codecs.BytesCodec("big")});
            tc.verifyEqual(z(101:103, 2), d(101:103, 2));
            tc.verifyEqual(probe.nPartialGets, 1);
            tc.verifyEqual(probe.bytesRead, 3 * 3 * 2);
        end
    end

    methods (Static)
        function [z, probe, d] = int16Array(shape, chunkShape, codecs)
            if nargin < 3
                codecs = {};
            end
            probe = CountingStore();
            z = zarr.create(probe, shape, "int16", ChunkShape=chunkShape, Codecs=codecs);
            R = numel(shape);
            d = permute(reshape(int16(mod(0:prod(shape) - 1, 30000)), flip(shape)), R:-1:1);
            whole = repmat({':'}, 1, R);
            z(whole{:}) = d;
            probe.resetCounts();
        end

        function d = sampleData(shape, dtype)
            v = mod(0:prod(shape) - 1, 200);
            switch dtype
                case "bool"
                    d = logical(mod(v, 3) == 0);
                case "float64"
                    d = v / 4;
                otherwise
                    d = cast(v, dtype);
            end
            if isscalar(shape)
                d = d(:);
            else
                d = reshape(d, shape);
            end
        end
    end
end
