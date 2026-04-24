classdef (Sealed) SimulinkTerminal < handle
    %SIMULINKTERMINAL Docks a terminal panel into Simulink Studio.
    %
    %   Reuses the matlab-terminal Go server and xterm.js UI, docked into
    %   Simulink via the DAS.Studio / GLUE2.DDGComponent / DDG webbrowser
    %   widget framework. The CEF browser talks directly to the Go server
    %   via fetch() — no MATLAB middleman for I/O.
    %
    %   Usage:
    %     SimulinkTerminal.show()                — dock terminal in active Studio
    %     SimulinkTerminal.show(Theme="dracula") — with a specific theme
    %     SimulinkTerminal.close()               — close all terminal panels
    %
    %   Requires:
    %     - Simulink model open (provides DAS.Studio)
    %     - matlab-terminal-server binary installed (via Terminal toolbox)

    % Copyright 2026 The MathWorks, Inc.

    properties (Constant)
        Id              = 'SimulinkTerminal'
        Title           = 'Terminal'
        DockSide        = 'Right'
        PreferredWidth  = 600
        PreferredHeight = 400
        ServerBinaryName = 'matlab-terminal-server'
    end

    properties (Access = private)
        Studio
        Component
        ServerProcess       % struct: pid, port
        AuthToken           % random hex auth string
        ServerBinary        % absolute path to Go binary
        Theme               % theme name or struct
        HTMLDir             % path to html/ directory
        IsCleaningUp logical = false
    end

    %% -------- Constructor / Destructor
    methods
        function this = SimulinkTerminal(options)
            arguments
                options.Theme = "light"
            end
            this.Theme = options.Theme;
        end

        function delete(this)
            this.cleanup();
            SimulinkTerminal.registry('remove', this);
        end
    end

    %% -------- Public Static API
    methods (Static)
        function panel = show(options)
            %SHOW Open a terminal panel docked in the active Simulink Studio.
            arguments
                options.Theme = "light"
            end

            % Get active Simulink Studio.
            studio = [];
            try
                studios = DAS.Studio.getAllStudiosSortedByMostRecentlyActive;
                if ~isempty(studios)
                    studio = studios(1);
                end
            catch
                % DAS.Studio may not be available outside Simulink.
            end
            if isempty(studio)
                error('SimulinkTerminal:NoStudio', ...
                    'No Simulink model is open. Open a model first, then run SimulinkTerminal.show().');
            end

            % Destroy existing panel if present.
            existing = SimulinkTerminal.findExistingComponent(studio);
            if ~isempty(existing)
                % Clean up the old panel instance.
                try
                    oldPanels = SimulinkTerminal.registry('get');
                    for i = 1:numel(oldPanels)
                        if ~isempty(oldPanels{i}) && isvalid(oldPanels{i})
                            oldPanels{i}.cleanup();
                        end
                    end
                catch
                    % Ignore errors during old panel cleanup.
                end
                try
                    studio.destroyComponent(existing);
                catch
                    % Component may already be destroyed.
                end
            end

            % Create new instance.
            panel = SimulinkTerminal(Theme=options.Theme);
            panel.Studio = studio;

            % Start server and dock.
            panel.startServer();
            panel.dock(studio);

            % Register.
            SimulinkTerminal.registry('add', panel);
        end

        function close()
            %CLOSE Close all SimulinkTerminal panels across all Studios.
            try
                studios = DAS.Studio.getAllStudiosSortedByMostRecentlyActive;
                for s = studios
                    comp = SimulinkTerminal.findExistingComponent(s);
                    if ~isempty(comp)
                        s.destroyComponent(comp);
                    end
                end
            catch
                % DAS.Studio may not be available.
            end
            % Clean up all registered panels.
            panels = SimulinkTerminal.registry('get');
            for i = 1:numel(panels)
                try
                    if isvalid(panels{i})
                        panels{i}.cleanup();
                    end
                catch
                    % Ignore errors during panel cleanup.
                end
            end
        end
    end

    %% -------- DDG Framework Callback
    methods
        function dlg = getDialogSchema(this)
            %GETDIALOGSCHEMA Build DDG schema with webbrowser widget.
            if isempty(this.ServerProcess)
                error('SimulinkTerminal:NoServer', 'Server not started.');
            end

            % Resolve and encode theme.
            try
                themeConfig = internal.Themes.resolve(this.Theme);
            catch
                % Fallback light theme if Themes utility unavailable.
                themeConfig = struct('isDark', false, ...
                    'background', '#ffffff', 'foreground', '#1e1e1e', ...
                    'cursor', '#1e1e1e', 'selectionBackground', '#add6ff', ...
                    'fontFamily', 'Consolas, monospace', 'fontSize', 14);
            end
            themeJson = urlencode(jsonencode(themeConfig));

            serverUrl = sprintf('http://127.0.0.1:%d/static/simulink.html?t=%s&theme=%s', ...
                this.ServerProcess.port, this.AuthToken, themeJson);

            src.Type                        = 'webbrowser';
            src.Tag                         = 'SimulinkTerminal_Webview';
            src.Url                         = serverUrl;
            src.DialogRefresh               = true;
            src.DisableContextMenu          = false;
            src.EnableInspectorInContextMenu = true;
            src.EnableInspectorOnLoad       = false;

            dlg.Items           = {src};
            dlg.DialogTag       = 'SimulinkTerminal_Dialog';
            dlg.DialogTitle     = '';
            dlg.EmbeddedButtonSet = {''};
            dlg.MinMaxButtons   = 1;
            dlg.IsScrollable    = false;
        end
    end

    %% -------- Private Instance Methods
    methods (Access = private)
        function startServer(this)
            %STARTSERVER Launch the Go server binary.

            % Locate binary.
            this.ServerBinary = SimulinkTerminal.findBinary();
            if isempty(this.ServerBinary)
                error('SimulinkTerminal:BinaryNotFound', ...
                    ['Server binary "%s" not found.\n' ...
                     'Install the Terminal toolbox or ensure the binary is on PATH.'], ...
                    SimulinkTerminal.ServerBinaryName);
            end

            % Resolve HTML directory.
            this.HTMLDir = SimulinkTerminal.resolveHTMLDir();
            if isempty(this.HTMLDir)
                error('SimulinkTerminal:HTMLNotFound', ...
                    'Could not find the html/ directory with simulink.html.');
            end

            % Generate auth token.
            this.AuthToken = SimulinkTerminal.generateToken();

            % Build args.
            readyFile = [tempname, '.txt'];
            matlabPid = num2str(feature('getpid'));
            matlabRoot = matlabroot;
            args = sprintf('--static-dir "%s" --ready-file "%s" --env "MATLAB_PID=%s" --env "MATLAB_ROOT=%s"', ...
                this.HTMLDir, readyFile, matlabPid, matlabRoot);

            % Pass token via env var (not CLI args) for security.
            setenv('MATLAB_TERMINAL_TOKEN', this.AuthToken);

            logFile = [tempname, '.log'];
            if ispc
                batFile = [tempname, '.bat'];
                fid = fopen(batFile, 'w');
                fprintf(fid, '@"%s" %s > "%s" 2>&1\n', this.ServerBinary, args, logFile);
                fclose(fid);
                system(sprintf('start "" /b cmd /c call "%s"', batFile));
            else
                cmd = sprintf('"%s" %s > "%s" 2>&1 &', this.ServerBinary, args, logFile);
                system(sprintf('/bin/sh -c ''%s''', cmd));
            end

            % Clear env var immediately.
            setenv('MATLAB_TERMINAL_TOKEN', '');

            % Wait for ready file with PID/PORT.
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
                    SimulinkTerminal.killProcess(serverPid);
                end
                serverLog = '';
                if isfile(logFile)
                    try serverLog = fileread(logFile); catch, end %#ok<EMCATCH>
                    delete(logFile);
                end
                if strlength(serverLog) > 0
                    error('SimulinkTerminal:NoPort', ...
                        'Server did not report a port within %d seconds.\nServer output:\n%s', ...
                        maxWait, serverLog);
                else
                    error('SimulinkTerminal:NoPort', ...
                        'Server did not report a port within %d seconds.', maxWait);
                end
            end

            this.ServerProcess = struct('pid', serverPid, 'port', port);
            % fprintf('Terminal server started on port %d (PID: %d)\n', port, serverPid);
        end

        function dock(this, studio)
            %DOCK Create DDG component and dock it in the Studio.

            % Destroy existing component if any.
            existing = SimulinkTerminal.findExistingComponent(studio);
            if ~isempty(existing)
                studio.destroyComponent(existing);
            end

            component = GLUE2.DDGComponent(studio, SimulinkTerminal.Id, this);
            component.DestroyOnHide = true;
            studio.registerComponent(component);
            component.setPreferredSize(SimulinkTerminal.PreferredWidth, ...
                                       SimulinkTerminal.PreferredHeight);
            studio.moveComponentToDock(component, SimulinkTerminal.Title, ...
                                       SimulinkTerminal.DockSide, 'Tabbed');

            this.Component = component;

            % Clean up when the panel is destroyed by the Studio.
            try
                addlistener(component, 'ObjectBeingDestroyed', @(~,~) this.cleanup());
            catch
                fprintf('Warning: Could not add cleanup listener. Use SimulinkTerminal.close() to clean up.\n');
            end

            pause(0.1);
        end

        function cleanup(this)
            %CLEANUP Idempotent resource cleanup.
            if this.IsCleaningUp, return; end
            this.IsCleaningUp = true;

            try
                % Kill server process.
                if ~isempty(this.ServerProcess) && isstruct(this.ServerProcess) ...
                        && isfield(this.ServerProcess, 'pid') && ~isnan(this.ServerProcess.pid)
                    SimulinkTerminal.killProcess(this.ServerProcess.pid);
                    % fprintf('Terminal server terminated (PID: %d)\n', this.ServerProcess.pid);
                end
            catch
                % Best-effort server termination.
            end

            % Reset state.
            this.ServerProcess = [];
            this.AuthToken = '';
            this.Component = [];
            this.IsCleaningUp = false;
        end
    end

    %% -------- Private Static Helpers
    methods (Static, Access = private)
        function comp = findExistingComponent(studio)
            %FINDEXISTINGCOMPONENT Find a SimulinkTerminal DDG component in a Studio.
            comp = [];
            try
                comps = studio.getAllComponents();
                for i = 1:numel(comps)
                    if strcmp(comps{i}.getName(), SimulinkTerminal.Id)
                        comp = comps{i};
                        return;
                    end
                end
            catch
                % Studio may not support getAllComponents.
            end
        end

        function result = registry(action, obj)
            %REGISTRY Persistent registry for tracking active panel instances.
            persistent instances
            if isempty(instances)
                instances = {};
            end
            switch action
                case 'add'
                    instances{end+1} = obj;
                case 'remove'
                    instances(cellfun(@(x) ~isvalid(x) || x == obj, instances)) = [];
                case 'get'
                    % Prune invalid handles.
                    instances(cellfun(@(x) ~isvalid(x), instances)) = [];
                    result = instances;
                    return;
                otherwise
                    error('SimulinkTerminal:InvalidAction', ...
                        'Unknown registry action: %s', action);
            end
            result = instances;
        end

        function binaryPath = findBinary()
            %FINDBINARY Locate the matlab-terminal-server binary.
            %   Searches: dist/<arch>/, prefdir cache, userpath/bin, system PATH.
            binaryName = SimulinkTerminal.ServerBinaryName;
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

            % Check system PATH.
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

        function htmlDir = resolveHTMLDir()
            %RESOLVEHTMLDIR Find the html/ directory containing simulink.html.
            %   Checks source directory first, then prefdir cache.

            % Source directory (development / addpath usage).
            candidate = fullfile(fileparts(mfilename('fullpath')), 'html');
            if isfile(fullfile(candidate, 'simulink.html'))
                htmlDir = candidate;
                return;
            end

            % Extracted cache (from .mltbx installation).
            candidate = fullfile(prefdir, 'matlab-terminal', 'html');
            if isfile(fullfile(candidate, 'simulink.html'))
                htmlDir = candidate;
                return;
            end

            htmlDir = '';
        end

        function token = generateToken()
            %GENERATETOKEN Generate a 32-char hex auth token.
            token = '';
            try
                if ispc
                    [status, token] = system('powershell -c "[guid]::NewGuid().ToString(''N'')"');
                    if status == 0
                        token = strtrim(token);
                    else
                        token = '';
                    end
                else
                    fid = fopen('/dev/urandom', 'r');
                    if fid ~= -1
                        bytes = fread(fid, 16, '*uint8');
                        fclose(fid);
                        token = sprintf('%02x', bytes);
                    end
                end
            catch
                % Fall through to randi fallback below.
            end
            if strlength(token) ~= 32
                token = sprintf('%04x', randi(65535, 1, 8));
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
    end
end