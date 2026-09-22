function m5_check()
%M5_CHECK ZipStore + consolidated metadata, MATLAB side.
%   Step A (after python wrote scratch/m5_py.zip and scratch/m5_py_cons):
%   verify both, then write scratch/m5_ml.zip and consolidate scratch/m5_ml_cons.

% --- read python-written zip store -------------------------------------
zs = zarr.stores.ZipStore("scratch/m5_py.zip");
g = zarr.open(zs);
z = g.item("data");
assert(isequal(z.read(), interop_pattern([6 8], "float64")), 'zip read data');
assert(g.attrs{"kind"} == "zipped", 'zip attrs');
sarr = g.item("labels");
assert(isequal(sarr.read(), ["alpha"; "beta"; ""; "delta"]), 'zip vlen strings');
zs.close();

% --- read python-consolidated store, verify no per-child reads ----------
probe = ProbeLocalStore("scratch/m5_py_cons");
root = zarr.open(probe);
assert(~isempty(root.meta.consolidated), 'consolidated parsed');
probe.resetCount();
[an, gn] = root.children();
assert(ismember("x", an) && ismember("sub", gn), 'consolidated children');
sub = root.item("sub");
y = sub.item("y");   % nested: served from sliced consolidated map
assert(probe.nGets == 0, 'no store reads for consolidated lookups');
assert(isequal(y.read(), interop_pattern([3 3], "int32")), 'consolidated data read');

% --- write our own zip + consolidated for python to verify --------------
ws = zarr.stores.ZipStore("scratch/m5_ml.zip", Mode="w");
zarr.create_group(ws, Attributes=struct('kind', 'zipped'));
z2 = zarr.create(ws, [6 8], "float64", Path="data", ChunkShape=[3 4], ...
    Codecs={zarr.codecs.ZstdCodec(3)});
z2.write(interop_pattern([6 8], "float64"));
s2 = zarr.create(ws, 4, "string", Path="labels", ChunkShape=2);
s2(:) = ["alpha"; "beta"; ""; "delta"];
ws.close();

if isfolder("scratch/m5_ml_cons"), rmdir("scratch/m5_ml_cons", 's'); end
ls = zarr.stores.LocalStore("scratch/m5_ml_cons");
zarr.create_group(ls, Attributes=struct('title', 'consolidated'));
zarr.create(ls, [4 4], "float64", Path="x", ChunkShape=[2 2]).write(magic(4));
zarr.create(ls, [3 3], "int32", Path="sub/y", ChunkShape=[3 3]).write( ...
    interop_pattern([3 3], "int32"));
zarr.consolidate_metadata(ls);
% our own round trip through the consolidated path
root2 = zarr.open(ls);
assert(~isempty(root2.meta.consolidated), 'own consolidation readable');
assert(isequal(root2.item("sub").item("y").read(), interop_pattern([3 3], "int32")));

disp('M5 MATLAB OK');
end
