classdef TestHttpStore < matlab.unittest.TestCase
    %HTTP read-only store, tested against a local python http.server.
    %   Skipped on Windows and when python is unavailable.

    properties
        root
        servedRoot
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

            % Build a store to serve: array + shards + strings + consolidated.
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
            zarr.consolidate_metadata(ls);

            % Serve with socketserver rather than `python -m http.server`:
            % HTTPServer.server_bind calls socket.getfqdn on the bind address
            % before it starts listening, and that reverse lookup can take tens
            % of seconds on hosts with slow name resolution (GitHub's macOS
            % runners among them).
            % The server binds port 0, so the OS assigns a port that is free
            % for this run, and prints that port to stdout, which goes to
            % portFile.
            serverCode = "import functools, http.server, socketserver, sys; " + ...
                "handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=sys.argv[1]); " + ...
                "server = socketserver.ThreadingTCPServer(('127.0.0.1', 0), handler); " + ...
                "print(server.server_address[1], flush=True); " + ...
                "server.serve_forever()";
            portFile = fullfile(tc.root, "port");
            cmd = sprintf('"%s" -c "%s" "%s" >"%s" 2>/dev/null & echo $!', ...
                tc.python, serverCode, tc.servedRoot, portFile);
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
                indexDir = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture).Folder;
                fid = fopen(fullfile(indexDir, "zarr.json"), 'w');
                fwrite(fid, meta);
                fclose(fid);
                fid = fopen(fullfile(indexDir, "manifest.json"), 'w');
                fwrite(fid, unicode2native(char("{""chunks"":{""c/0"":{""path"":""" + url + ...
                    """,""offset"":0,""length"":" + numel(chunk) + "}}}"), 'UTF-8'));
                fclose(fid);

                z = zarr.open(zarr.stores.ManifestStore(indexDir));
                tc.verifyEqual(z(:), d, "URL: " + url);
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
