--[[
	pesde.toml의 GitHub 의존성 rev를 최신 커밋으로 갱신하는 스크립트입니다.
]]

local Process = require("@lune/process")

local PesdeTomlUpdater = require("@self/modules/PesdeTomlUpdater")

local function printUsage()
	print("Usage: pesde-gitrev [pesde.toml path]")
	print("")
	print("Options:")
	print("  -h, --help   Show this help.")
	print("")
	print("Behavior:")
	print("  Runs pesde install when revisions change.")
	print("")
	print("Environment:")
	print("  GITHUB_TOKEN / GH_TOKEN   GitHub API token for higher rate limits.")
end

local function parseArgs(args: { string })
	local path = nil
	local help = false
	local errors: { string } = {}

	for _, arg in args do
		if arg == "-h" or arg == "--help" then
			help = true
		elseif arg:sub(1, 1) == "-" then
			table.insert(errors, `Unknown option "{arg}".`)
		elseif path == nil then
			path = arg
		else
			table.insert(errors, `Unknown argument "{arg}".`)
		end
	end

	return {
		Path = path or "pesde.toml",
		Help = help,
		Errors = errors,
	}
end

local function resolveToken(env): string?
	return env.GITHUB_TOKEN or env.GH_TOKEN
end

local options = parseArgs(Process.args)
if #options.Errors > 0 then
	for _, message in options.Errors do
		print(`[Error] {message}`)
	end
	printUsage()
	Process.exit(1)
end

if options.Help then
	printUsage()
	Process.exit(0)
end

local token = resolveToken(Process.env)

local okUpdate, result = PesdeTomlUpdater.Update({
	Path = options.Path,
	Token = token,
})
if not okUpdate then
	if result.Code == "MissingFile" then
		print(`[Error] File "{options.Path}" not found.`)
	elseif result.Code == "ReadFailed" then
		print(`[Error] Failed to read "{options.Path}": {result.Detail}`)
	elseif result.Code == "WriteFailed" then
		print(`[Error] Failed to write "{options.Path}": {result.Detail}`)
	else
		print("[Error] Failed to update pesde.toml.")
	end
	Process.exit(1)
end

for _, updateInfo in result.Updated do
	local branchLabel = updateInfo.Branch or "default"
	print(`[Update] {updateInfo.Name} ({branchLabel}) rev updated to {updateInfo.NewRev} \z
		(was {updateInfo.OldRev}).`)
end

for _, errorInfo in result.Errors do
	if errorInfo.Code == "RepoFetchFailed" then
		local statusLabel = errorInfo.StatusCode or 0
		print(`[Error] {errorInfo.Name} request failed with status {statusLabel}.`)
	elseif errorInfo.Code == "JsonDecodeFailed" then
		print(`[Error] {errorInfo.Name} response JSON decode failed.`)
	elseif errorInfo.Code == "MissingSha" then
		print(`[Error] {errorInfo.Name} response did not include a commit sha.`)
	elseif errorInfo.Code == "MissingDefaultBranch" then
		print(`[Error] {errorInfo.Name} default branch not found.`)
	elseif errorInfo.Code == "RevReplaceFailed" then
		print(`[Error] {errorInfo.Name} rev field could not be updated.`)
	else
		print(`[Error] {errorInfo.Name} update failed.`)
	end
end

if #result.Updated == 0 and #result.Errors == 0 then
	if result.GitHubEntries == 0 then
		print("[Info] No GitHub dependencies with rev were found.")
	else
		print("[Info] No GitHub dependencies needed an update.")
	end
end

if #result.Errors > 0 then
	Process.exit(1)
end

if result.Changed then
	print("[Install] Running pesde install.")
	local installResult = Process.exec("pesde", { "install" })
	if installResult.stdout ~= "" then
		print(installResult.stdout)
	end
	if installResult.stderr ~= "" then
		print(installResult.stderr)
	end
	if not installResult.ok or installResult.code ~= 0 then
		print("[Error] pesde install failed.")
		Process.exit(1)
	end
end

Process.exit(0)
