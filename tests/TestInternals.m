classdef TestInternals < matlab.unittest.TestCase
    %Unit tests for +zarr/+internal helpers.

    methods (Test)
        function crc32cKnownAnswer(tc)
            % RFC 3720 test vector
            tc.verifyEqual(zarr.internal.crc32c(uint8('123456789')), ...
                uint32(hex2dec('E3069283')));
            tc.verifyEqual(zarr.internal.crc32c(uint8([])), uint32(0));
            % 32 bytes of zeros (iSCSI test vector)
            tc.verifyEqual(zarr.internal.crc32c(zeros(1, 32, 'uint8')), ...
                uint32(hex2dec('8A9136AA')));
        end

        function halfRoundTrip(tc)
            % all finite half bit patterns survive a round trip
            u = uint16([0:31743, 32768:64511]);  % all non-NaN/Inf patterns
            back = zarr.internal.single2half(zarr.internal.half2single(u));
            tc.verifyEqual(back, u);
        end

        function halfSpecials(tc)
            tc.verifyEqual(zarr.internal.half2single(uint16(31744)), single(Inf));
            tc.verifyEqual(zarr.internal.half2single(uint16(64512)), single(-Inf));
            tc.verifyTrue(isnan(zarr.internal.half2single(uint16(32256))));
            tc.verifyEqual(zarr.internal.half2single(uint16(32768)), single(-0));
            % subnormal: smallest positive half = 2^-24
            tc.verifyEqual(zarr.internal.half2single(uint16(1)), single(2^-24));
            % rounding: 2049 is halfway between 2048 and 2050 -> ties to even (2048)
            tc.verifyEqual(zarr.internal.single2half(single(2049)), uint16(26624));
            tc.verifyEqual(zarr.internal.single2half(single(2051)), uint16(26626));  % 2052
            tc.verifyEqual(zarr.internal.single2half(single(65520)), uint16(31744)); % -> Inf
        end

        function hexParse(tc)
            tc.verifyEqual(zarr.internal.hex2uint64("7ff8000000000001"), ...
                uint64(9221120237041090561));
            tc.verifyEqual(zarr.internal.hex2uint64("ff"), uint64(255));
            tc.verifyError(@() zarr.internal.hex2uint64("xyz"), "zarr:InvalidFillValue");
        end

        function chunkIntersectionsMatchBruteForce(tc)
            rng(42);
            for trial = 1:25
                R = randi(3);
                shape = randi(9, 1, R) + 1;
                cs = arrayfun(@(s) randi(s), shape);
                start0 = arrayfun(@(s) randi(s) - 1, shape);
                count = arrayfun(@(s, st) randi(s - st), shape, start0);

                % brute force: mark every element covered exactly once
                cover = zeros([count, 1, 1]);
                parts = zarr.internal.chunk_intersections(start0, count, cs);
                for t = 1:numel(parts)
                    p = parts(t);
                    subs = arrayfun(@(a, c) a + 1:a + c, p.outStart, p.inCount, ...
                        'UniformOutput', false);
                    subs = [subs, {1, 1}];
                    cover(subs{1:max(R, 2)}) = cover(subs{1:max(R, 2)}) + 1;
                    % element positions consistent between region and chunk
                    tc.verifyEqual(p.coords .* cs + p.inStart, start0 + p.outStart);
                    tc.verifyTrue(all(p.inStart + p.inCount <= cs));
                end
                tc.verifyTrue(all(cover(:) == 1), 'every element covered exactly once');
            end
        end

        function mshapeMapping(tc)
            tc.verifyEqual(zarr.internal.mshape([]), [1 1]);
            tc.verifyEqual(zarr.internal.mshape(5), [5 1]);
            tc.verifyEqual(zarr.internal.mshape([3 4]), [3 4]);
        end

        function gzipMatchesSystem(tc)
            % our gzip output must be decodable by the system gunzip
            payload = uint8(1:255);
            gz = zarr.internal.gzip_java('compress', payload, 9);
            f = [tempname '.gz'];
            fid = fopen(f, 'w'); fwrite(fid, gz); fclose(fid);
            cleaner = onCleanup(@() delete(f));
            out = gunzip(f);
            fid = fopen(out{1}, 'r');
            back = fread(fid, Inf, '*uint8')';
            fclose(fid);
            delete(out{1});
            tc.verifyEqual(back, payload);
        end

        function gzipDecodesEveryMember(tc)
            % Two gzip members back to back decode to both payloads in order.
            firstPayload = uint8(1:200);
            secondPayload = uint8(mod(0:299, 7));
            gz = [zarr.internal.gzip_java('compress', firstPayload, 5), ...
                zarr.internal.gzip_java('compress', secondPayload, 5)];
            tc.verifyEqual(zarr.internal.gzip_java('decompress', gz), [firstPayload, secondPayload]);

            % A corrupted second member is still detected.
            gz(end - 8) = bitxor(gz(end - 8), 1);
            tc.verifyError(@() zarr.internal.gzip_java('decompress', gz), "zarr:CodecError");
        end

        function gzipCorruptDeflateIsCodecError(tc)
            % Deflate data that cannot be decoded is a codec error, in any member.
            good = zarr.internal.gzip_java('compress', uint8(mod(0:3999, 13)), 5);
            bad = good;
            bad(11) = 7;  % first deflate byte: a final block of the reserved type 3
            tc.verifyError(@() zarr.internal.gzip_java('decompress', bad), "zarr:CodecError");
            tc.verifyError(@() zarr.internal.gzip_java('decompress', [good, bad]), "zarr:CodecError");
        end

        function gzipMembersLargerThanASlice(tc)
            % Stored (level 0) members span several of the inflater's slices.
            payload = uint8(mod(0:149999, 251));
            member = zarr.internal.gzip_java('compress', payload, 0);
            tc.verifyEqual(zarr.internal.gzip_java('decompress', [member, member, member]), ...
                [payload, payload, payload]);
        end

        function gzipSkipsZeroPadding(tc)
            % Zero bytes after a member, at the end or between members, are padding.
            a = zarr.internal.gzip_java('compress', uint8(1:50), 5);
            b = zarr.internal.gzip_java('compress', uint8(51:90), 5);
            padding = zeros(1, 16, 'uint8');
            tc.verifyEqual(zarr.internal.gzip_java('decompress', [a, padding]), uint8(1:50));
            tc.verifyEqual(zarr.internal.gzip_java('decompress', [a, padding, b]), uint8(1:90));
        end

        function gzipMalformedHeaderIsCodecError(tc)
            % Header fields that run past the end of the stream are codec errors.
            member = zarr.internal.gzip_java('compress', uint8(1:50), 5);
            fnameFlag = uint8(8);
            extraAndFnameFlags = uint8(12);
            noTerminator = [member(1:3), fnameFlag, member(5:10), uint8(repmat('a', 1, 30))];
            longExtra = [member(1:3), extraAndFnameFlags, member(5:10), uint8([96 234]), uint8(1:10)];
            tc.verifyError(@() zarr.internal.gzip_java('decompress', noTerminator), "zarr:CodecError");
            tc.verifyError(@() zarr.internal.gzip_java('decompress', longExtra), "zarr:CodecError");
        end

        function gzipChecksMemberSize(tc)
            % The trailer's ISIZE must match the decoded length.
            member = zarr.internal.gzip_java('compress', uint8(1:50), 5);
            member(end-3) = member(end-3) + 1;
            tc.verifyError(@() zarr.internal.gzip_java('decompress', member), "zarr:CodecError");
        end

        function gzipLaterMemberCases(tc)
            % A later member with a file name field decodes, and one cut inside
            % its trailer is a codec error.
            firstMember = zarr.internal.gzip_java('compress', uint8(1:50), 5);
            plain = zarr.internal.gzip_java('compress', uint8(51:90), 5);
            fnameFlag = uint8(8);
            named = [plain(1:3), fnameFlag, plain(5:10), uint8('part2.bin'), uint8(0), plain(11:end)];
            tc.verifyEqual(zarr.internal.gzip_java('decompress', [firstMember, named]), uint8(1:90));
            tc.verifyError(@() zarr.internal.gzip_java('decompress', [firstMember, plain(1:end-4)]), ...
                "zarr:CodecError");
        end
    end
end
