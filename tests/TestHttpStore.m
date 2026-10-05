classdef TestHttpStore < matlab.unittest.TestCase
    %HTTP read-only store, tested against a local python http.server.
    %   Skipped on Windows and when python is unavailable.

    properties
        root
        servedRoot
        requestLog
        port
        proc
        python
    end

    methods (TestClassSetup)
        function startServer(tc)
            tc.assumeTrue(isunix, 'http.server test runs on unix only');
            tc.python = "";
            projRoot = fileparts(fileparts(mfilename('fullpath')));
            for c = [string(getenv('ZARR_MATLAB_PYTHON')), ...
                     fullfile(projRoot, '.venv', 'bin', 'python'), "python3"]
                if strlength(c) > 0 && system("""" + c + """ -c ""import sys""") == 0
                    tc.python = c;
                    break
                end
            end
            tc.assumeTrue(strlength(tc.python) > 0, 'python not found');

            % Build a store to serve: array + shards + strings + empty group
            % + consolidated.
            % The store sits in a subfolder of tc.root so that the server's
            % port file is outside the served tree.
            tc.root = fullfile(tempdir, "zm_http_" + string(feature('getpid')));
            if isfolder(tc.root), rmdir(tc.root, 's'); end
            tc.servedRoot = fullfile(tc.root, "store");
            ls = zarr.stores.LocalStore(tc.servedRoot);
            zarr.create_group(ls, Attributes=struct('served', true));
            zarr.create(ls, [10 8], "float64", Path="a", ChunkShape=[5 4], ...
                Codecs={zarr.codecs.GzipCodec(5)}).write(reshape(1:80, [10 8]));
            zs = zarr.create(ls, [8 8], "int32", Path="s", ChunkShape=[2 2], ...
                ShardShape=[8 8]);
            zs.write(reshape(int32(1:64), [8 8]));
            zarr.create_group(ls, Path="empty");
            zarr.consolidate_metadata(ls);

            % Serve with socketserver rather than `python -m http.server`:
            % HTTPServer.server_bind calls socket.getfqdn on the bind address
            % before it starts listening, and that reverse lookup can take tens
            % of seconds on hosts with slow name resolution (GitHub's macOS
            % runners among them).
            % The server binds port 0, so the OS assigns a port that is free
            % for this run, and prints that port to stdout, which goes to
            % portFile.
            % Paths under /range/<mode>/ answer a Range request the way one
            % kind of server does (see rangeModes); every other path is served
            % by SimpleHTTPRequestHandler, which ignores the Range header.
            serverScript = fullfile(tc.root, "server.py");
            writelines([
                "import http.server, os, socketserver, sys"
                "ROOT = sys.argv[1]"
                "PREFIX = '/range/'"
                "class Handler(http.server.SimpleHTTPRequestHandler):"
                "    def __init__(self, *args, **kwargs):"
                "        super().__init__(*args, directory=ROOT, **kwargs)"
                "    def do_GET(self):"
                "        if not self.path.startswith(PREFIX):"
                "            return super().do_GET()"
                "        mode, _, key = self.path[len(PREFIX):].partition('/')"
                "        try:"
                "            with open(os.path.join(ROOT, key), 'rb') as f:"
                "                body = f.read()"
                "        except OSError:"
                "            return self.send_error(404)"
                "        first, _, last = self.headers['Range'].replace('bytes=', '').partition('-')"
                "        first, last = int(first), min(int(last), len(body) - 1)"
                "        if mode in ('startonly', 'startonly-noheader'):"
                "            last = len(body) - 1"
                "        if mode == 'early':"
                "            first = max(first - 3, 0)"
                "        if mode == 'late':"
                "            first = first + 1"
                "        part = body[first:last + 1]"
                "        self.send_response(500 if mode == 'error' else 206)"
                "        if not mode.endswith('noheader'):"
                "            self.send_header('Content-Range', 'bytes %d-%d/%d' % (first, last, len(body)))"
                "        self.send_header('Content-Type', self.guess_type(key))"
                "        self.send_header('Content-Length', str(len(part)))"
                "        self.end_headers()"
                "        self.wfile.write(part)"
                "server = socketserver.ThreadingTCPServer(('127.0.0.1', 0), Handler)"
                "print(server.server_address[1], flush=True)"
                "server.serve_forever()"
                ], serverScript);
            portFile = fullfile(tc.root, "port");
            % The handler logs each request line to stderr, which goes to
            % requestLog, so a test can see exactly what reached the server.
            tc.requestLog = fullfile(tc.root, "requests.log");
            cmd = sprintf('"%s" "%s" "%s" >"%s" 2>"%s" & echo $!', ...
                tc.python, serverScript, tc.servedRoot, portFile, tc.requestLog);
            [~, pidStr] = system(cmd);
            tc.proc = strtrim(pidStr);

            % Wait for the port, then probe with webread, the client HttpStore
            % uses. Programs started with system() inherit MATLAB's library
            % path on Linux, which makes the system curl load MATLAB's bundled
            % libcurl and fail to start. The port file is re-read on every
            % attempt because it can be read while still empty or part-written.
            probeOptions = weboptions(Timeout=1, ContentType="binary");
            reachable = false;
            probeMessage = "the server did not report its port";
            for attempt = 1:20
                reportedPort = NaN;
                if isfile(portFile)
                    reportedPort = str2double(fileread(portFile));
                end
                if ~isnan(reportedPort)
                    try
                        webread(sprintf("http://127.0.0.1:%d/zarr.json", reportedPort), probeOptions);
                        tc.port = reportedPort;
                        reachable = true;
                        break
                    catch err
                        probeMessage = string(err.message);
                    end
                end
                pause(0.25);
            end
            if ~reachable
                tc.stopServer();
            end
            tc.assumeTrue(reachable, "Local HTTP server not reachable: " + probeMessage);
        end
    end

    methods (TestClassTeardown)
        function stopServer(tc)
            if ~isempty(tc.proc)
                system(sprintf('kill %s >/dev/null 2>&1', tc.proc));
            end
            if ~isempty(tc.root) && isfolder(tc.root)
                rmdir(tc.root, 's');
            end
        end
    end

    methods (Test)
        function readOverHttp(tc)
            store = zarr.stores.HttpStore(sprintf("http://127.0.0.1:%d", tc.port));
            g = zarr.open(store);
            tc.verifyTrue(logical(g.attrs{"served"}));
            % children served from consolidated metadata (store is unlistable)
            [an, ~] = g.children();
            tc.verifyTrue(all(ismember(["a"; "s"], an)));
            a = g.item("a");
            tc.verifyEqual(a(2:7, 3:6), subsref(reshape(1:80, [10 8]), ...
                substruct('()', {2:7, 3:6})));
            % sharded partial read over HTTP
            s = g.item("s");
            d = reshape(int32(1:64), [8 8]);
            tc.verifyEqual(s(3:4, 5:6), d(3:4, 5:6));
        end

        function readSpanningChunksFetchesConcurrently(tc)
            % "a" has 2 x 2 chunks, so a full read fetches four, which meets
            % the default ParallelThreshold. Fetching them concurrently, in
            % turn, or one request at a time must give the same data.
            expected = reshape(1:80, [10 8]);
            store = zarr.stores.HttpStore(sprintf("http://127.0.0.1:%d", tc.port));
            a = zarr.open(store, Path="a");
            tc.verifyEqual(tc.verifyWarningFree(@() a.read()), expected);

            store.MaxConcurrentRequests = 1;
            tc.verifyEqual(a.read(), expected);

            store.MaxConcurrentRequests = 8;
            store.ParallelThreshold = Inf;
            tc.verifyEqual(a.read(), expected);
        end

        function getManyKeepsOrderAndReportsAbsentKeys(tc)
            store = zarr.stores.HttpStore(sprintf("http://127.0.0.1:%d", tc.port));
            store.ParallelThreshold = 2;
            keys = ["a/c/1/1", "missing/key", "a/c/0/0", "a/zarr.json", "a/c/0/9"];

            [values, found] = store.getMany(keys);

            tc.verifyEqual(found, [true false true true false]);
            for i = find(found)
                tc.verifyEqual(values{i}, store.get(keys(i)), keys(i));
            end
            tc.verifyEmpty(values{2});
        end

        function emptyGroupIsBrowsedWithoutRequests(tc)
            % Consolidated metadata states that the group has no children, so
            % browsing it needs no listing, which an HTTP store cannot give.
            store = zarr.stores.HttpStore(sprintf("http://127.0.0.1:%d", tc.port));
            rootGroup = zarr.open(store);
            emptyGroup = rootGroup.item("empty");
            loggedRequests = string(fileread(tc.requestLog));

            [arrayNames, groupNames] = emptyGroup.children();
            tc.verifyEqual(arrayNames, string.empty(0, 1));
            tc.verifyEqual(groupNames, string.empty(0, 1));
            tc.verifyFalse(emptyGroup.isKey("missing"));
            treeText = string(evalc("rootGroup.tree()"));  % capture the printed tree
            tc.verifySubstring(treeText, "|- empty/");
            tc.verifyEqual(string(fileread(tc.requestLog)), loggedRequests, ...
                "Browsing an empty group must not send requests.");
        end

        function missingKeyIsNotFound(tc)
            store = zarr.stores.HttpStore(sprintf("http://127.0.0.1:%d", tc.port));
            [~, found] = store.get("nope/zarr.json");
            tc.verifyFalse(found);
            tc.verifyError(@() zarr.open(store, Path="nope"), "zarr:NodeNotFound");
        end

        function manifestUrlIsRequestedAsWritten(tc)
            % A manifest path is an encoded URL: "%20" names a space, and a
            % query string may contain "/".
            src = zarr.stores.MemoryStore();
            d = int32(1:6)';
            zarr.create(src, 6, "int32", ChunkShape=6).write(d);
            [chunk, ~] = src.get("c/0");
            [meta, ~] = src.get("zarr.json");
            fid = fopen(fullfile(tc.servedRoot, "a b.bin"), 'w');
            fwrite(fid, chunk);
            fclose(fid);

            fileUrl = sprintf("http://127.0.0.1:%d/a%%20b.bin", tc.port);
            for url = [fileUrl, fileUrl + "?sig=x/y%2Fz"]
                indexDir = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture()).Folder;
                fid = fopen(fullfile(indexDir, "zarr.json"), 'w');
                fwrite(fid, meta);
                fclose(fid);
                fid = fopen(fullfile(indexDir, "manifest.json"), 'w');
                fwrite(fid, unicode2native(char("{""chunks"":{""c/0"":{""path"":""" + url + ...
                    """,""offset"":0,""length"":" + numel(chunk) + "}}}"), 'UTF-8'));
                fclose(fid);

                z = zarr.open(zarr.stores.ManifestStore(indexDir));
                tc.verifyEqual(z(:), d, "URL: " + url);
                % The server ignores the query, so check its request log: the
                % path and query must arrive exactly as written.
                requestTarget = extractAfter(url, "127.0.0.1:" + tc.port);
                tc.verifySubstring(string(fileread(tc.requestLog)), ...
                    "GET " + requestTarget + " HTTP", "URL: " + url);
            end
        end

        function manifestRelativePathOverHttp(tc)
            % A relative manifest path names a file beside the index, as a
            % store key does, so "#", "%" and spaces in it are literal.
            src = zarr.stores.MemoryStore();
            d = int32(1:6)';
            zarr.create(src, 6, "int32", ChunkShape=6).write(d);
            [chunk, ~] = src.get("c/0");
            [meta, ~] = src.get("zarr.json");
            indexDir = fullfile(tc.servedRoot, "idx");
            mkdir(indexDir);
            writeBytes(fullfile(indexDir, "zarr.json"), meta);
            indexUrl = sprintf("http://127.0.0.1:%d/idx", tc.port);

            for name = ["c#d e.bin", "p%41.bin"]
                writeBytes(fullfile(tc.servedRoot, name), chunk);
                manifest = "{""chunks"":{""c/0"":{""path"":""../" + name + ...
                    """,""offset"":0,""length"":" + numel(chunk) + "}}}";
                writeBytes(fullfile(indexDir, "manifest.json"), unicode2native(char(manifest), 'UTF-8'));
                z = zarr.open(zarr.stores.ManifestStore(indexUrl));
                tc.verifyEqual(z(:), d, "path: ../" + name);
            end
        end

        function rangeReadTakesRequestedBytesFromResponse(tc)
            % Servers differ in what they send for a Range request. The
            % status and Content-Range say which bytes arrived.
            bytes = uint8(mod(0:199, 251));
            writeBytes(fullfile(tc.servedRoot, "blob.bin"), bytes);
            modes = [
                "honor"               % 206 with the requested range
                "noheader"            % 206 with the requested range, no Content-Range
                "startonly"           % 206 from the offset to the end of the object
                "startonly-noheader"  % the same, with no Content-Range
                "early"               % 206 starting 3 bytes before the offset
                ];
            ranges = [0 10; 20 10; 50 60; 190 10; 199 1];
            for mode = modes'
                url = sprintf("http://127.0.0.1:%d/range/%s/blob.bin", tc.port, mode);
                for r = 1:size(ranges, 1)
                    offset = ranges(r, 1);
                    len = ranges(r, 2);
                    [data, found] = zarr.internal.http_read_range(url, offset, len);
                    label = sprintf("%s: %d bytes at %d", mode, len, offset);
                    tc.verifyTrue(found, label);
                    tc.verifyEqual(data, bytes(offset + 1:offset + len), label);
                end
            end
            % A server that ignores the Range header sends the whole object.
            url = sprintf("http://127.0.0.1:%d/blob.bin", tc.port);
            for r = 1:size(ranges, 1)
                offset = ranges(r, 1);
                len = ranges(r, 2);
                [data, found] = zarr.internal.http_read_range(url, offset, len);
                tc.verifyTrue(found);
                tc.verifyEqual(data, bytes(offset + 1:offset + len));
            end
        end

        function rangeReadOfTextTypedObjectIsItsBytes(tc)
            % A server names a content type from the file extension. The
            % bytes must come back as stored whatever it says, including
            % bytes that are not valid text.
            bytes = uint8([0:255, 255:-1:0]);
            for name = ["typed.json", "typed.txt", "typed.bin"]
                writeBytes(fullfile(tc.servedRoot, name), bytes);
                for base = ["/range/honor/", "/"]
                    url = sprintf("http://127.0.0.1:%d%s%s", tc.port, base, name);
                    [data, found] = zarr.internal.http_read_range(url, 120, 300);
                    tc.verifyTrue(found, url);
                    tc.verifyEqual(data, bytes(121:420), url);
                end
            end
            % exists() makes a ranged read of a JSON document.
            store = zarr.stores.HttpStore(sprintf("http://127.0.0.1:%d", tc.port));
            tc.verifyTrue(store.exists("zarr.json"));
            tc.verifyFalse(store.exists("nope/zarr.json"));
        end

        function rangeReadPastTheEndIsShort(tc)
            bytes = uint8(1:50);
            writeBytes(fullfile(tc.servedRoot, "short.bin"), bytes);
            for target = ["/range/honor/short.bin", "/range/startonly/short.bin", "/short.bin"]
                url = sprintf("http://127.0.0.1:%d%s", tc.port, target);
                [data, found] = zarr.internal.http_read_range(url, 40, 20);
                tc.verifyTrue(found, target);
                tc.verifyEqual(data, bytes(41:50), target);
            end
        end

        function rangeReadOfMissingObjectIsNotFound(tc)
            for target = ["/range/honor/nope.bin", "/nope.bin"]
                url = sprintf("http://127.0.0.1:%d%s", tc.port, target);
                [data, found] = zarr.internal.http_read_range(url, 0, 10);
                tc.verifyFalse(found, target);
                tc.verifyEmpty(data, target);
            end
        end

        function rangeReadErrorsWhenRequestedBytesAreNotSent(tc)
            writeBytes(fullfile(tc.servedRoot, "blob2.bin"), uint8(1:100));
            base = sprintf("http://127.0.0.1:%d/range/", tc.port);
            % The body starts after the requested offset.
            tc.verifyError(@() zarr.internal.http_read_range(base + "late/blob2.bin", 10, 10), ...
                "zarr:StoreError");
            % A status that is neither success nor "not found".
            tc.verifyError(@() zarr.internal.http_read_range(base + "error/blob2.bin", 10, 10), ...
                "zarr:StoreError");
        end

        function readOnlyEnforced(tc)
            store = zarr.stores.HttpStore(sprintf("http://127.0.0.1:%d", tc.port));
            tc.verifyError(@() store.set("x", uint8(1)), "zarr:StoreError");
            tc.verifyError(@() store.list(), "zarr:StoreError");
        end
    end
end

function writeBytes(filePath, bytes)
%WRITEBYTES Write bytes to a file, replacing any earlier content.
fid = fopen(filePath, "w");
fwrite(fid, bytes);
fclose(fid);
end
