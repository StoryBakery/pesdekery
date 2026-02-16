--[[
	pesde를 래핑해 StoryBakery 의존성 동기화와 생성물 경로 보정을 함께 수행하는 스크립트입니다.
]]

local FileSystem = require("@lune/fs")
local Process = require("@lune/process")
local Stdio = require("@lune/stdio")

local PesdeTomlUpdater = require("@self/modules/PesdeTomlUpdater")
local RobloxPackagesPathFixer = require("@self/modules/RobloxPackagesPathFixer")

local AUTH_FILE_NAME = ".pesdekery-token"
local GITHUB_TOKEN_URL = "https://github.com/settings/personal-access-tokens/new"

local DEFAULT_PESDE_VERSION = "0.7.2"
local PESDE_PATH_ENV_NAME = "PESDEKERY_PESDE_PATH"
local PESDE_VERSION_ENV_NAME = "PESDEKERY_PESDE_VERSION"

local POST_SYNC_COMMAND_SET = {
	add = true,
	install = true,
	remove = true,
	update = true,
}

local function trim(value: string): string
	return value:match("^%s*(.-)%s*$")
end

local function copyArgs(args: { string }): { string }
	local copiedArgs = {}
	for _, arg in args do
		table.insert(copiedArgs, arg)
	end
	return copiedArgs
end

local function sliceArgs(args: { string }, fromIndex: number): { string }
	local slicedArgs = {}
	for index = fromIndex, #args do
		table.insert(slicedArgs, args[index])
	end
	return slicedArgs
end

local function printUsage()
	print("Usage:")
	print("  pesdekery")
	print("  pesdekery sync [pesde.toml path]")
	print("  pesdekery auth login [token]")
	print("  pesdekery <pesde command...>")
	print("")
	print("Sync options:")
	print("  -h, --help   Show this help.")
	print("  --auth       Save GitHub token and continue.")
	print("  --auth=<token>   Save token without prompt and continue.")
	print("  --auth-token <token>   Save token without prompt and continue.")
	print("")
	print("Behavior:")
	print("  sync updates StoryBakery revs, regenerates overrides, and fixes wrapper paths.")
	print("  add/install/remove/update also run sync after pesde command succeeds.")
	print("  use \"auth login\" to save GitHub token for later runs.")
	print("")
	print("Environment:")
	print("  GITHUB_TOKEN / GH_TOKEN   GitHub API token for higher rate limits.")
	print(`  {PESDE_VERSION_ENV_NAME}   Cached pesde version. Default is {DEFAULT_PESDE_VERSION}.`)
	print(`  {PESDE_PATH_ENV_NAME}   Override pesde executable path directly.`)
end

local function parseSyncArgs(args: { string })
	local path = nil
	local help = false
	local auth = false
	local authToken = nil
	local errors: { string } = {}

	local index = 1
	while index <= #args do
		local arg = args[index]
		if arg == "-h" or arg == "--help" then
			help = true
		elseif arg == "--auth" then
			auth = true
		elseif arg:match("^%-%-auth=") ~= nil then
			auth = true
			authToken = arg:sub(#"--auth=" + 1)
		elseif arg == "--auth-token" then
			auth = true
			local nextArg = args[index + 1]
			if nextArg == nil or nextArg:sub(1, 1) == "-" then
				table.insert(errors, `Missing value for "{arg}".`)
			else
				authToken = nextArg
				index += 1
			end
		elseif arg:sub(1, 1) == "-" then
			table.insert(errors, `Unknown option "{arg}".`)
		elseif path == nil then
			path = arg
		else
			table.insert(errors, `Unknown argument "{arg}".`)
		end
		index += 1
	end

	return {
		Path = path or "pesde.toml",
		Help = help,
		Auth = auth,
		AuthToken = authToken,
		Errors = errors,
	}
end

local function joinPath(basePath: string, name: string): string
	local separator = if Process.os == "windows" then "\\" else "/"
	local tail = basePath:sub(-1)
	if tail == "/" or tail == "\\" then
		return basePath .. name
	end
	return basePath .. separator .. name
end

local function getDirectoryFromPath(path: string): (string?, string)
	local unixDirectory = path:match("^(.*)/[^/]+$")
	if unixDirectory ~= nil then
		return unixDirectory, "/"
	end

	local windowsDirectory = path:match("^(.*)\\[^\\]+$")
	if windowsDirectory ~= nil then
		return windowsDirectory, "\\"
	end

	return nil, "/"
end

local function getPesdeTomlRootPath(path: string): string?
	local directory = getDirectoryFromPath(path)
	if directory == nil or directory == "" then
		return nil
	end
	return directory
end

local function getHomeDirectory(): string?
	local homeDirectory = Process.env.HOME or Process.env.USERPROFILE
	if homeDirectory == nil or homeDirectory == "" then
		return nil
	end
	return homeDirectory
end

local function getPesdeCacheRootPath(): string?
	if Process.os == "windows" then
		local localAppData = Process.env.LOCALAPPDATA
		if localAppData == nil or localAppData == "" then
			local homeDirectory = getHomeDirectory()
			if homeDirectory == nil then
				return nil
			end
			localAppData = joinPath(joinPath(homeDirectory, "AppData"), "Local")
		end
		return joinPath(localAppData, "pesdekery")
	end

	local xdgCacheHome = Process.env.XDG_CACHE_HOME
	if xdgCacheHome ~= nil and xdgCacheHome ~= "" then
		return joinPath(xdgCacheHome, "pesdekery")
	end

	local homeDirectory = getHomeDirectory()
	if homeDirectory == nil then
		return nil
	end

	return joinPath(joinPath(homeDirectory, ".cache"), "pesdekery")
end

local function getPesdeBinaryName(): string
	if Process.os == "windows" then
		return "pesde.exe"
	end
	return "pesde"
end

local function getPesdeVersion(): string
	local version = trim(Process.env[PESDE_VERSION_ENV_NAME] or "")
	if version ~= "" then
		return version
	end
	return DEFAULT_PESDE_VERSION
end

local function getCachedPesdePath(version: string): string?
	local cacheRootPath = getPesdeCacheRootPath()
	if cacheRootPath == nil then
		return nil
	end

	return joinPath(
		joinPath(joinPath(joinPath(cacheRootPath, "tools"), "pesde"), version),
		getPesdeBinaryName()
	)
end

local function resolvePesdeCommand(): (boolean, string, any?)
	local overridePath = trim(Process.env[PESDE_PATH_ENV_NAME] or "")
	if overridePath ~= "" then
		if FileSystem.isFile(overridePath) then
			return true, overridePath, nil
		end

		return false,
			"",
			{
				Code = "MissingOverridePesde",
				Path = overridePath,
			}
	end

	local version = getPesdeVersion()
	local cachedPath = getCachedPesdePath(version)
	if cachedPath == nil then
		return false,
			"",
			{
				Code = "MissingCacheRoot",
				Version = version,
			}
	end

	if FileSystem.isFile(cachedPath) then
		return true, cachedPath, nil
	end

	return false,
		"",
		{
			Code = "MissingCachedPesde",
			Path = cachedPath,
			Version = version,
		}
end

local function getAuthFilePath(): string?
	local homeDirectory = getHomeDirectory()
	if homeDirectory == nil then
		return nil
	end
	return joinPath(homeDirectory, AUTH_FILE_NAME)
end

local function readTokenFromAuthFile(path: string?): string?
	if path == nil then
		return nil
	end
	if not FileSystem.isFile(path) then
		return nil
	end

	local okRead, contentOrErr = pcall(FileSystem.readFile, path)
	if not okRead then
		return nil
	end

	local token = trim(contentOrErr)
	if token == "" then
		return nil
	end

	return token
end

local function writeTokenToAuthFile(path: string, token: string)
	local okWrite, err = pcall(function()
		FileSystem.writeFile(path, token .. "\n")
	end)
	if not okWrite then
		return false, tostring(err)
	end
	return true, nil
end

local function authenticate(path: string?, authToken: string?)
	local token = nil
	if authToken ~= nil then
		token = trim(authToken)
	else
		local okPrompt, inputOrErr = pcall(function()
			return Stdio.prompt("text", "GitHub token", "")
		end)
		if not okPrompt then
			return false,
				{
					Code = "PromptFailed",
					Detail = tostring(inputOrErr),
				}
		end
		token = trim(inputOrErr)
	end

	if token == "" then
		return false, { Code = "EmptyToken" }
	end

	if path == nil then
		return true, { Token = token, SavedPath = nil }
	end

	local okWrite, err = writeTokenToAuthFile(path, token)
	if not okWrite then
		return false,
			{
				Code = "AuthWriteFailed",
				Path = path,
				Detail = err,
			}
	end

	return true, { Token = token, SavedPath = path }
end

local function resolveToken(env, authFilePath: string?): string?
	return env.GITHUB_TOKEN or env.GH_TOKEN or readTokenFromAuthFile(authFilePath)
end

local function tryOpenBrowser(url: string): boolean
	local command = nil
	local commandArgs = nil

	if Process.os == "windows" then
		command = "cmd"
		commandArgs = { "/c", "start", "", url }
	elseif Process.os == "macos" then
		command = "open"
		commandArgs = { url }
	else
		command = "xdg-open"
		commandArgs = { url }
	end

	local okExec, execResultOrErr = pcall(function()
		return Process.exec(command, commandArgs, {
			stdio = "none",
		})
	end)
	if not okExec then
		return false
	end

	return execResultOrErr.ok and execResultOrErr.code == 0
end

local function runAuthCommand(args: { string }, authFilePath: string?): boolean
	if #args == 0 or args[1] ~= "auth" then
		return false
	end

	local subCommand = args[2]
	if subCommand ~= "login" then
		print(`[Error] Unknown auth command "{tostring(subCommand)}".`)
		print("Usage: pesdekery auth login [token]")
		Process.exit(1)
	end

	if #args > 3 then
		print("[Error] Too many arguments for auth login.")
		print("Usage: pesdekery auth login [token]")
		Process.exit(1)
	end

	local tokenArg = args[3]
	if tokenArg == nil then
		print("[Auth] Open the following URL and create a GitHub token:")
		print(`[Auth] {GITHUB_TOKEN_URL}`)
		if tryOpenBrowser(GITHUB_TOKEN_URL) then
			print("[Auth] Browser opened.")
		else
			print("[Info] Browser could not be opened automatically.")
		end
	end

	local okAuth, authResult = authenticate(authFilePath, tokenArg)
	if not okAuth then
		if authResult.Code == "EmptyToken" then
			print("[Error] Empty token is not allowed.")
		elseif authResult.Code == "PromptFailed" then
			print("[Error] Interactive auth is unavailable in this terminal.")
			print("[Error] Use: pesdekery auth login <token>")
		elseif authResult.Code == "AuthWriteFailed" then
			print(`[Error] Failed to save auth token to "{authResult.Path}": {authResult.Detail}`)
		else
			print("[Error] Failed to save auth token.")
		end
		Process.exit(1)
	end

	if authResult.SavedPath ~= nil then
		print(`[Auth] GitHub token saved to "{authResult.SavedPath}".`)
	else
		print("[Auth] GitHub token set for this process.")
	end

	Process.exit(0)
	return true
end

local function runPesdeCommand(command: string, args: { string }, cwd: string?): (boolean, number)
	local execOptions = {
		stdio = "inherit",
	}
	if cwd ~= nil and cwd ~= "" then
		execOptions.cwd = cwd
	end

	local okExec, execResultOrErr = pcall(function()
		return Process.exec(command, args, execOptions)
	end)
	if not okExec then
		local detail = tostring(execResultOrErr)
		detail = detail:match("^[^\n]+") or detail
		print(`[Error] Failed to run pesde: {detail}`)
		return false, 1
	end

	local execResult = execResultOrErr
	if not execResult.ok or execResult.code ~= 0 then
		local code = execResult.code
		if code == nil or code == 0 then
			code = 1
		end
		return false, code
	end

	return true, 0
end

local function runRobloxPackagesPathFix(path: string)
	local okFix, fixResultOrErr = RobloxPackagesPathFixer.Fix({
		Path = path,
	})
	if not okFix then
		if fixResultOrErr.Code == "ReadDirFailed" then
			print(
				`[Warn] Failed to scan generated roblox packages at "{fixResultOrErr.Path}": {fixResultOrErr.Detail}`
			)
		elseif fixResultOrErr.Code == "ReadFileFailed" then
			print(`[Warn] Failed to read generated wrapper "{fixResultOrErr.Path}": {fixResultOrErr.Detail}`)
		elseif fixResultOrErr.Code == "RemoveFileFailed" then
			print(
				`[Warn] Failed to rewrite generated wrapper "{fixResultOrErr.Path}": {fixResultOrErr.Detail}`
			)
		elseif fixResultOrErr.Code == "WriteFileFailed" then
			print(
				`[Warn] Failed to fix generated wrapper "{fixResultOrErr.Path}": {fixResultOrErr.Detail}`
			)
		else
			print("[Warn] Failed to apply generated roblox package path fixes.")
		end
		return
	end

	if fixResultOrErr.FixedCount > 0 then
		print(`[Fix] Updated {fixResultOrErr.FixedCount} generated wrapper path(s).`)
	end
end

local function runStoryBakerySync(
	pesdeCommand: string,
	path: string,
	token: string?,
	rootPath: string?
): (boolean, number)
	local okUpdate, result = PesdeTomlUpdater.Update({
		Path = path,
		Token = token,
	})
	if not okUpdate then
		if result.Code == "MissingFile" then
			print(`[Error] File "{path}" not found.`)
		elseif result.Code == "ReadFailed" then
			print(`[Error] Failed to read "{path}": {result.Detail}`)
		elseif result.Code == "WriteFailed" then
			print(`[Error] Failed to write "{path}": {result.Detail}`)
		else
			print("[Error] Failed to update pesde.toml.")
		end
		return false, 1
	end

	for _, updateInfo in result.Updated do
		local branchLabel = updateInfo.Branch or "default"
		print(`[Update] {updateInfo.Name} ({branchLabel}) rev updated to {updateInfo.NewRev} \z
			(was {updateInfo.OldRev}).`)
	end

	local fatalErrorCount = 0
	local warnErrorCount = 0

	for _, errorInfo in result.Errors do
		if errorInfo.Code == "RepoFetchFailed" then
			local statusLabel = errorInfo.StatusCode or 0
			if statusLabel == 403 then
				warnErrorCount += 1
				print(`[Warn] {errorInfo.Name} request failed with status 403. Skipped update. \z
					Set GITHUB_TOKEN or GH_TOKEN to avoid GitHub API limits.`)
			else
				fatalErrorCount += 1
				print(`[Error] {errorInfo.Name} request failed with status {statusLabel}.`)
			end
		elseif errorInfo.Code == "JsonDecodeFailed" then
			fatalErrorCount += 1
			print(`[Error] {errorInfo.Name} response JSON decode failed.`)
		elseif errorInfo.Code == "MissingSha" then
			fatalErrorCount += 1
			print(`[Error] {errorInfo.Name} response did not include a commit sha.`)
		elseif errorInfo.Code == "MissingDefaultBranch" then
			fatalErrorCount += 1
			print(`[Error] {errorInfo.Name} default branch not found.`)
		elseif errorInfo.Code == "RevReplaceFailed" then
			fatalErrorCount += 1
			print(`[Error] {errorInfo.Name} rev field could not be updated.`)
		else
			fatalErrorCount += 1
			print(`[Error] {errorInfo.Name} update failed.`)
		end
	end

	if #result.AddedOverrides > 0 then
		print(`[Override] Added {#result.AddedOverrides} StoryBakery override entries.`)
	end

	if result.LockfileStatus ~= nil then
		if result.LockfileStatus.Code == "MissingLockfile" then
			print(`[Info] Lockfile "{result.LockfileStatus.Path}" not found. Override generation skipped.`)
		elseif result.LockfileStatus.Code == "LockfileReadFailed" then
			print(`[Info] Failed to read lockfile "{result.LockfileStatus.Path}": {result.LockfileStatus.Detail}`)
		elseif result.LockfileStatus.Code == "LockfileDecodeFailed" then
			print(`[Info] Failed to decode lockfile "{result.LockfileStatus.Path}": {result.LockfileStatus.Detail}`)
		else
			print(`[Info] Lockfile "{result.LockfilePath}" has unsupported graph format.`)
		end
	elseif result.HasStoryAlias and #result.OverrideCandidates == 0 then
		print(`[Info] No StoryBakery override paths were found in "{result.LockfilePath}".`)
	elseif not result.HasStoryAlias then
		print("[Info] No StoryBakery-owned dependencies were found.")
	end

	if #result.Updated == 0 and fatalErrorCount == 0 and warnErrorCount == 0 then
		if result.ManagedGitHubEntries == 0 then
			print("[Info] No StoryBakery GitHub dependencies with rev were found.")
		else
			print("[Info] No StoryBakery GitHub dependencies needed a rev update.")
		end
	end

	if fatalErrorCount > 0 then
		return false, 1
	end

	if result.Changed then
		print("[Install] Running pesde install.")
		local okInstall, installCode = runPesdeCommand(pesdeCommand, { "install" }, rootPath)
		if not okInstall then
			print("[Error] pesde install failed.")
			return false, installCode
		end
	end

	runRobloxPackagesPathFix(path)
	return true, 0
end

local function runSyncCommand(
	pesdeCommand: string,
	args: { string },
	authFilePath: string?
): (boolean, number)
	local options = parseSyncArgs(args)
	if #options.Errors > 0 then
		for _, message in options.Errors do
			print(`[Error] {message}`)
		end
		printUsage()
		return false, 1
	end

	if options.Help then
		printUsage()
		return true, 0
	end

	if options.Auth then
		local okAuth, authResult = authenticate(authFilePath, options.AuthToken)
		if not okAuth then
			if authResult.Code == "EmptyToken" then
				print("[Error] Empty token is not allowed.")
			elseif authResult.Code == "PromptFailed" then
				print("[Error] Interactive auth is unavailable in this terminal.")
				print("[Error] Use --auth-token <token> or --auth=<token>.")
			elseif authResult.Code == "AuthWriteFailed" then
				print(`[Error] Failed to save auth token to "{authResult.Path}": {authResult.Detail}`)
			else
				print("[Error] Failed to save auth token.")
			end
			return false, 1
		end

		Process.env.GITHUB_TOKEN = authResult.Token
		if authResult.SavedPath ~= nil then
			print(`[Auth] GitHub token saved to "{authResult.SavedPath}".`)
		else
			print("[Auth] GitHub token set for this process.")
		end
	end

	local token = resolveToken(Process.env, authFilePath)
	local rootPath = getPesdeTomlRootPath(options.Path)
	return runStoryBakerySync(pesdeCommand, options.Path, token, rootPath)
end

local function isSyncOption(arg: string): boolean
	if arg == "-h" or arg == "--help" then
		return true
	end

	if arg == "--auth" or arg == "--auth-token" then
		return true
	end

	return arg:match("^%-%-auth=") ~= nil
end

local function shouldRunSyncMode(args: { string }): boolean
	if #args == 0 then
		return true
	end

	local firstArg = args[1]
	if firstArg == "sync" then
		return true
	end

	if firstArg:match("%.toml$") ~= nil then
		return true
	end

	return isSyncOption(firstArg)
end

local function getSyncArgsFromProcessArgs(args: { string }): { string }
	if #args > 0 and args[1] == "sync" then
		return sliceArgs(args, 2)
	end
	return copyArgs(args)
end

local function shouldRunPostSync(args: { string }): boolean
	if #args == 0 then
		return false
	end

	local normalizedCommand = string.lower(args[1])
	if POST_SYNC_COMMAND_SET[normalizedCommand] ~= true then
		return false
	end

	for _, arg in args do
		if arg == "-h" or arg == "--help" then
			return false
		end
	end

	return true
end

local authFilePath = getAuthFilePath()
runAuthCommand(Process.args, authFilePath)

local okPesdeCommand, pesdeCommand, pesdeResolveErr = resolvePesdeCommand()
if not okPesdeCommand then
	if pesdeResolveErr.Code == "MissingOverridePesde" then
		print(`[Error] {PESDE_PATH_ENV_NAME} points to a missing file: "{pesdeResolveErr.Path}".`)
	elseif pesdeResolveErr.Code == "MissingCacheRoot" then
		print(`[Error] Failed to resolve pesde cache root for version "{pesdeResolveErr.Version}".`)
	elseif pesdeResolveErr.Code == "MissingCachedPesde" then
		print(`[Error] Cached pesde was not found at "{pesdeResolveErr.Path}".`)
		print(`[Error] Install pesde "{pesdeResolveErr.Version}" into cache or set {PESDE_PATH_ENV_NAME}.`)
	else
		print("[Error] Failed to resolve pesde executable path.")
	end
	Process.exit(1)
end

if shouldRunSyncMode(Process.args) then
	local syncArgs = getSyncArgsFromProcessArgs(Process.args)
	local okSync, syncCode = runSyncCommand(pesdeCommand, syncArgs, authFilePath)
	if not okSync then
		Process.exit(syncCode)
	end
	Process.exit(0)
end

local pesdeArgs = copyArgs(Process.args)
local okPesde, pesdeCode = runPesdeCommand(pesdeCommand, pesdeArgs, nil)
if not okPesde then
	Process.exit(pesdeCode)
end

if shouldRunPostSync(pesdeArgs) then
	print("[Sync] Running StoryBakery sync after pesde command.")
	local okSync, syncCode = runSyncCommand(pesdeCommand, {}, authFilePath)
	if not okSync then
		Process.exit(syncCode)
	end
end

Process.exit(0)
