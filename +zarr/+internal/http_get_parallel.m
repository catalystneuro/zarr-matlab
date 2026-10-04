function [values, found] = http_get_parallel(urls, maxConcurrent)
%HTTP_GET_PARALLEL Fetch URLs concurrently on the thread workers of backgroundPool.
%   [values, found] = http_get_parallel(urls, maxConcurrent) fetches each URL
%   with zarr.internal.http_get and returns, in the order of urls, a cell row
%   of values and a logical row that is false for an absent object (404 or
%   403). The URLs are dealt round-robin into at most maxConcurrent tasks,
%   each fetching its share in turn, so at most maxConcurrent requests are in
%   flight. An error in any task cancels the others and is raised.

arguments
    urls (1,:) string
    maxConcurrent (1,1) double {mustBeInteger, mustBePositive}
end

numUrls = numel(urls);
values = cell(1, numUrls);
found = false(1, numUrls);
if numUrls == 0
    return
end

numTasks = min(maxConcurrent, numUrls);
taskOf = mod(0:numUrls - 1, numTasks) + 1;
pool = backgroundPool;
futures = cell(1, numTasks);
for task = 1:numTasks
    futures{task} = parfeval(pool, @fetchInTurn, 2, urls(taskOf == task));
end

try
    for task = 1:numTasks
        [taskValues, taskFound] = fetchOutputs(futures{task});
        values(taskOf == task) = taskValues;
        found(taskOf == task) = taskFound;
    end
catch taskError
    cellfun(@cancel, futures);
    if ~isempty(taskError.cause)
        % fetchOutputs wraps the task's own error; raise that one.
        rethrow(taskError.cause{1})
    end
    rethrow(taskError)
end
end

function [values, found] = fetchInTurn(urls)
values = cell(1, numel(urls));
found = false(1, numel(urls));
for i = 1:numel(urls)
    [values{i}, found(i)] = zarr.internal.http_get(urls(i), []);
end
end
