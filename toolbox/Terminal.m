% Copyright 2026 The MathWorks, Inc.

classdef Terminal < handle
    %TERMINAL Embeds a system terminal inside a MATLAB figure using uihtml.
    %
    %   t = Terminal()                    — docked terminal with default name
    %   t = Terminal(Name="Build")        — docked terminal with custom name
    %   t = Terminal(WindowStyle="normal") — undocked terminal in its own window
    %   t = Terminal(MCP=true)            — enable MCP server for AI agents
    %   t = Terminal(parent)              — terminal inside an existing figure/panel
    %   delete(t)                         — closes the terminal and kills the server
    %
    %   Name-Value Arguments:
    %     Name        - Title of the terminal window (default: "Terminal")
    %     WindowStyle - "docked" (default) or "normal"
    %     Shell       - Shell program to run. Can be a name on PATH or an
    %                   absolute path. Default: system shell ($SHELL on
    %                   Unix, %COMSPEC% on Windows).
    %
    %                   Common values by platform:
    %                     Linux/macOS: "bash", "zsh", "sh", "fish",
    %                                  "/bin/bash", "/usr/bin/zsh"
    %                     Windows:     "cmd.exe", "powershell.exe", "pwsh.exe",
    %                                  "wsl.exe"
    %     MCP         - Enable the MCP (Model Context Protocol) server so
    %                   AI coding agents (Claude Code, etc.) launched from
    %                   the terminal can interact with the running MATLAB
    %                   session. Default: false.
    %
    %   Static methods:
    %     Terminal.version()  — return the installed toolbox version string
    %     Terminal.list()     — return handles to all running terminals
    %     Terminal.closeAll() — close all running terminals
    %     Terminal.update()   — check for and install the latest version from GitHub
    %
    %   Examples:
    %     t = Terminal();
    %     t = Terminal(Name="Git", WindowStyle="normal");
    %     t = Terminal(Shell="zsh");
    %     t = Terminal(Shell="powershell.exe");
    %     t = Terminal(MCP=true);
    %     delete(t);
    %     Terminal.update();

    properties (Access = private)
        ServerProcess   % struct with fields: pid (double), port (double)
        HTMLComponent   % uihtml handle
        AuthToken       % random hex auth string
        ParentFigure    % figure or uifigure handle
        ServerBinary    % absolute path to the Go binary
        PollTimer       % timer object for polling server output
        PollSeq         % last sequence number received from server
        BaseURL         % server base URL
        ReadOpts        % cached weboptions for webread
        WriteOpts       % cached weboptions for webwrite
        OutQueue cell = {}  % queued messages from JS to send to server (legacy only)
        UseEvents logical = false  % true if R2023a+ event API is available
        ThemeConfig        % cached theme config for re-init on HTML reload
        MCPCommand         % command to pre-populate in the first session
        ThemePollCount double = 0  % tick counter for periodic theme check
        LastFigureColor    % cached groot DefaultFigureColor for change detection
    end

    properties (SetAccess = private)
        Shell string        % shell program for new sessions (empty = server default)
    end

    properties (Constant, Access = private)
        DEFAULT_IDLE_TIMEOUT = 30   % seconds
        SERVER_BINARY_NAME = 'matlab-terminal-server'
        POLL_INTERVAL = 0.1         % 100ms polling interval
        THEME_CHECK_TICKS = 50     % check theme every 50 ticks (5 seconds)
        TOOLBOX_ID = '9e8f4a2b-3c1d-4e5f-a6b7-8c9d0e1f2a3b'
        GITHUB_REPO = 'prabhakk-mw/matlab-terminal'
    end

    methods
        function obj = Terminal(parent, options)
            %TERMINAL Construct a terminal instance.
            arguments
                parent = []
                options.Name (1,1) string = "Terminal"
                options.WindowStyle (1,1) string {mustBeMember(options.WindowStyle, ["docked", "normal"])} = "docked"
                options.Shell (1,1) string = ""
                options.MCP (1,1) logical = false
            end

            obj.Shell = options.Shell;

            % --- Validate shell if specified, resolve default if not ---
            if obj.Shell ~= ""
                Terminal.validateShell(obj.Shell);
            else
                obj.Shell = Terminal.defaultShell();
            end

            % --- Parent container ---
            if isempty(parent)
                parent = uifigure('Name', options.Name, ...
                    'Position', [100 100 800 500]);
                try
                    parent.WindowStyle = options.WindowStyle;
                catch
                    if options.WindowStyle == "docked"
                        warning('Terminal:DockNotSupported', ...
                            'Docked window style is not supported in this MATLAB release. Using normal window.');
                    end
                end
            end
            obj.ParentFigure = parent;

            % --- Auth token (32-char hex string, no Java) ---
            obj.AuthToken = sprintf('%04x', randi(65535, 1, 8));

            % --- Extract bundled assets if needed ---
            Terminal.extractWebAssets();

            % --- Locate the server binary ---
            obj.ServerBinary = Terminal.findBinary();
            if isempty(obj.ServerBinary)
                error('Terminal:BinaryNotFound', ...
                    ['Server binary "%s" not found.\n' ...
                     'The toolbox installation may be corrupted.\n' ...
                     'Run  Terminal.update()  to reinstall.'], ...
                    Terminal.SERVER_BINARY_NAME);
            end

            % --- Build environment info ---
            matlabPid = num2str(feature('getpid'));
            matlabRoot = matlabroot;

            % --- Bootstrap the Embedded Connector for MCP ---
            ecInfo = [];
            if options.MCP
                ecInfo = Terminal.ensureEmbeddedConnector();
            end

            % --- Start the server process ---
            readyFile = [tempname, '.txt'];
            args = sprintf('--token "%s" --env "MATLAB_PID=%s" --env "MATLAB_ROOT=%s" --ready-file "%s"', ...
                obj.AuthToken, matlabPid, matlabRoot, readyFile);

            % Pass EC details to the shell so MCP and CLI tools can use them.
            if ~isempty(ecInfo)
                args = sprintf('%s --env "MATLAB_EC_PORT=%d" --env "MWAPIKEY=%s"', ...
                    args, ecInfo.ecPort, ecInfo.mwapikey);
            end

            logFile = [tempname, '.log'];
            if ispc
                % Windows: use a temp batch file to run in background.
                batFile = [tempname, '.bat'];
                fid = fopen(batFile, 'w');
                fprintf(fid, '@"%s" %s > "%s" 2>&1\n', obj.ServerBinary, args, logFile);
                fclose(fid);
                system(sprintf('start "" /b cmd /c call "%s"', batFile));
            else
                system(sprintf('"%s" %s > "%s" 2>&1 &', obj.ServerBinary, args, logFile));
            end

            % Wait for the server to write PID and PORT to the ready file.
            % The server writes and closes this file immediately, so there
            % is no file locking conflict on Windows.
            serverPid = [];
            port = [];
            maxWait = 5;
            elapsed = 0;
            while elapsed < maxWait
                pause(0.2);
                elapsed = elapsed + 0.2;
                if isfile(readyFile)
                    raw = fileread(readyFile);
                    pidTok = regexp(raw, 'PID:(\d+)', 'tokens', 'once');
                    portTok = regexp(raw, 'PORT:(\d+)', 'tokens', 'once');
                    if ~isempty(pidTok)
                        serverPid = str2double(pidTok{1});
                    end
                    if ~isempty(portTok)
                        port = str2double(portTok{1});
                        break;
                    end
                end
            end

            % Clean up temp files.
            if isfile(readyFile), delete(readyFile); end
            if ispc && exist('batFile', 'var') && isfile(batFile)
                delete(batFile);
            end

            if isempty(port)
                if ~isempty(serverPid)
                    Terminal.killProcess(serverPid);
                end
                % Read server log for diagnostics.
                serverLog = '';
                if isfile(logFile)
                    try
                        serverLog = fileread(logFile);
                    catch
                    end
                    delete(logFile);
                end
                if serverLog ~= ""
                    error('Terminal:NoPort', ...
                        'Server did not report a port within %d seconds.\nServer output:\n%s', ...
                        maxWait, serverLog);
                else
                    error('Terminal:NoPort', ...
                        'Server did not report a port within %d seconds.', maxWait);
                end
            end
            % Clean up log file on success (server keeps running).
            % Keep it around — it's useful for debugging if something
            % goes wrong later. It will be cleaned up by the OS.

            obj.ServerProcess = struct('pid', serverPid, 'port', port);
            obj.BaseURL = sprintf('http://127.0.0.1:%d', port);
            obj.PollSeq = 0;

            % --- Build MCP registration command to pre-populate in terminal ---
            if ~isempty(ecInfo)
                mcpJson = sprintf('{"command":"%s","args":["--mcp","--ec-port","%d","--mwapikey","%s"]}', ...
                    strrep(obj.ServerBinary, '\', '\\'), ecInfo.ecPort, ecInfo.mwapikey);
                obj.MCPCommand = sprintf('devai launch claude mcp add-json terminal-mcp ''%s'' 2>/dev/null; devai launch claude', mcpJson);
            end

            % Pre-create weboptions to avoid re-parsing every call.
            obj.ReadOpts = weboptions('HeaderFields', {'Authorization', obj.AuthToken}, ...
                'Timeout', 2, 'ContentType', 'json');
            obj.WriteOpts = weboptions('HeaderFields', {'Authorization', obj.AuthToken}, ...
                'MediaType', 'application/json', 'Timeout', 2);

            % --- Read MATLAB theme / font settings ---
            themeConfig = Terminal.buildThemeConfig();

            % --- Locate web assets ---
            % extractWebAssets (called above) ensures these exist.
            htmlDir = fullfile(fileparts(mfilename('fullpath')), 'html');
            htmlFile = fullfile(htmlDir, 'index.html');
            if ~isfile(htmlFile)
                % Installed via .mltbx — use extracted cache.
                htmlDir = fullfile(prefdir, 'matlab-terminal', 'html');
                htmlFile = fullfile(htmlDir, 'index.html');
            end
            if ~isfile(htmlFile)
                error('Terminal:HTMLNotFound', ...
                    'Could not find index.html at:\n  %s', htmlFile);
            end

            if isprop(parent, 'AutoResizeChildren')
                parent.AutoResizeChildren = 'off';
            end

            obj.HTMLComponent = uihtml(parent);
            obj.HTMLComponent.Position = [0 0 parent.Position(3) parent.Position(4)];
            obj.HTMLComponent.HTMLSource = htmlFile;

            % Auto-resize.
            obj.ParentFigure.SizeChangedFcn = @(~,~) set(obj.HTMLComponent, ...
                'Position', [0 0 obj.ParentFigure.Position(3) obj.ParentFigure.Position(4)]);

            % Clean up when figure is closed.
            obj.ParentFigure.CloseRequestFcn = @(~,~) delete(obj);

            % Register this instance.
            Terminal.registry('add', obj);

            % Use a one-shot timer to initialize AFTER the constructor returns.
            % This prevents DataChangedFcn from firing during construction.
            initTimer = timer('StartDelay', 1.5, ...
                'TimerFcn', @(t,~) obj.deferredInit(t, themeConfig));
            start(initTimer);
        end

        function delete(obj)
            %DELETE Clean up: stop timer, kill server, close figure.
            Terminal.registry('remove', obj);
            if ~isempty(obj.PollTimer) && isvalid(obj.PollTimer)
                stop(obj.PollTimer);
                delete(obj.PollTimer);
            end
            if ~isempty(obj.ServerProcess) && isstruct(obj.ServerProcess) ...
                    && isfield(obj.ServerProcess, 'pid') && ~isnan(obj.ServerProcess.pid)
                Terminal.killProcess(obj.ServerProcess.pid);
            end
            if ~isempty(obj.ParentFigure) && isvalid(obj.ParentFigure)
                obj.ParentFigure.CloseRequestFcn = '';
                delete(obj.ParentFigure);
            end
        end
    end

    methods (Access = private)
        function deferredInit(obj, initTimer, themeConfig)
            %DEFERREDINIT Called after constructor returns to avoid reentrant callbacks.
            stop(initTimer);
            delete(initTimer);

            obj.ThemeConfig = themeConfig;
            obj.UseEvents = ~isMATLABReleaseOlderThan('R2023a');

            if obj.UseEvents
                % R2023a+: event-based API — no data loss, no buffering needed.
                obj.HTMLComponent.HTMLEventReceivedFcn = @(~, event) obj.onHTMLEvent(event);
                sendEventToHTMLSource(obj.HTMLComponent, 'init', themeConfig);
            else
                % Legacy: Data channel (last-write-wins).
                obj.HTMLComponent.DataChangedFcn = @(src, ~) obj.onJSMessage(src);
                obj.HTMLComponent.Data = struct('type', 'init', 'theme', themeConfig);
            end

            % Snapshot the current figure color for theme change detection.
            try
                obj.LastFigureColor = get(groot, 'defaultFigureColor');
            catch
                obj.LastFigureColor = [];
            end

            % Start polling for server output.
            obj.PollTimer = timer( ...
                'ExecutionMode', 'fixedSpacing', ...
                'Period', obj.POLL_INTERVAL, ...
                'TimerFcn', @(~,~) obj.pollOutput(), ...
                'ErrorFcn', @(~,~) []);
            start(obj.PollTimer);
        end

        function checkThemeChanged(obj)
            %CHECKTHEMECHANGED Compare current figure color to cached value.
            try
                c = get(groot, 'defaultFigureColor');
            catch
                return;
            end
            if isequal(c, obj.LastFigureColor)
                return;
            end
            obj.LastFigureColor = c;
            newConfig = Terminal.buildThemeConfig();
            obj.ThemeConfig = newConfig;
            obj.sendToJS(struct('type', 'theme', ...
                'theme', newConfig));
        end

        function onHTMLEvent(obj, event)
            %ONHTMLEVENT Handle events from JS via the R2023a+ event API.
            %   Still queued for the poll timer to avoid concurrent webwrite
            %   calls, but no JS-side data loss since events don't overwrite.
            msg = event.HTMLEventData;
            msg.type = event.HTMLEventName;
            obj.OutQueue{end+1} = msg;
        end

        function onJSMessage(obj, src)
            %ONJSMESSAGE Handle messages from JS via the legacy Data channel.
            %   Queues messages for the poll timer to process, avoiding
            %   concurrent webread/webwrite calls.
            msg = src.Data;
            if ~isstruct(msg) || ~isfield(msg, 'type')
                return;
            end
            obj.OutQueue{end+1} = msg;
        end

        function pollOutput(obj)
            %POLLOUTPUT Process queued JS messages, then poll for output.
            try
                % --- Periodic theme change detection ---
                obj.ThemePollCount = obj.ThemePollCount + 1;
                if obj.ThemePollCount >= obj.THEME_CHECK_TICKS
                    obj.ThemePollCount = 0;
                    obj.checkThemeChanged();
                end

                % --- Drain outbound queue (JS -> server) ---
                if ~isempty(obj.OutQueue)
                    if obj.UseEvents
                        % R2023a+: drain all — event API doesn't overwrite.
                        queue = obj.OutQueue;
                        obj.OutQueue = {};
                        for i = 1:numel(queue)
                            obj.processJSMessage(queue{i});
                        end
                    else
                        % Legacy: one at a time, then return so JS can
                        % read the response before Data is overwritten.
                        msg = obj.OutQueue{1};
                        obj.OutQueue(1) = [];
                        obj.processJSMessage(msg);
                        return;
                    end
                end

                % --- Poll for server output ---
                url = sprintf('%s/api/poll?since=%d', obj.BaseURL, obj.PollSeq);
                resp = webread(url, obj.ReadOpts);
                if isfield(resp, 'messages') && ~isempty(resp.messages)
                    msgs = resp.messages;
                    hasExited = false;
                    if iscell(msgs)
                        for i = 1:numel(msgs)
                            m = msgs{i};
                            if m.seq > obj.PollSeq
                                obj.PollSeq = m.seq;
                            end
                            if strcmp(m.type, 'exited')
                                hasExited = true;
                            end
                        end
                        obj.sendToJS(struct('type', 'batch', 'messages', {msgs}));
                    elseif isstruct(msgs)
                        for i = 1:numel(msgs)
                            if msgs(i).seq > obj.PollSeq
                                obj.PollSeq = msgs(i).seq;
                            end
                            if strcmp(msgs(i).type, 'exited')
                                hasExited = true;
                            end
                        end
                        obj.sendToJS(struct('type', 'batch', 'messages', {msgs}));
                    end
                    if hasExited
                        obj.checkAllExited();
                    end
                end
            catch
                % Ignore errors (server may be restarting or session gone).
            end
        end

        function processJSMessage(obj, msg)
            %PROCESSJSMESSAGE Execute a single queued JS message.
            switch msg.type
                case 'ready'
                    % HTML page (re)loaded — re-send init so JS can start.
                    % Query the server for existing sessions so JS can
                    % reconnect instead of creating new tabs.
                    initData = obj.ThemeConfig;
                    try
                        url = [obj.BaseURL, '/api/sessions'];
                        resp = webread(url, obj.ReadOpts);
                        if isfield(resp, 'ids') && ~isempty(resp.ids)
                            if ischar(resp.ids) || isstring(resp.ids)
                                ids = {char(resp.ids)};
                            else
                                ids = resp.ids;
                            end
                            initData.existingSessionIds = ids;
                            % Fetch scrollback for each session.
                            scrollbacks = struct();
                            for k = 1:numel(ids)
                                sid = ids{k};
                                try
                                    sbUrl = sprintf('%s/api/scrollback?id=%s', obj.BaseURL, sid);
                                    sbResp = webread(sbUrl, obj.ReadOpts);
                                    if isfield(sbResp, 'data')
                                        scrollbacks.(sid) = sbResp.data;
                                    end
                                catch
                                end
                            end
                            initData.scrollbacks = scrollbacks;
                        end
                    catch
                        % Server may not be ready yet — JS will create a
                        % new tab as usual.
                    end
                    if obj.UseEvents
                        sendEventToHTMLSource(obj.HTMLComponent, 'init', initData);
                    else
                        obj.HTMLComponent.Data = struct('type', 'init', 'theme', initData);
                    end
                case 'create'
                    createReq = struct('cols', 80, 'rows', 24, 'shell', obj.Shell);
                    resp = obj.serverPost('/api/create', createReq);
                    if ~isempty(resp) && isfield(resp, 'id')
                        obj.sendToJS(struct('type', 'created', 'id', resp.id));
                        % Pre-populate MCP registration command in the
                        % first session. Delayed so the shell prompt is
                        % ready. Sent without a newline — user hits Enter.
                        if ~isempty(obj.MCPCommand)
                            sid = resp.id;
                            cmd = obj.MCPCommand;
                            obj.MCPCommand = [];  % only for the first session
                            mcpTimer = timer('StartDelay', 1.0, ...
                                'TimerFcn', @(t,~) obj.sendMCPHint(t, sid, cmd));
                            start(mcpTimer);
                        end
                    end
                case 'input'
                    obj.serverPost('/api/input', struct('id', msg.id, 'data', msg.data));
                case 'resize'
                    obj.serverPost('/api/resize', struct('id', msg.id, 'cols', msg.cols, 'rows', msg.rows));
                case 'close'
                    obj.serverPost('/api/close', struct('id', msg.id));
            end
        end

        function checkAllExited(obj)
            %CHECKALLEXITED Close window if server has no active sessions.
            try
                url = [obj.BaseURL, '/api/sessions'];
                resp = webread(url, obj.ReadOpts);
                if resp.count > 0
                    return;  % Other sessions still active.
                end
            catch
                % Server gone — close anyway.
            end
            fig = obj.ParentFigure;
            closeTimer = timer('StartDelay', 0.5, ...
                'TimerFcn', @(t,~) Terminal.deferredClose(t, obj, fig));
            start(closeTimer);
        end

        function resp = serverPost(obj, endpoint, data)
            %SERVERPOST Send a POST request to the Go server.
            url = [obj.BaseURL, endpoint];
            resp = webwrite(url, data, obj.WriteOpts);
        end

        function sendMCPHint(obj, tmr, sessionId, cmd)
            %SENDMCPHINT Pre-populate MCP registration command in a session.
            stop(tmr);
            delete(tmr);
            try
                obj.serverPost('/api/input', struct('id', sessionId, 'data', cmd));
            catch
            end
        end

        function sendToJS(obj, msg)
            %SENDTOJS Send a message to JS.
            if isempty(obj.HTMLComponent) || ~isvalid(obj.HTMLComponent)
                return;
            end
            if obj.UseEvents
                sendEventToHTMLSource(obj.HTMLComponent, msg.type, msg);
            else
                obj.HTMLComponent.Data = msg;
            end
        end
    end

    methods (Static)
        function v = version()
            %VERSION Return the installed toolbox version string.
            %
            %   v = Terminal.version()
            v = TerminalVersion();
        end

        function terminals = list()
            %LIST Return handles to all running Terminal instances.
            %
            %   terminals = Terminal.list()
            %
            %   Returns a (possibly empty) array of Terminal handles.
            terminals = Terminal.registry('get');
        end

        function closeAll()
            %CLOSEALL Close all running Terminal instances.
            %
            %   Terminal.closeAll()
            terminals = Terminal.list();
            for i = 1:numel(terminals)
                delete(terminals(i));
            end
        end

        function update()
            %UPDATE Check for and install the latest toolbox version from GitHub.
            %
            %   Terminal.update()
            %
            %   Queries the latest release from GitHub, displays version
            %   information, and prompts for confirmation before updating.

            disp('Checking for updates...');

            % Query GitHub for the latest release.
            url = sprintf('https://api.github.com/repos/%s/releases/latest', ...
                Terminal.GITHUB_REPO);
            try
                opts = weboptions('ContentType', 'json', 'Timeout', 10);
                release = webread(url, opts);
            catch me
                error('Terminal:UpdateFailed', ...
                    'Could not reach GitHub:\n  %s', me.message);
            end

            latestVersion = string(release.tag_name);
            if startsWith(latestVersion, 'v')
                latestVersion = extractAfter(latestVersion, 1);
            end

            disp(['  Installed version: ', Terminal.version()]);
            disp(['  Latest version:    ', char(latestVersion)]);

            % Find the .mltbx asset in the release.
            mltbxURL = '';
            assets = release.assets;
            for i = 1:numel(assets)
                if iscell(assets)
                    asset = assets{i};
                else
                    asset = assets(i);
                end
                if endsWith(asset.name, '.mltbx')
                    mltbxURL = asset.browser_download_url;
                    break;
                end
            end
            if isempty(mltbxURL)
                error('Terminal:UpdateFailed', ...
                    'No .mltbx file found in the latest GitHub release.');
            end

            % Ask for confirmation.
            if latestVersion == Terminal.version()
                disp('Already up to date.');
                reply = input('Reinstall current version? (y/n): ', 's');
            else
                reply = input(sprintf('Update from %s to %s? (y/n): ', ...
                    Terminal.version(), latestVersion), 's');
            end
            if ~strcmpi(reply, 'y')
                disp('Update cancelled.');
                return;
            end

            % Step 1: Close all open terminals.
            disp('Step 1/5: Closing all open terminals...');
            Terminal.closeAll();

            % Step 2: Uninstall current toolbox.
            disp('Step 2/5: Uninstalling current version...');
            matlab.addons.uninstall(Terminal.TOOLBOX_ID);

            % Step 3: Clear cached assets.
            cacheRoot = fullfile(prefdir, 'matlab-terminal');
            if isfolder(cacheRoot)
                disp('Step 3/5: Clearing cached assets...');
                rmdir(cacheRoot, 's');
            else
                disp('Step 3/5: No cached assets to clear.');
            end

            % Step 4: Download the latest .mltbx.
            disp('Step 4/5: Downloading latest release...');
            tmpFile = fullfile(tempdir, 'Terminal.mltbx');
            websave(tmpFile, mltbxURL);

            % Step 5: Install the new version.
            disp('Step 5/5: Installing new version...');
            matlab.addons.install(tmpFile);
            delete(tmpFile);

            fprintf('Successfully updated Terminal to version %s.\n', latestVersion);
        end
    end

    methods (Static, Access = private)
        function result = registry(action, obj)
            %REGISTRY Persistent store for tracking Terminal instances.
            persistent instances
            if isempty(instances)
                instances = Terminal.empty;
            end
            switch action
                case 'add'
                    instances(end+1) = obj;
                case 'remove'
                    instances(instances == obj) = [];
                case 'get'
                    % Prune deleted handles before returning.
                    instances(~isvalid(instances)) = [];
                    result = instances;
                    return;
            end
            result = Terminal.empty;
        end

        function htmlDir = extractWebAssets()
            %EXTRACTWEBASSETS Extract web assets from web_assets.mat to a cache dir.
            %   packageToolbox drops .html/.css/.js files, so we bundle them
            %   in a .mat file and extract at runtime.
            cacheRoot = fullfile(prefdir, 'matlab-terminal');
            cacheDir = fullfile(cacheRoot, 'html');
            stampFile = fullfile(cacheRoot, '.extracted');

            matFile = fullfile(fileparts(mfilename('fullpath')), 'web_assets.mat');
            if ~isfile(matFile)
                % Running from source — no .mat file needed.
                htmlDir = cacheDir;
                return;
            end

            % Re-extract if the .mat file is newer than our stamp,
            % meaning a new toolbox version was installed.
            matInfo = dir(matFile);
            needsExtract = true;
            if isfile(stampFile)
                stampInfo = dir(stampFile);
                needsExtract = matInfo.datenum > stampInfo.datenum;
            end

            if ~needsExtract
                htmlDir = cacheDir;
                return;
            end

            % Wipe old cache entirely before extracting.
            if isfolder(cacheRoot)
                fprintf('Clearing old Terminal cache at:\n  %s\n', cacheRoot);
                rmdir(cacheRoot, 's');
            end

            fprintf('Extracting Terminal assets to:\n  %s\n', cacheRoot);

            S = load(matFile, 'assets');
            fields = fieldnames(S.assets);
            for i = 1:numel(fields)
                entry = S.assets.(fields{i});
                dst = fullfile(cacheRoot, entry.path);
                dstDir = fileparts(dst);
                if ~isfolder(dstDir)
                    mkdir(dstDir);
                end
                fid = fopen(dst, 'w');
                fwrite(fid, entry.data);
                fclose(fid);
                % Make binaries executable.
                if isfield(entry, 'executable') && entry.executable && ~ispc
                    system(sprintf('chmod +x "%s"', dst));
                end
            end

            % Touch stamp file so we know this extraction is current.
            fid = fopen(stampFile, 'w');
            fclose(fid);

            htmlDir = cacheDir;
        end

        function deferredClose(tmr, obj, fig)
            stop(tmr);
            delete(tmr);
            delete(obj);
            if ~isempty(fig) && isvalid(fig)
                close(fig);
            end
        end

        function binaryPath = findBinary()
            binaryName = Terminal.SERVER_BINARY_NAME;
            if ispc
                binaryName = [binaryName, '.exe'];
            end

            % Check dist/<arch>/ directory (development builds).
            arch = computer('arch');
            candidate = fullfile(fileparts(fileparts(mfilename('fullpath'))), 'dist', arch, binaryName);
            if isfile(candidate)
                binaryPath = candidate;
                return;
            end

            % Check extracted cache (from web_assets.mat).
            candidate = fullfile(prefdir, 'matlab-terminal', 'bin', arch, binaryName);
            if isfile(candidate)
                binaryPath = candidate;
                return;
            end

            % Check userpath/bin (installed via Terminal.install).
            candidate = fullfile(userpath, 'bin', binaryName);
            if isfile(candidate)
                binaryPath = candidate;
                return;
            end

            if ispc
                [st, result] = system(sprintf('where "%s" 2>nul', binaryName));
            else
                [st, result] = system(sprintf('which "%s" 2>/dev/null', binaryName));
            end
            if st == 0
                binaryPath = strtrim(result);
                lines = splitlines(binaryPath);
                binaryPath = lines{1};
                return;
            end

            binaryPath = '';
        end

        function themeConfig = buildThemeConfig()
            fontFamily = 'Consolas, ''DejaVu Sans Mono'', ''Liberation Mono'', monospace';

            try
                s = settings;
                fontSize = s.matlab.fonts.codefont.Size.ActiveValue;
            catch
                fontSize = 14;
            end

            % MATLAB reports font size in points; xterm.js expects CSS
            % pixels. Convert using screen DPI (pt * PPI/72 = px).
            try
                screenPPI = get(groot, 'ScreenPixelsPerInch');
            catch
                screenPPI = 96;
            end
            fontSize = round(fontSize * screenPPI / 72);

            isDark = false;
            try
                % Check default figure background luminance (no side effects).
                c = get(groot, 'defaultFigureColor');
                luminance = 0.2126*c(1) + 0.7152*c(2) + 0.0722*c(3);
                isDark = luminance < 0.5;
            catch
            end

            if isDark
                themeConfig = struct( ...
                    'isDark', true, ...
                    'fontFamily', fontFamily, ...
                    'fontSize', fontSize, ...
                    'background',  '#1e1e1e', ...
                    'foreground',  '#d4d4d4', ...
                    'cursor',      '#aeafad', ...
                    'selectionBackground', '#264f78');
            else
                themeConfig = struct( ...
                    'isDark', false, ...
                    'fontFamily', fontFamily, ...
                    'fontSize', fontSize, ...
                    'background',  '#ffffff', ...
                    'foreground',  '#333333', ...
                    'cursor',      '#333333', ...
                    'selectionBackground', '#add6ff');
            end
        end

        function shell = defaultShell()
            %DEFAULTSHELL Return the system default shell (mirrors server logic).
            if ispc
                shell = string(getenv('COMSPEC'));
                if shell == ""
                    shell = "cmd.exe";
                end
            else
                shell = string(getenv('SHELL'));
                if shell == ""
                    shell = "/bin/sh";
                end
            end
        end

        function validateShell(shell)
            %VALIDATESHELL Error if the given shell is not found on the system.
            if isfile(shell)
                return;  % Absolute path exists.
            end
            % Check if it's on PATH.
            if ispc
                [st, ~] = system(sprintf('where "%s" >nul 2>&1', shell));
            else
                [st, ~] = system(sprintf('which "%s" >/dev/null 2>&1', shell));
            end
            if st ~= 0
                if ispc
                    common = 'cmd.exe, powershell.exe, pwsh.exe, wsl.exe';
                else
                    common = 'bash, zsh, sh, fish';
                end
                error('Terminal:ShellNotFound', ...
                    'Shell "%s" not found.\nCommon shells for this platform: %s', ...
                    shell, common);
            end
        end

        function killProcess(pid)
            %KILLPROCESS Terminate a process by PID (cross-platform).
            if ispc
                system(sprintf('taskkill /PID %d /F >nul 2>&1', pid));
            else
                system(sprintf('kill %d 2>/dev/null', pid));
            end
        end

        function ecInfo = ensureEmbeddedConnector()
            %ENSUREEMBEDDEDCONNECTOR Start the EC and return connection details.
            %   Returns a struct with fields ecPort (double) and mwapikey (string),
            %   or [] if the EC could not be started. Safe to call multiple
            %   times — skips startup if the EC is already running.
            persistent cachedInfo
            if ~isempty(cachedInfo)
                ecInfo = cachedInfo;
                return;
            end

            try
                % Check if the EC is already running. Worker.start
                % guards on this.Started internally, but checking first
                % avoids the "Starting CPP Connector" console output.
                alreadyRunning = connector.internal.Worker.isMATLABOnline();

                if ~alreadyRunning
                    % Set MWAPIKEY if not already present.
                    if isempty(getenv('MWAPIKEY'))
                        mwapikey = lower(sprintf('%s-%s-%s-%s-%s', ...
                            dec2hex(randi([0 2^32-1], 1, 1), 8), ...
                            dec2hex(randi([0 2^16-1], 1, 1), 4), ...
                            dec2hex(randi([0 2^16-1], 1, 1), 4), ...
                            dec2hex(randi([0 2^16-1], 1, 1), 4), ...
                            dec2hex(randi([0 2^48-1], 1, 1), 12)));
                        setenv('MWAPIKEY', mwapikey);
                    end

                    % Set MATLAB_LOG_DIR if not already present.
                    if isempty(getenv('MATLAB_LOG_DIR'))
                        logDir = fullfile(tempdir, 'matlab-terminal-ec');
                        if ~exist(logDir, 'dir'), mkdir(logDir); end
                        setenv('MATLAB_LOG_DIR', logDir);
                    end

                    % Start the Embedded Connector.
                    evalc('connector.internal.Worker.start');
                end

                % Extract port from the connector base URL.
                baseUrl = connector.getBaseUrl('');
                ecPort = regexp(baseUrl, ':(\d+)', 'tokens', 'once');
                ecPort = str2double(ecPort{1});
                mwapikey = getenv('MWAPIKEY');
                if ecPort <= 0 || isempty(mwapikey)
                    ecInfo = [];
                    return;
                end

                ecInfo = struct('ecPort', ecPort, 'mwapikey', mwapikey);
                cachedInfo = ecInfo;
            catch
                ecInfo = [];
            end
        end


    end
end
