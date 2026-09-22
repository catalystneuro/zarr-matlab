%% Getting started with zarr-matlab
% Zarr is a format for chunked, compressed N-dimensional arrays designed for
% cloud storage and parallel I/O. This library reads and writes Zarr v3
% stores that are byte-compatible with zarr-python.

%% Create a compressed array
% A store is just a directory; each chunk is one file inside it.
root = fullfile(tempdir, "getting_started.zarr");
if isfolder(root), rmdir(root, 's'); end

z = zarr.create(root, [720 1440], "single", ...
    Path="temperature", ...
    ChunkShape=[180 360], ...
    Codecs={zarr.codecs.ZstdCodec(3)}, ...
    FillValue=single(NaN), ...
    DimensionNames=["lat" "lon"], ...
    Attributes=struct(units="degC", source="getting_started"));

%% Write and read with ordinary MATLAB indexing
z(:, :) = single(20 + 5 * randn(720, 1440));
block = z(1:10, end-9:end);        %#ok<NASGU> % reads only the chunks it needs
z(1, 1) = single(-40);             % read-modify-write of one chunk

%% Reopen and inspect
z2 = zarr.open(root, Path="temperature");
disp(z2.shape)
disp(z2.attrs)                 % dictionary; z2.attrs{"units"}
disp(z2.dimensionNames)

%% Groups and hierarchy
g = zarr.open(root);               % the root group was created implicitly
run1 = g.createGroup("run1");
spikes = run1.createArray("spikes", [1e5 1], "int16", ChunkShape=[16384 1]);
spikes(1:5, 1) = int16([3 1 4 1 5]');
[arrayNames, groupNames] = g.children() %#ok<NOPTS>

%% Sharding: many small chunks per stored object
% With ShardShape, each stored file holds a grid of independently-compressed
% inner chunks, and reads fetch only the byte ranges they need.
zs = zarr.create(root, [4096 4096], "uint16", ...
    Path="image", ChunkShape=[256 256], ShardShape=[2048 2048], ...
    Codecs={zarr.codecs.BloscCodec(cname="zstd", shuffle="bitshuffle")});
zs(1:256, 1:256) = uint16(magic(256));
tile = zs(1:100, 1:100); %#ok<NASGU>

%% Variable-length strings
labels = zarr.create(root, 4, "string", Path="labels");
labels(:) = ["train"; "test"; "validate"; ""];

%% Grow an array
resize(spikes, [2e5 1]);
append(zs, zeros(4096, 512, 'uint16'), 2);

%% Consolidated metadata: open big hierarchies with a single read
zarr.consolidate_metadata(root);
gc = zarr.open(root);              % children/lookups now served from memory

%% Interop with Python
% Everything written above opens unchanged in zarr-python:
%
%   import zarr
%   z = zarr.open_group("<root>")
%   z["temperature"][:5, :5]
%
% and any v3 store zarr-python writes opens here with zarr.open.
