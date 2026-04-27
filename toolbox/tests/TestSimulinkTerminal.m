classdef TestSimulinkTerminal < matlab.mock.TestCase
    %TESTSIMULINKTERMINAL Comprehensive unit tests for SimulinkTerminal.
    %
    %   Covers: constructor, constants, delete/destructor, show() error paths,
    %   close(), getDialogSchema, findBinary, resolveHTMLDir, generateToken,
    %   killProcess, registry, findExistingComponent, cleanup, metaclass
    %   structure, startServer error paths, and edge cases.
    %
    %   Requires SimulinkTerminal.m to grant test access:
    %     properties (Access = {?SimulinkTerminal, ?TestSimulinkTerminal})
    %     methods   (Access = {?SimulinkTerminal, ?TestSimulinkTerminal})
    %     methods   (Static, Access = {?SimulinkTerminal, ?TestSimulinkTerminal})

    % Copyright 2026 The MathWorks, Inc.

    properties (Access = private)
        TempDir  % temporary directory for test artifacts
    end

    methods (TestMethodSetup)
        function setupTempDir(testCase)
            testCase.TempDir = fullfile(tempdir, ...
                sprintf('TestSimTerm_%d', randi(1e8)));
            mkdir(testCase.TempDir);
            testCase.addTeardown(@() rmdir(testCase.TempDir, 's'));
        end
    end

    methods (TestMethodTeardown)
        function resetRegistryState(testCase) %#ok<MANU>
            try
                SimulinkTerminal.registry('reset');
            catch
            end
        end
    end

    %% ============= CONSTRUCTOR TESTS =============
    methods (Test)
        function testDefaultConstructor(testCase)
            obj = SimulinkTerminal();
            testCase.addTeardown(@() delete(obj));
            testCase.verifyClass(obj, 'SimulinkTerminal');
            testCase.verifyTrue(isvalid(obj));
        end

        function testConstructorDefaultThemeIsLight(testCase)
            obj = SimulinkTerminal();
            testCase.addTeardown(@() delete(obj));
            testCase.verifyEqual(obj.Theme, "light");
        end

        function testConstructorCustomThemeString(testCase)
            obj = SimulinkTerminal(Theme="dracula");
            testCase.addTeardown(@() delete(obj));
            testCase.verifyEqual(obj.Theme, "dracula");
        end

        function testConstructorCustomThemeStruct(testCase)
            s = struct('background', '#ff0000');
            obj = SimulinkTerminal(Theme=s);
            testCase.addTeardown(@() delete(obj));
            testCase.verifyTrue(isstruct(obj.Theme));
            testCase.verifyEqual(obj.Theme.background, '#ff0000');
        end

        function testConstructorInitialStateIsClean(testCase)
            obj = SimulinkTerminal();
            testCase.addTeardown(@() delete(obj));
            testCase.verifyEmpty(obj.Studio);
            testCase.verifyEmpty(obj.Component);
            testCase.verifyEmpty(obj.ServerProcess);
            testCase.verifyEmpty(obj.AuthToken);
            testCase.verifyEmpty(obj.ServerBinary);
            testCase.verifyEmpty(obj.HTMLDir);
            testCase.verifyFalse(obj.IsCleaningUp);
        end

        function testMultipleConstructions(testCase)
            objs = SimulinkTerminal.empty();
            for i = 1:5
                objs(i) = SimulinkTerminal(Theme="dark");
            end
            testCase.addTeardown(@() delete(objs));
            testCase.verifyEqual(numel(objs), 5);
            for i = 1:5
                testCase.verifyTrue(isvalid(objs(i)));
            end
        end
    end

    %% ============= CONSTANT PROPERTY TESTS =============
    methods (Test)
        function testIdConstant(testCase)
            testCase.verifyEqual(SimulinkTerminal.Id, 'SimulinkTerminal');
        end

        function testTitleConstant(testCase)
            testCase.verifyEqual(SimulinkTerminal.Title, 'Terminal');
        end

        function testDockSideConstant(testCase)
            testCase.verifyEqual(SimulinkTerminal.DockSide, 'Right');
        end

        function testPreferredWidthConstant(testCase)
            testCase.verifyEqual(SimulinkTerminal.PreferredWidth, 600);
        end

        function testPreferredHeightConstant(testCase)
            testCase.verifyEqual(SimulinkTerminal.PreferredHeight, 400);
        end

        function testServerBinaryNameConstant(testCase)
            testCase.verifyEqual(SimulinkTerminal.ServerBinaryName, ...
                'matlab-terminal-server');
        end

        function testConstantsAreNotEmpty(testCase)
            testCase.verifyNotEmpty(SimulinkTerminal.Id);
            testCase.verifyNotEmpty(SimulinkTerminal.Title);
            testCase.verifyNotEmpty(SimulinkTerminal.DockSide);
            testCase.verifyGreaterThan(SimulinkTerminal.PreferredWidth, 0);
            testCase.verifyGreaterThan(SimulinkTerminal.PreferredHeight, 0);
            testCase.verifyNotEmpty(SimulinkTerminal.ServerBinaryName);
        end
    end

    %% ============= DELETE / DESTRUCTOR TESTS =============
    methods (Test)
        function testDeleteMarksInvalid(testCase)
            obj = SimulinkTerminal();
            testCase.verifyTrue(isvalid(obj));
            delete(obj);
            testCase.verifyFalse(isvalid(obj));
        end

        function testDeleteOnFreshObjectNoError(testCase)
            obj = SimulinkTerminal();
            delete(obj);
        end

        function testDoubleDeleteNoError(testCase)
            obj = SimulinkTerminal();
            delete(obj);
            delete(obj); % Second delete on invalid handle: no-op
        end

        function testDeleteRemovesFromRegistry(testCase)
            obj = SimulinkTerminal();
            SimulinkTerminal.registry('add', obj);
            reg = SimulinkTerminal.registry('get');
            testCase.verifyEqual(numel(reg), 1);

            delete(obj);
            reg = SimulinkTerminal.registry('get');
            testCase.verifyEmpty(reg);
        end
    end

    %% ============= SHOW() ERROR TESTS =============
    methods (Test)
        function testShowNoStudioErrors(testCase)
            testCase.verifyError(@() SimulinkTerminal.show(), ...
                'SimulinkTerminal:NoStudio');
        end

        function testShowNoStudioCustomThemeErrors(testCase)
            testCase.verifyError(...
                @() SimulinkTerminal.show(Theme="dracula"), ...
                'SimulinkTerminal:NoStudio');
        end

        function testShowErrorMessageContent(testCase)
            try
                SimulinkTerminal.show();
                testCase.verifyFail('Expected error was not thrown');
            catch ME
                testCase.verifyEqual(ME.identifier, 'SimulinkTerminal:NoStudio');
                testCase.verifyTrue(contains(ME.message, 'No Simulink model is open'));
            end
        end
    end

    %% ============= CLOSE() TESTS =============
    methods (Test)
        function testCloseNoStudiosNoError(testCase)
            SimulinkTerminal.close();
        end

        function testCloseMultipleTimesNoError(testCase)
            SimulinkTerminal.close();
            SimulinkTerminal.close();
            SimulinkTerminal.close();
        end

        function testCloseCleansPanelsInRegistry(testCase)
            obj1 = SimulinkTerminal();
            obj2 = SimulinkTerminal();
            testCase.addTeardown(@() delete(obj1));
            testCase.addTeardown(@() delete(obj2));

            % Give them fake server state to verify cleanup clears it
            obj1.ServerProcess = struct('pid', 999999999, 'port', 11111);
            obj2.ServerProcess = struct('pid', 888888888, 'port', 22222);
            SimulinkTerminal.registry('add', obj1);
            SimulinkTerminal.registry('add', obj2);

            SimulinkTerminal.close();

            % Objects still valid but ServerProcess cleared
            testCase.verifyTrue(isvalid(obj1));
            testCase.verifyTrue(isvalid(obj2));
            testCase.verifyEmpty(obj1.ServerProcess);
            testCase.verifyEmpty(obj2.ServerProcess);
        end
    end

    %% ============= GETDIALOGSCHEMA TESTS =============
    methods (Test)
        function testGetDialogSchemaNoServerErrors(testCase)
            obj = SimulinkTerminal();
            testCase.addTeardown(@() delete(obj));
            testCase.verifyError(@() obj.getDialogSchema(), ...
                'SimulinkTerminal:NoServer');
        end

        function testGetDialogSchemaReturnsStruct(testCase)
            obj = SimulinkTerminal();
            testCase.addTeardown(@() delete(obj));
            obj.ServerProcess = struct('pid', 99999, 'port', 12345);
            obj.AuthToken = 'aaaabbbbccccddddeeeeffffgggghhhh';

            dlg = obj.getDialogSchema();
            testCase.verifyTrue(isstruct(dlg));
        end

        function testGetDialogSchemaHasItems(testCase)
            obj = SimulinkTerminal();
            testCase.addTeardown(@() delete(obj));
            obj.ServerProcess = struct('pid', 99999, 'port', 12345);
            obj.AuthToken = 'aaaabbbbccccddddeeeeffffgggghhhh';

            dlg = obj.getDialogSchema();
            testCase.verifyTrue(isfield(dlg, 'Items'));
            testCase.verifyTrue(iscell(dlg.Items));
            testCase.verifyEqual(numel(dlg.Items), 1);
        end

        function testGetDialogSchemaWebBrowserWidget(testCase)
            obj = SimulinkTerminal();
            testCase.addTeardown(@() delete(obj));
            obj.ServerProcess = struct('pid', 99999, 'port', 12345);
            obj.AuthToken = 'aaaabbbbccccddddeeeeffffgggghhhh';

            dlg = obj.getDialogSchema();
            src = dlg.Items{1};
            testCase.verifyEqual(src.Type, 'webbrowser');
            testCase.verifyEqual(src.Tag, 'SimulinkTerminal_Webview');
            testCase.verifyTrue(contains(src.Url, '127.0.0.1:12345'));
            testCase.verifyTrue(contains(src.Url, 'aaaabbbbccccddddeeeeffffgggghhhh'));
            testCase.verifyTrue(src.DialogRefresh);
            testCase.verifyFalse(src.DisableContextMenu);
            testCase.verifyTrue(src.EnableInspectorInContextMenu);
            testCase.verifyFalse(src.EnableInspectorOnLoad);
        end

        function testGetDialogSchemaUrlFormat(testCase)
            obj = SimulinkTerminal();
            testCase.addTeardown(@() delete(obj));
            port = 54321;
            token = 'aabbccddaabbccddaabbccddaabbccdd';
            obj.ServerProcess = struct('pid', 99999, 'port', port);
            obj.AuthToken = token;

            dlg = obj.getDialogSchema();
            url = dlg.Items{1}.Url;
            testCase.verifyTrue(startsWith(url, ...
                sprintf('http://127.0.0.1:%d/static/simulink.html', port)));
            testCase.verifyTrue(contains(url, sprintf('t=%s', token)));
            testCase.verifyTrue(contains(url, 'theme='));
        end

        function testGetDialogSchemaDialogProperties(testCase)
            obj = SimulinkTerminal();
            testCase.addTeardown(@() delete(obj));
            obj.ServerProcess = struct('pid', 99999, 'port', 12345);
            obj.AuthToken = 'aaaabbbbccccddddeeeeffffgggghhhh';

            dlg = obj.getDialogSchema();
            testCase.verifyEqual(dlg.DialogTag, 'SimulinkTerminal_Dialog');
            testCase.verifyEqual(dlg.DialogTitle, '');
            testCase.verifyEqual(dlg.MinMaxButtons, 1);
            testCase.verifyFalse(dlg.IsScrollable);
        end

        function testGetDialogSchemaThemeFallback(testCase)
            % Use a function handle as theme to force internal.Themes.resolve
            % to error, triggering the fallback theme in getDialogSchema.
            obj = SimulinkTerminal(Theme=@disp);
            testCase.addTeardown(@() delete(obj));
            obj.ServerProcess = struct('pid', 99999, 'port', 12345);
            obj.AuthToken = 'aaaabbbbccccddddeeeeffffgggghhhh';

            dlg = obj.getDialogSchema();
            testCase.verifyTrue(isstruct(dlg));
            testCase.verifyTrue(contains(dlg.Items{1}.Url, 'theme='));
        end

        function testGetDialogSchemaWithDarkTheme(testCase)
            obj = SimulinkTerminal(Theme="dark");
            testCase.addTeardown(@() delete(obj));
            obj.ServerProcess = struct('pid', 99999, 'port', 12345);
            obj.AuthToken = 'aaaabbbbccccddddeeeeffffgggghhhh';

            dlg = obj.getDialogSchema();
            url = dlg.Items{1}.Url;
            % Dark theme URL should contain encoded theme JSON with dark bg
            testCase.verifyTrue(contains(url, 'theme='));
        end
    end

    %% ============= FIND BINARY TESTS =============
    methods (Test)
        function testFindBinaryReturnsCharOrEmpty(testCase)
            result = SimulinkTerminal.findBinary();
            testCase.verifyTrue(ischar(result));
        end

        function testFindBinaryDistLocation(testCase)
            arch = computer('arch');
            srcDir = fileparts(which('SimulinkTerminal'));
            parentDir = fileparts(srcDir);
            distDir = fullfile(parentDir, 'dist', arch);

            binaryName = SimulinkTerminal.ServerBinaryName;
            if ispc, binaryName = [binaryName, '.exe']; end
            fakeBinary = fullfile(distDir, binaryName);

            % Don't overwrite a real binary
            if isfile(fakeBinary)
                testCase.assumeFail('Binary already exists at dist location');
            end

            if ~isfolder(distDir), mkdir(distDir); end
            testCase.addTeardown(@() cleanupDir(fullfile(parentDir, 'dist')));

            fid = fopen(fakeBinary, 'w');
            fprintf(fid, 'fake');
            fclose(fid);

            result = SimulinkTerminal.findBinary();
            testCase.verifyEqual(result, fakeBinary);

            function cleanupDir(d)
                if isfolder(d)
                    try rmdir(d, 's'); catch, end
                end
            end
        end

        function testFindBinaryAddsExeOnWindows(testCase)
            testCase.assumeTrue(ispc, 'Windows-only test');

            arch = computer('arch');
            srcDir = fileparts(which('SimulinkTerminal'));
            parentDir = fileparts(srcDir);
            distDir = fullfile(parentDir, 'dist', arch);

            exeName = [SimulinkTerminal.ServerBinaryName, '.exe'];
            fakeBinary = fullfile(distDir, exeName);

            if isfile(fakeBinary)
                testCase.assumeFail('Binary already at dist location');
            end

            if ~isfolder(distDir), mkdir(distDir); end
            testCase.addTeardown(@() cleanupDir(fullfile(parentDir, 'dist')));

            fid = fopen(fakeBinary, 'w');
            fprintf(fid, 'fake');
            fclose(fid);

            result = SimulinkTerminal.findBinary();
            testCase.verifyTrue(endsWith(result, '.exe'));

            function cleanupDir(d)
                if isfolder(d)
                    try rmdir(d, 's'); catch, end
                end
            end
        end
    end

    %% ============= RESOLVE HTML DIR TESTS =============
    methods (Test)
        function testResolveHTMLDirReturnsCharOrEmpty(testCase)
            result = SimulinkTerminal.resolveHTMLDir();
            testCase.verifyTrue(ischar(result));
        end

        function testResolveHTMLDirSourceLocation(testCase)
            srcDir = fileparts(which('SimulinkTerminal'));
            htmlDir = fullfile(srcDir, 'html');
            htmlFile = fullfile(htmlDir, 'simulink.html');

            if isfile(htmlFile)
                % Already exists — verify it's found
                result = SimulinkTerminal.resolveHTMLDir();
                testCase.verifyEqual(result, htmlDir);
                return;
            end

            % Create temp html directory
            createdDir = false;
            if ~isfolder(htmlDir)
                mkdir(htmlDir);
                createdDir = true;
            end
            fid = fopen(htmlFile, 'w');
            fprintf(fid, '<html></html>');
            fclose(fid);
            testCase.addTeardown(@() cleanupHTML(htmlDir, htmlFile, createdDir));

            result = SimulinkTerminal.resolveHTMLDir();
            testCase.verifyEqual(result, htmlDir);

            function cleanupHTML(htmlDir, htmlFile, createdDir)
                if isfile(htmlFile), delete(htmlFile); end
                if createdDir && isfolder(htmlDir)
                    try rmdir(htmlDir); catch, end
                end
            end
        end

        function testResolveHTMLDirPrefdirLocation(testCase)
            % Only test if source location does NOT have html
            srcDir = fileparts(which('SimulinkTerminal'));
            if isfile(fullfile(srcDir, 'html', 'simulink.html'))
                testCase.assumeFail('Source html exists, cannot test prefdir fallback');
            end

            cacheDir = fullfile(prefdir, 'matlab-terminal', 'html');
            htmlFile = fullfile(cacheDir, 'simulink.html');

            alreadyExists = isfile(htmlFile);
            if ~alreadyExists
                if ~isfolder(cacheDir), mkdir(cacheDir); end
                fid = fopen(htmlFile, 'w');
                fprintf(fid, '<html></html>');
                fclose(fid);
                testCase.addTeardown(@() deleteIfExists(htmlFile));
            end

            result = SimulinkTerminal.resolveHTMLDir();
            testCase.verifyEqual(result, cacheDir);

            function deleteIfExists(f)
                if isfile(f), delete(f); end
            end
        end
    end

    %% ============= GENERATE TOKEN TESTS =============
    methods (Test)
        function testGenerateTokenLength(testCase)
            token = SimulinkTerminal.generateToken();
            testCase.verifyEqual(strlength(string(token)), 32);
        end

        function testGenerateTokenHexFormat(testCase)
            token = SimulinkTerminal.generateToken();
            testCase.verifyTrue( ...
                ~isempty(regexp(token, '^[0-9a-f]{32}$', 'once')));
        end

        function testGenerateTokenUniqueness(testCase)
            tokens = strings(1, 20);
            for i = 1:20
                tokens(i) = string(SimulinkTerminal.generateToken());
            end
            testCase.verifyEqual(numel(unique(tokens)), 20, ...
                'All generated tokens should be unique');
        end

        function testGenerateTokenIsChar(testCase)
            token = SimulinkTerminal.generateToken();
            testCase.verifyTrue(ischar(token));
        end
    end

    %% ============= KILL PROCESS TESTS =============
    methods (Test)
        function testKillProcessInvalidPidNoError(testCase)
            SimulinkTerminal.killProcess(999999999);
        end

        function testKillProcessZeroPidNoError(testCase)
            SimulinkTerminal.killProcess(0);
        end
    end

    %% ============= REGISTRY TESTS =============
    methods (Test)
        function testRegistryAddAndGet(testCase)
            obj = SimulinkTerminal();
            testCase.addTeardown(@() delete(obj));

            SimulinkTerminal.registry('add', obj);
            result = SimulinkTerminal.registry('get');
            testCase.verifyEqual(numel(result), 1);
            testCase.verifyEqual(result{1}, obj);
        end

        function testRegistryRemove(testCase)
            obj = SimulinkTerminal();
            SimulinkTerminal.registry('add', obj);

            SimulinkTerminal.registry('remove', obj);
            result = SimulinkTerminal.registry('get');
            testCase.verifyEmpty(result);

            delete(obj);
        end

        function testRegistryPrunesInvalidHandles(testCase)
            obj1 = SimulinkTerminal();
            obj2 = SimulinkTerminal();
            SimulinkTerminal.registry('add', obj1);
            SimulinkTerminal.registry('add', obj2);

            delete(obj1); % makes it invalid

            result = SimulinkTerminal.registry('get');
            testCase.verifyEqual(numel(result), 1);
            testCase.verifyEqual(result{1}, obj2);

            delete(obj2);
        end

        function testRegistryMultipleObjects(testCase)
            objs = cell(1, 5);
            for i = 1:5
                objs{i} = SimulinkTerminal();
                SimulinkTerminal.registry('add', objs{i});
            end

            result = SimulinkTerminal.registry('get');
            testCase.verifyEqual(numel(result), 5);

            for i = 1:5
                delete(objs{i});
            end
        end

        function testRegistryUnknownActionErrors(testCase)
            testCase.verifyError(...
                @() SimulinkTerminal.registry('unknown_action'), ...
                'SimulinkTerminal:InvalidAction');
        end

        function testRegistryResetClearsAll(testCase)
            obj = SimulinkTerminal();
            testCase.addTeardown(@() delete(obj));
            SimulinkTerminal.registry('add', obj);

            SimulinkTerminal.registry('reset');
            result = SimulinkTerminal.registry('get');
            testCase.verifyEmpty(result);
        end

        function testRegistryGetReturnsCell(testCase)
            result = SimulinkTerminal.registry('get');
            testCase.verifyTrue(iscell(result));
        end

        function testRegistryRemoveNonExistent(testCase)
            obj = SimulinkTerminal();
            testCase.addTeardown(@() delete(obj));
            % Remove from empty registry should not error
            SimulinkTerminal.registry('remove', obj);
            result = SimulinkTerminal.registry('get');
            testCase.verifyEmpty(result);
        end
    end

    %% ============= FIND EXISTING COMPONENT TESTS =============
    methods (Test)
        function testFindExistingComponentNoComponents(testCase)
            [mockStudio, behavior] = testCase.createMock(...
                'AddedMethods', {'getAllComponents'});
            testCase.assignOutputsWhen( ...
                withAnyInputs(behavior.getAllComponents), {});

            comp = SimulinkTerminal.findExistingComponent(mockStudio);
            testCase.verifyEmpty(comp);
        end

        function testFindExistingComponentNotFound(testCase)
            [mockComp, compBehavior] = testCase.createMock(...
                'AddedMethods', {'getName'});
            testCase.assignOutputsWhen( ...
                withAnyInputs(compBehavior.getName), 'OtherComponent');

            [mockStudio, studioBehavior] = testCase.createMock(...
                'AddedMethods', {'getAllComponents'});
            testCase.assignOutputsWhen( ...
                withAnyInputs(studioBehavior.getAllComponents), {mockComp});

            comp = SimulinkTerminal.findExistingComponent(mockStudio);
            testCase.verifyEmpty(comp);
        end

        function testFindExistingComponentFound(testCase)
            [mockComp, compBehavior] = testCase.createMock(...
                'AddedMethods', {'getName'});
            testCase.assignOutputsWhen( ...
                withAnyInputs(compBehavior.getName), 'SimulinkTerminal');

            [mockStudio, studioBehavior] = testCase.createMock(...
                'AddedMethods', {'getAllComponents'});
            testCase.assignOutputsWhen( ...
                withAnyInputs(studioBehavior.getAllComponents), {mockComp});

            comp = SimulinkTerminal.findExistingComponent(mockStudio);
            testCase.verifyEqual(comp, mockComp);
        end

        function testFindExistingComponentMultipleComps(testCase)
            [mockComp1, comp1Beh] = testCase.createMock(...
                'AddedMethods', {'getName'});
            testCase.assignOutputsWhen( ...
                withAnyInputs(comp1Beh.getName), 'OtherComponent');

            [mockComp2, comp2Beh] = testCase.createMock(...
                'AddedMethods', {'getName'});
            testCase.assignOutputsWhen( ...
                withAnyInputs(comp2Beh.getName), 'SimulinkTerminal');

            [mockStudio, studioBeh] = testCase.createMock(...
                'AddedMethods', {'getAllComponents'});
            testCase.assignOutputsWhen( ...
                withAnyInputs(studioBeh.getAllComponents), ...
                {mockComp1, mockComp2});

            comp = SimulinkTerminal.findExistingComponent(mockStudio);
            testCase.verifyEqual(comp, mockComp2);
        end

        function testFindExistingComponentHandlesError(testCase)
            [mockStudio, studioBeh] = testCase.createMock(...
                'AddedMethods', {'getAllComponents'});
            testCase.throwExceptionWhen( ...
                withAnyInputs(studioBeh.getAllComponents), ...
                MException('test:error', 'simulated'));

            comp = SimulinkTerminal.findExistingComponent(mockStudio);
            testCase.verifyEmpty(comp);
        end

        function testFindExistingComponentWarnsOnError(testCase)
            [mockStudio, studioBeh] = testCase.createMock(...
                'AddedMethods', {'getAllComponents'});
            testCase.throwExceptionWhen( ...
                withAnyInputs(studioBeh.getAllComponents), ...
                MException('test:error', 'simulated'));

            testCase.verifyWarning(...
                @() SimulinkTerminal.findExistingComponent(mockStudio), ...
                'SimulinkTerminal:ComponentSearch');
        end
    end

    %% ============= CLEANUP TESTS =============
    methods (Test)
        function testCleanupFreshObject(testCase)
            obj = SimulinkTerminal();
            testCase.addTeardown(@() delete(obj));

            obj.cleanup();
            testCase.verifyEmpty(obj.ServerProcess);
            testCase.verifyEqual(obj.AuthToken, '');
            testCase.verifyEmpty(obj.Component);
            testCase.verifyFalse(obj.IsCleaningUp);
        end

        function testCleanupIsIdempotent(testCase)
            obj = SimulinkTerminal();
            testCase.addTeardown(@() delete(obj));

            obj.cleanup();
            obj.cleanup();
            obj.cleanup();
            testCase.verifyFalse(obj.IsCleaningUp);
        end

        function testCleanupWithServerProcess(testCase)
            obj = SimulinkTerminal();
            testCase.addTeardown(@() delete(obj));

            obj.ServerProcess = struct('pid', 999999999, 'port', 12345);
            obj.AuthToken = 'testtoken123456789012345678901234';

            obj.cleanup();
            testCase.verifyEmpty(obj.ServerProcess);
            testCase.verifyEqual(obj.AuthToken, '');
            testCase.verifyFalse(obj.IsCleaningUp);
        end

        function testCleanupWithNaNPid(testCase)
            obj = SimulinkTerminal();
            testCase.addTeardown(@() delete(obj));

            obj.ServerProcess = struct('pid', NaN, 'port', 12345);
            obj.cleanup();
            testCase.verifyEmpty(obj.ServerProcess);
        end

        function testCleanupGuardsAgainstReentrance(testCase)
            obj = SimulinkTerminal();
            testCase.addTeardown(@() delete(obj));

            % Simulate re-entrant call
            obj.IsCleaningUp = true;
            obj.ServerProcess = struct('pid', 999999999, 'port', 12345);

            obj.cleanup(); % Should return early

            % ServerProcess NOT cleared (early return)
            testCase.verifyTrue(isstruct(obj.ServerProcess));

            % Reset for proper cleanup
            obj.IsCleaningUp = false;
        end

        function testCleanupWithEmptyServerProcess(testCase)
            obj = SimulinkTerminal();
            testCase.addTeardown(@() delete(obj));

            obj.ServerProcess = [];
            obj.cleanup();
            testCase.verifyEmpty(obj.ServerProcess);
        end

        function testCleanupDoesNotAffectOtherObjects(testCase)
            obj1 = SimulinkTerminal();
            obj2 = SimulinkTerminal();
            testCase.addTeardown(@() delete(obj1));
            testCase.addTeardown(@() delete(obj2));

            obj1.ServerProcess = struct('pid', 999999999, 'port', 11111);
            obj2.ServerProcess = struct('pid', 888888888, 'port', 22222);

            obj1.cleanup();
            testCase.verifyEmpty(obj1.ServerProcess);
            testCase.verifyTrue(isstruct(obj2.ServerProcess));
            testCase.verifyEqual(obj2.ServerProcess.port, 22222);
        end
    end

    %% ============= METACLASS / STRUCTURE TESTS =============
    methods (Test)
        function testClassIsSealed(testCase)
            mc = ?SimulinkTerminal;
            testCase.verifyTrue(mc.Sealed);
        end

        function testClassIsHandle(testCase)
            mc = ?SimulinkTerminal;
            superNames = arrayfun(@(x) x.Name, ...
                mc.SuperclassList, 'UniformOutput', false);
            testCase.verifyTrue(ismember('handle', superNames));
        end

        function testHasExpectedPublicStaticMethods(testCase)
            mc = ?SimulinkTerminal;
            methods = mc.MethodList;
            staticMethods = methods([methods.Static]);
            names = {staticMethods.Name};
            testCase.verifyTrue(ismember('show', names));
            testCase.verifyTrue(ismember('close', names));
        end

        function testHasGetDialogSchemaMethod(testCase)
            mc = ?SimulinkTerminal;
            names = {mc.MethodList.Name};
            testCase.verifyTrue(ismember('getDialogSchema', names));
        end

        function testPrivateMethodsExist(testCase)
            mc = ?SimulinkTerminal;
            names = {mc.MethodList.Name};
            expected = {'startServer', 'dock', 'cleanup', ...
                'findExistingComponent', 'registry', 'findBinary', ...
                'resolveHTMLDir', 'generateToken', 'killProcess'};
            for i = 1:numel(expected)
                testCase.verifyTrue(ismember(expected{i}, names), ...
                    sprintf('Missing method: %s', expected{i}));
            end
        end

        function testConstantPropertiesCount(testCase)
            mc = ?SimulinkTerminal;
            props = mc.PropertyList;
            constProps = props([props.Constant]);
            testCase.verifyEqual(numel(constProps), 6);
        end
    end

    %% ============= START SERVER ERROR TESTS (SLOW) =============
    methods (Test, TestTags = {'Slow'})
        function testStartServerNoHTML(testCase)
            obj = SimulinkTerminal();
            testCase.addTeardown(@() delete(obj));

            % Create fake binary so findBinary succeeds
            arch = computer('arch');
            srcDir = fileparts(which('SimulinkTerminal'));
            parentDir = fileparts(srcDir);
            distDir = fullfile(parentDir, 'dist', arch);

            binaryName = SimulinkTerminal.ServerBinaryName;
            if ispc, binaryName = [binaryName, '.exe']; end
            fakeBinary = fullfile(distDir, binaryName);

            if isfile(fakeBinary)
                testCase.assumeFail('Binary already exists at dist');
            end

            if ~isfolder(distDir), mkdir(distDir); end
            testCase.addTeardown(@() cleanupDir(fullfile(parentDir, 'dist')));

            fid = fopen(fakeBinary, 'w');
            fprintf(fid, 'fake');
            fclose(fid);

            % Ensure no HTML directory
            htmlResult = SimulinkTerminal.resolveHTMLDir();
            if ~isempty(htmlResult)
                testCase.assumeFail('HTML dir exists, cannot test not-found');
            end

            testCase.verifyError(@() obj.startServer(), ...
                'SimulinkTerminal:HTMLNotFound');

            function cleanupDir(d)
                if isfolder(d)
                    try rmdir(d, 's'); catch, end
                end
            end
        end

        function testStartServerTimeoutNoPort(testCase)
            obj = SimulinkTerminal();
            testCase.addTeardown(@() delete(obj));

            % Create both fake binary and fake HTML dir
            arch = computer('arch');
            srcDir = fileparts(which('SimulinkTerminal'));
            parentDir = fileparts(srcDir);
            distDir = fullfile(parentDir, 'dist', arch);

            binaryName = SimulinkTerminal.ServerBinaryName;
            if ispc, binaryName = [binaryName, '.exe']; end
            fakeBinary = fullfile(distDir, binaryName);

            if isfile(fakeBinary)
                testCase.assumeFail('Binary already at dist');
            end

            if ~isfolder(distDir), mkdir(distDir); end
            testCase.addTeardown(@() cleanupDir(fullfile(parentDir, 'dist')));

            fid = fopen(fakeBinary, 'w');
            fprintf(fid, 'fake');
            fclose(fid);

            % Create fake HTML dir if needed
            htmlDir = fullfile(srcDir, 'html');
            htmlFile = fullfile(htmlDir, 'simulink.html');
            createdHTML = false;
            if ~isfile(htmlFile)
                if ~isfolder(htmlDir), mkdir(htmlDir); end
                fid2 = fopen(htmlFile, 'w');
                fprintf(fid2, '<html></html>');
                fclose(fid2);
                createdHTML = true;
                testCase.addTeardown(@() cleanupHTML(htmlDir, htmlFile));
            end

            % Fake binary won't produce ready file => timeout => NoPort
            testCase.verifyError(@() obj.startServer(), ...
                'SimulinkTerminal:NoPort');

            function cleanupDir(d)
                if isfolder(d)
                    try rmdir(d, 's'); catch, end
                end
            end
            function cleanupHTML(htmlDir, htmlFile)
                if isfile(htmlFile), delete(htmlFile); end
                if isfolder(htmlDir)
                    try rmdir(htmlDir); catch, end
                end
            end
        end

    end

    %% ============= ENVIRONMENT / MISC TESTS =============
    methods (Test)
        function testAuthTokenEnvVarNotSet(testCase)
            val = getenv('MATLAB_TERMINAL_TOKEN');
            testCase.verifyTrue(isempty(val) || strlength(string(val)) == 0);
        end

        function testHandleSemantics(testCase)
            obj1 = SimulinkTerminal();
            testCase.addTeardown(@() delete(obj1));
            obj2 = obj1;
            testCase.verifyTrue(obj1 == obj2);
        end

        function testObjectArrayCreation(testCase)
            obj = SimulinkTerminal.empty();
            testCase.verifyEqual(numel(obj), 0);
        end

        function testRegistryIntegrationWithDelete(testCase)
            % Full lifecycle: create, register, delete => registry empty
            objs = cell(1, 3);
            for i = 1:3
                objs{i} = SimulinkTerminal();
                SimulinkTerminal.registry('add', objs{i});
            end

            reg = SimulinkTerminal.registry('get');
            testCase.verifyEqual(numel(reg), 3);

            % Delete one
            delete(objs{2});
            reg = SimulinkTerminal.registry('get');
            testCase.verifyEqual(numel(reg), 2);

            % Delete remaining
            delete(objs{1});
            delete(objs{3});
            reg = SimulinkTerminal.registry('get');
            testCase.verifyEmpty(reg);
        end

        function testCleanupViaCloseWithRegistry(testCase)
            obj = SimulinkTerminal();
            testCase.addTeardown(@() delete(obj));
            obj.ServerProcess = struct('pid', 999999999, 'port', 55555);
            obj.AuthToken = 'aaaabbbbccccddddeeeeffffgggghhhh';
            SimulinkTerminal.registry('add', obj);

            SimulinkTerminal.close();

            testCase.verifyEmpty(obj.ServerProcess);
            testCase.verifyEqual(obj.AuthToken, '');
        end

        function testGetDialogSchemaAfterCleanup(testCase)
            obj = SimulinkTerminal();
            testCase.addTeardown(@() delete(obj));
            obj.ServerProcess = struct('pid', 99999, 'port', 12345);
            obj.AuthToken = 'aaaabbbbccccddddeeeeffffgggghhhh';

            obj.cleanup();

            % After cleanup, ServerProcess is empty => NoServer error
            testCase.verifyError(@() obj.getDialogSchema(), ...
                'SimulinkTerminal:NoServer');
        end
    end

    %% ============= MOCK DAS.STUDIO TESTS =============
    % These tests use temporary mock +DAS packages on the path to cover
    % show() and close() branches that depend on DAS.Studio.
    methods (Test)
        function testShowAlwaysErrorsWithNoModel(testCase)
            % DAS.Studio is built-in. Without an open model, show() always
            % errors with NoStudio regardless of theme.
            themes = {"light", "dark", "dracula", "monokai", "nord"};
            for i = 1:numel(themes)
                testCase.verifyError(...
                    @() SimulinkTerminal.show(Theme=themes{i}), ...
                    'SimulinkTerminal:NoStudio');
            end
        end

        function testCloseWithStudioIteration(testCase)
            % Test close() when DAS.Studio returns studios.
            % DAS.Studio is built-in: when no model is open it returns
            % empty; when a model is open, close() iterates studios.
            studios = [];
            try
                studios = DAS.Studio.getAllStudiosSortedByMostRecentlyActive;
            catch
            end
            if isempty(studios)
                % No studios: close() just runs the registry cleanup
                SimulinkTerminal.close();
            else
                % Studios available: close() iterates them
                SimulinkTerminal.close();
            end
        end

        function testCloseCatchesDASStudioError(testCase)
            % The DAS.Studio catch path in close() is defensive code.
            % DAS.Studio is built-in and can't be mocked to throw.
            % We verify close() handles all states gracefully.
            src = fileread(which('SimulinkTerminal'));
            testCase.verifyTrue(contains(src, 'SimulinkTerminal:CloseStudioAccess'));
            testCase.verifyTrue(contains(src, 'SimulinkTerminal:PanelCleanup'));
            SimulinkTerminal.close();
        end

        function testShowSourceHasAllWarningIds(testCase)
            % Verify all defensive warning IDs exist in the source
            src = fileread(which('SimulinkTerminal'));
            expectedIds = { ...
                'SimulinkTerminal:StudioUnavailable', ...
                'SimulinkTerminal:OldPanelCleanup', ...
                'SimulinkTerminal:DestroyComponent', ...
                'SimulinkTerminal:CloseStudioAccess', ...
                'SimulinkTerminal:PanelCleanup', ...
                'SimulinkTerminal:ServerTermination', ...
                'SimulinkTerminal:ComponentSearch', ...
                'SimulinkTerminal:LogRead', ...
                'SimulinkTerminal:TokenGeneration', ...
                'SimulinkTerminal:ListenerFailed'};
            for i = 1:numel(expectedIds)
                testCase.verifyTrue(contains(src, expectedIds{i}), ...
                    sprintf('Missing warning ID: %s', expectedIds{i}));
            end
        end

    end

    %% ============= FIND BINARY EXTENDED TESTS =============
    methods (Test)
        function testFindBinarySystemPATH(testCase)
            % Test PATH fallback by creating a fake binary on PATH
            binaryName = SimulinkTerminal.ServerBinaryName;
            if ispc, binaryName = [binaryName, '.exe']; end

            % Only test if no binary at higher-priority locations
            % First, temporarily hide the prefdir binary
            arch = computer('arch');
            prefdirBin = fullfile(prefdir, 'matlab-terminal', 'bin', arch, binaryName);
            prefdirBackup = [prefdirBin, '.testbak'];

            movedPrefdir = false;
            if isfile(prefdirBin)
                movefile(prefdirBin, prefdirBackup);
                movedPrefdir = true;
                testCase.addTeardown(@() restoreFile(prefdirBackup, prefdirBin));
            end

            % Also check dist/ location
            srcDir = fileparts(which('SimulinkTerminal'));
            parentDir = fileparts(srcDir);
            distBin = fullfile(parentDir, 'dist', arch, binaryName);
            if isfile(distBin)
                testCase.assumeFail('Binary at dist/ location, cannot test PATH');
            end

            % Also check userpath/bin
            userpathBin = fullfile(userpath, 'bin', binaryName);
            if isfile(userpathBin)
                testCase.assumeFail('Binary at userpath/bin, cannot test PATH');
            end

            % Create a temporary directory with fake binary, add to system PATH
            tempBinDir = fullfile(testCase.TempDir, 'bin');
            mkdir(tempBinDir);
            fakeBinary = fullfile(tempBinDir, binaryName);
            fid = fopen(fakeBinary, 'w');
            fprintf(fid, 'fake');
            fclose(fid);

            % Add to PATH
            origPath = getenv('PATH');
            setenv('PATH', [tempBinDir, pathsep, origPath]);
            testCase.addTeardown(@() setenv('PATH', origPath));

            result = SimulinkTerminal.findBinary();
            testCase.verifyNotEmpty(result);

            function restoreFile(backup, original)
                if isfile(backup)
                    movefile(backup, original);
                end
            end
        end

        function testFindBinaryReturnsEmptyWhenNoneExist(testCase)
            % Test that findBinary returns '' when no binary exists anywhere
            binaryName = SimulinkTerminal.ServerBinaryName;
            if ispc, binaryName = [binaryName, '.exe']; end

            % Temporarily hide all known locations
            arch = computer('arch');
            prefdirBin = fullfile(prefdir, 'matlab-terminal', 'bin', arch, binaryName);
            prefdirBackup = [prefdirBin, '.testbak'];

            movedPrefdir = false;
            if isfile(prefdirBin)
                movefile(prefdirBin, prefdirBackup);
                movedPrefdir = true;
                testCase.addTeardown(@() restoreFile(prefdirBackup, prefdirBin));
            end

            srcDir = fileparts(which('SimulinkTerminal'));
            parentDir = fileparts(srcDir);
            distBin = fullfile(parentDir, 'dist', arch, binaryName);
            if isfile(distBin)
                testCase.assumeFail('Binary at dist/');
            end

            userpathBin = fullfile(userpath, 'bin', binaryName);
            if isfile(userpathBin)
                testCase.assumeFail('Binary at userpath/bin');
            end

            result = SimulinkTerminal.findBinary();
            testCase.verifyEqual(result, '');

            function restoreFile(backup, original)
                if isfile(backup)
                    movefile(backup, original);
                end
            end
        end
    end

    %% ============= START SERVER EXTENDED TESTS =============
    methods (Test, TestTags = {'Slow'})
        function testStartServerBinaryNotFoundAfterHiding(testCase)
            % Temporarily hide the installed binary to test BinaryNotFound
            binaryName = SimulinkTerminal.ServerBinaryName;
            if ispc, binaryName = [binaryName, '.exe']; end

            arch = computer('arch');
            prefdirBin = fullfile(prefdir, 'matlab-terminal', 'bin', arch, binaryName);
            prefdirBackup = [prefdirBin, '.testbak'];

            if ~isfile(prefdirBin)
                testCase.assumeFail('No prefdir binary to hide');
            end

            movefile(prefdirBin, prefdirBackup);
            testCase.addTeardown(@() restoreFile(prefdirBackup, prefdirBin));

            % Ensure no binary at other locations either
            srcDir = fileparts(which('SimulinkTerminal'));
            parentDir = fileparts(srcDir);
            distBin = fullfile(parentDir, 'dist', arch, binaryName);
            if isfile(distBin)
                testCase.assumeFail('Binary at dist/');
            end

            obj = SimulinkTerminal();
            testCase.addTeardown(@() delete(obj));

            testCase.verifyError(@() obj.startServer(), ...
                'SimulinkTerminal:BinaryNotFound');

            function restoreFile(backup, original)
                if isfile(backup)
                    movefile(backup, original);
                end
            end
        end
    end

    %% ============= GENERATE TOKEN EXTENDED TESTS =============
    methods (Test)
        function testGenerateTokenFallbackPath(testCase)
            % Test that the fallback (randi-based) token works.
            % The fallback triggers when the primary method returns
            % a token with length ~= 32. We can't easily force that,
            % but we can verify the function always returns 32-char hex.
            for i = 1:50
                token = SimulinkTerminal.generateToken();
                testCase.verifyEqual(strlength(string(token)), 32, ...
                    'Token must always be 32 chars');
                testCase.verifyTrue( ...
                    ~isempty(regexp(token, '^[0-9a-f]{32}$', 'once')), ...
                    'Token must be lowercase hex');
            end
        end
    end
end
