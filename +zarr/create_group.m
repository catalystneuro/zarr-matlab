function g = create_group(store, opts)
%CREATE_GROUP Create a Zarr v3 group (and any missing parent groups).
%   g = zarr.create_group(store, Path="a/b", Attributes=struct(...))
%
%   Attributes takes a scalar struct or a dictionary. A struct can only
%   express keys that are valid MATLAB identifiers; pass a dictionary for
%   any other key ("_DTYPE", "chunk size").

arguments
    store
    opts.Path (1,1) string = ""
    opts.Attributes = struct()
end

attributes = zarr.internal.attribute_dictionary(opts.Attributes);
store = zarr.internal.resolve_store(store);
path = zarr.internal.normalize_path(opts.Path);

if strlength(path) == 0
    key = "zarr.json";
else
    key = path + "/zarr.json";
end

[bytes, found] = store.get(key);
if found
    txt = native2unicode(bytes, 'UTF-8');
    m = jsondecode(txt);
    if ~strcmp(m.node_type, 'group')
        error("zarr:NodeExists", "An array already exists at '%s'.", path);
    end
    if numEntries(attributes) > 0
        warning("zarr:NodeExists", ...
            "A group already exists at '%s'; keeping its existing attributes.", path);
    end
    g = zarr.Group(store, path, zarr.metadata.GroupMetadata.fromJsonText(txt));
    return
end

meta = zarr.metadata.GroupMetadata();
meta.attributes = attributes;

zarr.internal.ensure_parents(store, path);
store.set(key, unicode2native(char(meta.toJsonText()), 'UTF-8'));
g = zarr.Group(store, path, meta);
end
