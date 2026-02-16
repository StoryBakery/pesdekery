--[[
	pesde 설치 이후 roblox_packages 내부 래퍼의 잘못된 버전 경로를 보정하는 모듈입니다.
]]

local FileSystem = require("@lune/fs")
local Process = require("@lune/process")

local PATH_SEPARATOR = if Process.os == "windows" then "\\" else "/"

local function joinPath(basePath: string, name: string): string
	local tail = basePath:sub(-1)
	if tail == "/" or tail == "\\" then
		return basePath .. name
	end
	return basePath .. PATH_SEPARATOR .. name
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

	return nil, PATH_SEPARATOR
end

local function getSiblingPath(path: string, fileName: string): string
	local directory, separator = getDirectoryFromPath(path)
	if directory == nil or directory == "" then
		return fileName
	end
	return directory .. separator .. fileName
end

local function getFileName(path: string): string
	local unixFileName = path:match("^.+/(.+)$")
	if unixFileName ~= nil then
		return unixFileName
	end

	local windowsFileName = path:match("^.+\\(.+)$")
	if windowsFileName ~= nil then
		return windowsFileName
	end

	return path
end

local function getFirstRequirePath(content: string): string?
	local doubleQuotePath = content:match("require%(%s*\"(.-)\"%s*%)")
	if doubleQuotePath ~= nil then
		return doubleQuotePath
	end
	return content:match("require%(%s*'(.-)'%s*%)")
end

local function parseStoryBakeryRequirePath(
	requirePath: string
): (string?, string?, string?, string?, string?)
	return requirePath:match("^(.-)(storybakery%+[^/]+)/([^/]+)/([^/]+)(/src.*)$")
end

local function parseVersion(version: string)
	local major, minor, patch, preRelease = version:match("^(%d+)%.(%d+)%.(%d+)(%-.*)?$")
	if major == nil or minor == nil or patch == nil then
		return nil
	end

	return {
		Major = tonumber(major),
		Minor = tonumber(minor),
		Patch = tonumber(patch),
		PreRelease = preRelease,
	}
end

local function isVersionGreater(left: string, right: string): boolean
	local leftVersion = parseVersion(left)
	local rightVersion = parseVersion(right)

	if leftVersion ~= nil and rightVersion ~= nil then
		if leftVersion.Major ~= rightVersion.Major then
			return leftVersion.Major > rightVersion.Major
		end
		if leftVersion.Minor ~= rightVersion.Minor then
			return leftVersion.Minor > rightVersion.Minor
		end
		if leftVersion.Patch ~= rightVersion.Patch then
			return leftVersion.Patch > rightVersion.Patch
		end

		local leftHasPreRelease = leftVersion.PreRelease ~= nil
		local rightHasPreRelease = rightVersion.PreRelease ~= nil
		if leftHasPreRelease ~= rightHasPreRelease then
			return not leftHasPreRelease
		end

		local leftPreRelease = leftVersion.PreRelease or ""
		local rightPreRelease = rightVersion.PreRelease or ""
		return leftPreRelease > rightPreRelease
	end

	return left > right
end

local function readDir(path: string)
	local okReadDir, entriesOrErr = pcall(FileSystem.readDir, path)
	if not okReadDir then
		return false,
			{
				Code = "ReadDirFailed",
				Path = path,
				Detail = tostring(entriesOrErr),
			}
	end

	return true, entriesOrErr
end

local function readFile(path: string)
	local okRead, contentOrErr = pcall(FileSystem.readFile, path)
	if not okRead then
		return false,
			{
				Code = "ReadFileFailed",
				Path = path,
				Detail = tostring(contentOrErr),
			}
	end

	return true, contentOrErr
end

local function writeFile(path: string, content: string)
	local okRemove, removeErr = pcall(function()
		if FileSystem.isFile(path) then
			FileSystem.removeFile(path)
		end
	end)
	if not okRemove then
		return false,
			{
				Code = "RemoveFileFailed",
				Path = path,
				Detail = tostring(removeErr),
			}
	end

	local okWrite, writeErr = pcall(function()
		FileSystem.writeFile(path, content)
	end)
	if not okWrite then
		return false,
			{
				Code = "WriteFileFailed",
				Path = path,
				Detail = tostring(writeErr),
			}
	end

	return true, nil
end

local function findPackageName(versionPath: string): (string?, any?)
	local okReadDir, versionEntriesOrErr = readDir(versionPath)
	if not okReadDir then
		return nil, versionEntriesOrErr
	end

	local packageNames = {}
	for _, entryName in versionEntriesOrErr do
		local entryPath = joinPath(versionPath, entryName)
		if FileSystem.isDir(entryPath) then
			table.insert(packageNames, entryName)
		end
	end

	table.sort(packageNames)
	return packageNames[1], nil
end

local function collectLatestTargetsByToken(pesdePath: string): ({ [string]: any }?, any?)
	local latestTargetsByToken = {}
	local okReadDir, tokenEntriesOrErr = readDir(pesdePath)
	if not okReadDir then
		return nil, tokenEntriesOrErr
	end

	for _, token in tokenEntriesOrErr do
		local tokenPath = joinPath(pesdePath, token)
		if FileSystem.isDir(tokenPath) then
			local okReadVersions, versionEntriesOrErr = readDir(tokenPath)
			if not okReadVersions then
				return nil, versionEntriesOrErr
			end

			local latestVersion = nil
			local latestPackageName = nil
			for _, version in versionEntriesOrErr do
				local versionPath = joinPath(tokenPath, version)
				if FileSystem.isDir(versionPath) then
					local packageName, packageErr = findPackageName(versionPath)
					if packageErr ~= nil then
						return nil, packageErr
					end

					if packageName ~= nil then
						if latestVersion == nil or isVersionGreater(version, latestVersion) then
							latestVersion = version
							latestPackageName = packageName
						end
					end
				end
			end

			if latestVersion ~= nil and latestPackageName ~= nil then
				latestTargetsByToken[token] = {
					Token = token,
					Version = latestVersion,
					PackageName = latestPackageName,
				}
			end
		end
	end

	return latestTargetsByToken, nil
end

local function collectRootWrapperPaths(robloxPackagesPath: string): ({ string }?, any?)
	local wrapperPaths = {}
	local okReadDir, entriesOrErr = readDir(robloxPackagesPath)
	if not okReadDir then
		return nil, entriesOrErr
	end

	for _, entryName in entriesOrErr do
		if entryName:sub(-5) == ".luau" then
			local wrapperPath = joinPath(robloxPackagesPath, entryName)
			if FileSystem.isFile(wrapperPath) then
				table.insert(wrapperPaths, wrapperPath)
			end
		end
	end

	return wrapperPaths, nil
end

local function collectNestedWrapperPaths(pesdePath: string): ({ string }?, any?)
	local wrapperPaths = {}
	local okReadDir, tokenEntriesOrErr = readDir(pesdePath)
	if not okReadDir then
		return nil, tokenEntriesOrErr
	end

	for _, token in tokenEntriesOrErr do
		local tokenPath = joinPath(pesdePath, token)
		if FileSystem.isDir(tokenPath) then
			local okReadVersions, versionEntriesOrErr = readDir(tokenPath)
			if not okReadVersions then
				return nil, versionEntriesOrErr
			end

			for _, version in versionEntriesOrErr do
				local versionPath = joinPath(tokenPath, version)
				if FileSystem.isDir(versionPath) then
					local okReadPackages, packageEntriesOrErr = readDir(versionPath)
					if not okReadPackages then
						return nil, packageEntriesOrErr
					end

					for _, packageName in packageEntriesOrErr do
						local packagePath = joinPath(versionPath, packageName)
						if FileSystem.isDir(packagePath) then
							local nestedPackagesPath = joinPath(packagePath, "roblox_packages")
							if FileSystem.isDir(nestedPackagesPath) then
								local okReadWrappers, wrapperEntriesOrErr = readDir(nestedPackagesPath)
								if not okReadWrappers then
									return nil, wrapperEntriesOrErr
								end

								for _, wrapperName in wrapperEntriesOrErr do
									if wrapperName:sub(-5) == ".luau" then
										local wrapperPath = joinPath(nestedPackagesPath, wrapperName)
										if FileSystem.isFile(wrapperPath) then
											table.insert(wrapperPaths, wrapperPath)
										end
									end
								end
							end
						end
					end
				end
			end
		end
	end

	return wrapperPaths, nil
end

local function collectAllWrapperPaths(params): ({ string }?, any?)
	local robloxPackagesPath = params.RobloxPackagesPath
	local pesdeStorePath = params.PesdeStorePath

	local rootWrapperPaths, rootWrapperPathsErr = collectRootWrapperPaths(robloxPackagesPath)
	if rootWrapperPathsErr ~= nil then
		return nil, rootWrapperPathsErr
	end

	local nestedWrapperPaths, nestedWrapperPathsErr = collectNestedWrapperPaths(pesdeStorePath)
	if nestedWrapperPathsErr ~= nil then
		return nil, nestedWrapperPathsErr
	end

	local wrapperPaths = {}
	for _, wrapperPath in rootWrapperPaths do
		table.insert(wrapperPaths, wrapperPath)
	end
	for _, wrapperPath in nestedWrapperPaths do
		table.insert(wrapperPaths, wrapperPath)
	end

	return wrapperPaths, nil
end

local function replaceRequirePath(content: string, oldPath: string, newPath: string): (string, boolean)
	local replacedContent, replaceCount = content:gsub(
		"(require%(%s*\")(.-)(\"%s*%))",
		function(prefix: string, requirePath: string, suffix: string)
			if requirePath == oldPath then
				return prefix .. newPath .. suffix
			end
			return prefix .. requirePath .. suffix
		end,
		1
	)

	if replaceCount > 0 then
		return replacedContent, true
	end

	replacedContent, replaceCount = content:gsub(
		"(require%(%s*')(.-)('%s*%))",
		function(prefix: string, requirePath: string, suffix: string)
			if requirePath == oldPath then
				return prefix .. newPath .. suffix
			end
			return prefix .. requirePath .. suffix
		end,
		1
	)

	return replacedContent, replaceCount > 0
end

local function hasTargetDirectory(pesdePath: string, target): boolean
	local targetPath = joinPath(joinPath(joinPath(pesdePath, target.Token), target.Version), target.PackageName)
	return FileSystem.isDir(targetPath)
end

local function fixWrapperPath(params): (string, boolean)
	local content = params.Content
	local latestTargetsByToken = params.LatestTargetsByToken
	local pesdeStorePath = params.PesdeStorePath

	local oldRequirePath = getFirstRequirePath(content)
	if oldRequirePath == nil then
		return content, false
	end

	local prefix, token, version, packageName, suffix = parseStoryBakeryRequirePath(oldRequirePath)
	if prefix == nil or token == nil or version == nil or packageName == nil or suffix == nil then
		return content, false
	end

	local target = latestTargetsByToken[token]
	if target == nil or not hasTargetDirectory(pesdeStorePath, target) then
		return content, false
	end

	local newRequirePath = prefix .. target.Token .. "/" .. target.Version .. "/" .. target.PackageName .. suffix
	if newRequirePath == oldRequirePath then
		return content, false
	end

	local replacedContent, replaced = replaceRequirePath(content, oldRequirePath, newRequirePath)
	return replacedContent, replaced
end

local RobloxPackagesPathFixer = {}

function RobloxPackagesPathFixer.Fix(params)
	local pesdeTomlPath = params.Path
	local robloxPackagesPath = getSiblingPath(pesdeTomlPath, "roblox_packages")
	local pesdeStorePath = joinPath(robloxPackagesPath, ".pesde")

	if not FileSystem.isDir(robloxPackagesPath) or not FileSystem.isDir(pesdeStorePath) then
		return true,
			{
				ScannedCount = 0,
				FixedCount = 0,
				FixedFiles = {},
			}
	end

	local latestTargetsByToken, latestTargetsErr = collectLatestTargetsByToken(pesdeStorePath)
	if latestTargetsErr ~= nil then
		return false, latestTargetsErr
	end

	local wrapperPaths, wrapperPathsErr = collectAllWrapperPaths({
		RobloxPackagesPath = robloxPackagesPath,
		PesdeStorePath = pesdeStorePath,
	})
	if wrapperPathsErr ~= nil then
		return false, wrapperPathsErr
	end

	local fixedFiles = {}
	for _, wrapperPath in wrapperPaths do
		local okReadFile, contentOrErr = readFile(wrapperPath)
		if not okReadFile then
			return false, contentOrErr
		end

		local updatedContent, changed = fixWrapperPath({
			Content = contentOrErr,
			LatestTargetsByToken = latestTargetsByToken,
			PesdeStorePath = pesdeStorePath,
		})

		if changed then
			local okWrite, writeErr = writeFile(wrapperPath, updatedContent)
			if not okWrite then
				return false, writeErr
			end

			table.insert(fixedFiles, wrapperPath)
		end
	end

	return true,
		{
			ScannedCount = #wrapperPaths,
			FixedCount = #fixedFiles,
			FixedFiles = fixedFiles,
		}
end

return RobloxPackagesPathFixer
