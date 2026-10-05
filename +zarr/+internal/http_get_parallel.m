function [values, found] = http_get_parallel(urls, maxConcurrent, ranges)
%HTTP_GET_PARALLEL Fetch URLs concurrently on the thread workers of backgroundPool.
%   [values, found] = http_get_parallel(urls, maxConcurrent) fetches each URL
%   with zarr.internal.http_get and returns, in the order of urls, a cell row
%   of values and a logical row that is false for an absent object (404 or
%   403). The URLs are dealt round-robin into at most maxConcurrent tasks,
%   each fetching its share in turn, so at most maxConcurrent requests are in
%   flight. An error in any task cancels the others and is raised.
%
%   http_get_parallel(urls, maxConcurrent, ranges) reads a byte range of
%   each URL with zarr.internal.http_read_range instead. Row i of ranges is
%   the 0-based offset and the length to read from urls(i).

arguments
    urls (1,:) string
    maxConcurrent (1,1) double {mustBeInteger, mustBePositive}
    ranges (:,2) double = zeros(0, 2)
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
    taskRanges = zeros(0, 2);
    if ~isempty(ranges)
        taskRanges = ranges(taskOf == task, :);
    end
    futures{task} = parfeval(pool, @fetchInTurn, 2, urls(taskOf == task), taskRanges);
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
        % fetchOutputs wraps the task's own error; raise that one. It was
        % caught on the worker, not here, so it is thrown, not rethrown.
        throw(taskError.cause{1})
    end
    rethrow(taskError)
end
end

function [values, found] = fetchInTurn(urls, ranges)
values = cell(1, numel(urls));
found = false(1, numel(urls));
for i = 1:numel(urls)
    if isempty(ranges)
        [values{i}, found(i)] = zarr.internal.http_get(urls(i), []);
    else
        [values{i}, found(i)] = zarr.internal.http_read_range(urls(i), ranges(i, 1), ranges(i, 2));
    end
end
end
