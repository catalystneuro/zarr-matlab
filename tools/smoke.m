% Quick smoke test of the core paths. Run: matlab -batch "run tools/smoke.m"
function smoke()
% crc32c known-answer test (RFC 3720 vector)
assert(zarr.internal.crc32c(uint8('123456789')) == uint32(hex2dec('E3069283')), 'crc32c KAT');

% float16 round trip incl. specials and subnormals
u = uint16([0 1 1023 1024 15360 31743 31744 64512 32768 33792 48128]);
back = zarr.internal.single2half(zarr.internal.half2single(u));
assert(isequal(u, back), 'half round trip');
assert(isnan(zarr.internal.half2single(uint16(32256))), 'half NaN');

% gzip round trip
payload = uint8(repmat('zarr-matlab!', 1, 1000));
gz = zarr.internal.gzip_java('compress', payload, 5);
assert(isequal(zarr.internal.gzip_java('decompress', gz), payload), 'gzip round trip');
assert(numel(gz) < numel(payload) / 2, 'gzip compresses');

% memory store: create/write/read with gzip, 2-D, uneven chunks
s = zarr.stores.MemoryStore();
z = zarr.create(s, [10 13], "float64", ChunkShape=[4 5], ...
    Codecs={zarr.codecs.GzipCodec(5)}, FillValue=NaN, Path="a/b");
data = reshape(1:130, [10 13]);
z(:, :) = data;
assert(isequal(z(:, :), data), 'full round trip');
assert(isequal(z(2:7, 3:11), data(2:7, 3:11)), 'partial read');
z(3:4, 5:6) = [1 2; 3 4];
data(3:4, 5:6) = [1 2; 3 4];
assert(isequal(z(:, :), data), 'partial write RMW');

% fill values for unwritten chunks
z2 = zarr.create(s, [6 6], "float32", ChunkShape=[3 3], FillValue=single(-1), Path="fills");
z2(1:3, 1:3) = single(magic(3));
out = z2(:, :);
assert(isequal(out(1:3, 1:3), single(magic(3))), 'written chunk');
assert(all(out(4:6, :) == -1, 'all'), 'unwritten chunk = fill');

% rank-1 and rank-0
v = zarr.create(s, 7, "int32", ChunkShape=3, Path="vec");
v(:) = int32((1:7)');
assert(isequal(v(2:5), int32((2:5)')), 'rank-1');
sc = zarr.create(s, [], "float64", Path="scalar");
sc.write(pi);
assert(sc() == pi, 'rank-0');

% local store + reopen + metadata round trip (NaN fill, dim names, attrs)
tmp = fullfile(tempdir, "zm_smoke_" + string(feature('getpid')));
cleanup = onCleanup(@() rmdir_if(tmp));
z3 = zarr.create(char(tmp), [5 4 3], "int16", ChunkShape=[2 2 2], ...
    Codecs={zarr.codecs.GzipCodec(1), zarr.codecs.Crc32cCodec()}, ...
    DimensionNames=["z" "y" "x"], Attributes=struct('units', 'mm'), Path="t");
d3 = reshape(int16(1:60), [5 4 3]);
z3(:, :, :) = d3;
z4 = zarr.open(char(tmp), Path="t");
assert(isequal(z4(:, :, :), d3), 'local store 3-D round trip');
assert(z4.attrs{"units"} == "mm", 'attrs');
assert(isequal(z4.dimensionNames, ["z" "y" "x"]), 'dimension names');
assert(isequal(z4(4:5, [1 3], 2), d3(4:5, [1 3], 2)), 'fancy indexing');

% transpose codec / Order="F"
zf = zarr.create(s, [4 6], "float64", ChunkShape=[2 3], Order="F", Path="forder");
df = magic(4); df = df(:, [1 1 2 2 3 3]);
zf(:, :) = df;
assert(isequal(zf(:, :), df), 'F-order round trip');

% groups
g = zarr.open(s);
[an, gn] = g.children();
assert(ismember("vec", an) && ismember("a", gn), 'children listing');

% resize / append
za = zarr.create(s, [2 3], "float64", ChunkShape=[2 2], Path="grow");
za(:, :) = ones(2, 3);
za.append(2 * ones(2, 2), 2);
assert(isequal(za(:, :), [ones(2, 3), 2 * ones(2, 2)]), 'append');
za.resize([2 2]);
assert(isequal(size(za), [2 2]), 'shrink');

% --- sharding ---------------------------------------------------------
% full + partial reads, gzip+crc32c inner chain, both index locations
zs = zarr.create(s, [12 10], "float64", ChunkShape=[3 5], ShardShape=[6 10], ...
    Codecs={zarr.codecs.GzipCodec(5), zarr.codecs.Crc32cCodec()}, Path="shard");
ds = reshape((1:120) * 0.5, [12 10]);
zs(:, :) = ds;
assert(isequal(zs(:, :), ds), 'shard full round trip');
assert(isequal(zs(2:9, 3:10), ds(2:9, 3:10)), 'shard partial read');
zs(4:5, 2:3) = [9 8; 7 6];
ds(4:5, 2:3) = [9 8; 7 6];
assert(isequal(zs(:, :), ds), 'shard RMW write');

zst = zarr.create(s, [8 8], "int32", ChunkShape=[2 2], ShardShape=[4 8], ...
    IndexLocation="start", Path="shard_start");
di = reshape(int32(1:64), [8 8]);
zst(:, :) = di;
assert(isequal(zst(:, :), di), 'index_location=start');
assert(isequal(zst(3:6, 2:7), di(3:6, 2:7)), 'index_location=start partial');

% missing shards and missing inner chunks read as fill
zm = zarr.create(s, [8 8], "float64", ChunkShape=[2 2], ShardShape=[4 4], ...
    FillValue=NaN, Path="shard_fill");
zm(1:2, 1:2) = ones(2);  % one inner chunk of one shard
outm = zm(:, :);
assert(isequal(outm(1:2, 1:2), ones(2)), 'shard written inner chunk');
assert(all(isnan(outm(5:8, :)), 'all'), 'missing shard = fill');
assert(all(isnan(outm(3:4, 3:4)), 'all'), 'missing inner chunk = fill');

% nested sharding
zn = zarr.create(s, [8 8], "float64", ChunkShape=[4 4], ShardShape=[8 8], ...
    Codecs={zarr.codecs.ShardingCodec([2 2])}, Path="shard_nested");
dn = magic(8);
zn(:, :) = dn;
assert(isequal(zn(:, :), dn), 'nested sharding');

% sharded local store round trip (exercises getSuffix/getPartial on files)
zl = zarr.create(char(tmp), [10 6], "float32", ChunkShape=[2 3], ShardShape=[10 6], ...
    Codecs={zarr.codecs.GzipCodec(5)}, Path="shard_local");
dl = single(reshape(1:60, [10 6]));
zl(:, :) = dl;
zl2 = zarr.open(char(tmp), Path="shard_local");
assert(isequal(zl2(3:8, 2:5), dl(3:8, 2:5)), 'shard local partial');

disp('SMOKE OK');
end

function rmdir_if(p)
if isfolder(p), rmdir(p, 's'); end
end
