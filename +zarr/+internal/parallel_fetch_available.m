function tf = parallel_fetch_available(isAvailable, kind)
%PARALLEL_FETCH_AVAILABLE Whether chunks may be fetched on thread workers.
%   tf = parallel_fetch_available() is true when backgroundPool exists
%   (R2021b+) and concurrent fetching has not been turned off.
%
%   parallel_fetch_available(false) turns it off for the rest of the MATLAB
%   session, which zarr.stores.HttpStore.getMany does when a concurrent
%   fetch fails where a sequential one succeeds. parallel_fetch_available(true)
%   turns it back on.
%
%   parallel_fetch_available(isAvailable, kind) reads or sets one kind of
%   fetch: "get" (the default) for whole values, or "range" for the ranged
%   reads of zarr.stores.HttpStore.getPartialMany. The two use different
%   HTTP clients, so one can fail on thread workers where the other works.
%   Pass [] as isAvailable to read a kind without setting it.

persistent available
if nargin < 2
    kind = "get";
end
if isempty(available)
    hasPool = ~isempty(which("backgroundPool"));
    available = struct('get', hasPool, 'range', hasPool);
end
if nargin > 0 && ~isempty(isAvailable)
    available.(kind) = isAvailable;
end
tf = available.(kind);
end
