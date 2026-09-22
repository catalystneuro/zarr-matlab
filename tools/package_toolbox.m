function out = package_toolbox()
%PACKAGE_TOOLBOX Build the zarr-matlab .mltbx (MATLAB toolbox installer).
%   Stages +zarr (including any built MEX binaries in +zarr/+internal),
%   examples, README and LICENSE, then packages them. Requires R2023a+.

root = fileparts(fileparts(mfilename('fullpath')));
version = strtrim(fileread(fullfile(root, 'VERSION')));

stage = fullfile(tempname, 'zarr-matlab');
mkdir(stage);
copyfile(fullfile(root, '+zarr'), fullfile(stage, '+zarr'));
copyfile(fullfile(root, 'examples'), fullfile(stage, 'examples'));
copyfile(fullfile(root, 'README.md'), stage);
copyfile(fullfile(root, 'LICENSE'), stage);

% Stable identifier so installs upgrade in place rather than duplicating.
uuid = "7db4372e-2f14-4a52-9d5a-6a4bd3b6a501";
opts = matlab.addons.toolbox.ToolboxOptions(stage, uuid);
opts.ToolboxName = "zarr-matlab";
opts.ToolboxVersion = version;
opts.Summary = "Read and write Zarr v3 arrays natively in MATLAB";
opts.Description = "Zarr v3 for MATLAB: chunked, compressed N-D arrays with " + ...
    "gzip/zstd/blosc/crc32c codecs, sharding with partial reads, groups and " + ...
    "attributes, variable-length strings, zip stores, and consolidated " + ...
    "metadata. Byte-level interoperable with zarr-python.";
opts.AuthorName = "Ben Dichter";
opts.MinimumMatlabRelease = "R2023a";
opts.ToolboxMatlabPath = {char(stage)};
opts.OutputFile = fullfile(root, "zarr-matlab-" + version + ".mltbx");

matlab.addons.toolbox.packageToolbox(opts);
out = opts.OutputFile;
fprintf('packaged %s\n', out);
end
