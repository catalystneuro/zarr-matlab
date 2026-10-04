function tf = parallel_fetch_available(isAvailable)
%PARALLEL_FETCH_AVAILABLE Whether chunks may be fetched on thread workers.
%   tf = parallel_fetch_available() is true when backgroundPool exists
%   (R2021b+) and concurrent fetching has not been turned off.
%
%   parallel_fetch_available(false) turns it off for the rest of the MATLAB
%   session, which zarr.stores.HttpStore.getMany does when a concurrent
%   fetch fails where a sequential one succeeds. parallel_fetch_available(true)
%   turns it back on.

persistent available
if nargin > 0
    available = isAvailable;
end
if isempty(available)
    available = ~isempty(which("backgroundPool"));
end
tf = available;
end
