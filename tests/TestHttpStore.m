classdef TestHttpStore < matlab.unittest.TestCase
    %HTTP read-only store, tested against a local python http.server.
    %   Skipped on Windows and when python is unavailable.

    properties
        root
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
            tc.root = fullfile(tempdir, "zm_http_" + string(feature('getpid')));
            if isfolder(tc.root), rmdir(tc.root, 's'); end
            ls = zarr.stores.LocalStore(tc.root);
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
            serverCode = "import functools, http.server, socketserver, sys; " + ...
                "handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=sys.argv[2]); " + ...
                "socketserver.ThreadingTCPServer(('127.0.0.1', int(sys.argv[1])), handler).serve_forever()";
            tc.port = 8000 + randi(1000);
            cmd = sprintf('"%s" -c "%s" %d "%s" >/dev/null 2>&1 & echo $!', ...
                tc.python, serverCode, tc.port, tc.root);
            [~, pidStr] = system(cmd);
            tc.proc = strtrim(pidStr);

            % Probe with webread, the client HttpStore uses. Programs started
            % with system() inherit MATLAB's library path on Linux, which makes
            % the system curl load MATLAB's bundled libcurl and fail to start.
            probeOptions = weboptions(Timeout=1, ContentType="binary");
            probeUrl = sprintf("http://127.0.0.1:%d/zarr.json", tc.port);
            reachable = false;
            probeMessage = "";
            for attempt = 1:20
                try
                    webread(probeUrl, probeOptions);
                    reachable = true;
                    break
                catch err
                    probeMessage = string(err.message);
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

        function readOnlyEnforced(tc)
            store = zarr.stores.HttpStore(sprintf("http://127.0.0.1:%d", tc.port));
            tc.verifyError(@() store.set("x", uint8(1)), "zarr:StoreError");
            tc.verifyError(@() store.list(), "zarr:StoreError");
        end
    end
end
