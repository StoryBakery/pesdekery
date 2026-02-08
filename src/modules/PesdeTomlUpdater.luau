--[[
	pesde.toml의 StoryBakery 의존성 버전을 갱신하고 override를 추가하는 모듈입니다.
]]

local FileSystem = require("@lune/fs")
local Serde = require("@lune/serde")

local GitHubApi = require("./GitHubApi")

local MAX_OVERRIDE_DEPTH = 12

local function trim(value: string): string
	return value:match("^%s*(.-)%s*$")
end

local function splitLines(text: string): { string }
	local normalized = text:gsub("\r\n", "\n")
	normalized = normalized:gsub("\r", "\n")
	local lines: { string } = {}
	local startIndex = 1

	while true do
		local nextIndex = normalized:find("\n", startIndex, true)
		if not nextIndex then
			table.insert(lines, normalized:sub(startIndex))
			break
		end

		table.insert(lines, normalized:sub(startIndex, nextIndex - 1))
		startIndex = nextIndex + 1
	end

	return lines
end

local function joinLines(lines: { string }, hadTrailingNewline: boolean): string
	local joined = table.concat(lines, "\n")
	if hadTrailingNewline and joined:sub(-1) ~= "\n" then
		joined ..= "\n"
	end
	return joined
end

local function stripComments(line: string): string
	local inString = false
	local escaped = false
	for i = 1, #line do
		local ch = line:sub(i, i)
		if escaped then
			escaped = false
		elseif ch == "\\" then
			escaped = true
		elseif ch == "\"" then
			inString = not inString
		elseif ch == "#" and not inString then
			return line:sub(1, i - 1)
		end
	end
	return line
end

local function stripCommentsFromText(text: string): string
	local lines = splitLines(text)
	local stripped: { string } = {}
	for _, line in lines do
		table.insert(stripped, stripComments(line))
	end
	return table.concat(stripped, "\n")
end

local function updateBraceDepth(text: string, depth: number): number
	local inString = false
	local escaped = false
	for i = 1, #text do
		local ch = text:sub(i, i)
		if escaped then
			escaped = false
		elseif ch == "\\" then
			escaped = true
		elseif ch == "\"" then
			inString = not inString
		elseif not inString then
			if ch == "{" then
				depth += 1
			elseif ch == "}" then
				depth -= 1
			end
		end
	end
	return depth
end

local function isDependencySection(sectionName: string?): boolean
	if sectionName == nil then
		return false
	end

	if sectionName == "dependencies" then
		return true
	end
	if sectionName == "dev-dependencies" then
		return true
	end
	if sectionName == "peer-dependencies" then
		return true
	end
	if sectionName:match("%.dependencies$") then
		return true
	end
	if sectionName:match("%.dev%-dependencies$") then
		return true
	end
	if sectionName:match("%.peer%-dependencies$") then
		return true
	end

	return false
end

local function extractStringValue(text: string, key: string): string?
	local pattern = key .. "%s*=%s*\"(.-)\""
	return text:match(pattern)
end

local function isCommitSha(value: string): boolean
	if #value ~= 40 then
		return false
	end
	return value:match("^[0-9a-fA-F]+$") ~= nil
end

local function replaceRev(entryText: string, newRev: string): (string, boolean)
	local pattern = "(%f[%w]rev%s*=%s*)\"(.-)\""
	local replaced, count = entryText:gsub(pattern, `%1"{newRev}"`, 1)
	if count == 0 then
		return entryText, false
	end
	return replaced, true
end

local function parseEntryAlias(lineForParse: string): string?
	local alias = lineForParse:match("^%s*([%w%-%_%.]+)%s*=%s*%{")
	if alias ~= nil then
		return alias
	end

	return lineForParse:match("^%s*\"(.-)\"%s*=%s*%{")
end

local function isStoryBakeryDependency(cleanText: string): boolean
	local name = extractStringValue(cleanText, "name")
	if name ~= nil and name:lower():match("^storybakery/") ~= nil then
		return true
	end

	local repo = extractStringValue(cleanText, "repo")
	if repo == nil then
		return false
	end

	local repoInfo = GitHubApi.ParseRepo(repo)
	if repoInfo == nil then
		return false
	end

	return repoInfo.Owner:lower() == "storybakery"
end

local function copyArray(values: { string }): { string }
	local copied = {}
	for _, value in values do
		table.insert(copied, value)
	end
	return copied
end

local function copySet(valueSet)
	local copied = {}
	for value, enabled in valueSet do
		copied[value] = enabled
	end
	return copied
end

local function getPackageIdFromTuple(value): string?
	if type(value) ~= "table" then
		return nil
	end

	local packageId = value[1]
	if type(packageId) ~= "string" then
		return nil
	end

	return packageId
end

local function getPackageIdentity(packageId: string): string?
	if packageId:match("^pesde:") ~= nil then
		local name = packageId:match("^pesde:[^:]+:([^@]+)@")
		if name ~= nil then
			return `pesde:{name}`
		end
	end

	if packageId:match("^wally:") ~= nil then
		local name = packageId:match("^wally:[^:]+:([^@]+)@")
		if name ~= nil then
			return `wally:{name}`
		end
	end

	if packageId:match("^git:") ~= nil then
		local repo = packageId:match("^git:([^:]+):")
		if repo ~= nil then
			return `git:{repo}`
		end
	end

	return nil
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

local function getSiblingPath(path: string, fileName: string): string
	local directory, separator = getDirectoryFromPath(path)
	if directory == nil or directory == "" then
		return fileName
	end
	return directory .. separator .. fileName
end

local function readLockfile(path: string)
	if not FileSystem.isFile(path) then
		return false, { Code = "MissingLockfile", Path = path }
	end

	local okRead, contentOrErr = pcall(FileSystem.readFile, path)
	if not okRead then
		return false,
			{
				Code = "LockfileReadFailed",
				Path = path,
				Detail = tostring(contentOrErr),
			}
	end

	local okDecode, decodedOrErr = pcall(function()
		return Serde.decode("toml", contentOrErr)
	end)
	if not okDecode then
		return false,
			{
				Code = "LockfileDecodeFailed",
				Path = path,
				Detail = tostring(decodedOrErr),
			}
	end

	return true, decodedOrErr
end

local function collectStoryAliases(content: string): { string: true }
	local lines = splitLines(content)
	local storyAliases = {}
	local currentSection = nil
	local activeEntry = nil

	local function registerEntry(entryName: string, entryText: string)
		local cleanText = stripCommentsFromText(entryText)
		if isStoryBakeryDependency(cleanText) then
			storyAliases[entryName] = true
		end
	end

	for _, line in lines do
		if activeEntry ~= nil then
			table.insert(activeEntry.Lines, line)
			local lineForParse = stripComments(line)
			activeEntry.Depth = updateBraceDepth(lineForParse, activeEntry.Depth)
			if activeEntry.Depth == 0 then
				registerEntry(activeEntry.Name, table.concat(activeEntry.Lines, "\n"))
				activeEntry = nil
			end
		else
			local lineForParse = stripComments(line)
			local trimmedLine = trim(lineForParse)
			local sectionName = trimmedLine:match("^%[(.+)%]$")
			if sectionName ~= nil then
				currentSection = sectionName
			elseif isDependencySection(currentSection) then
				local alias = parseEntryAlias(lineForParse)
				if alias ~= nil then
					local depth = updateBraceDepth(lineForParse, 0)
					if depth == 0 then
						registerEntry(alias, line)
					else
						activeEntry = {
							Name = alias,
							Lines = { line },
							Depth = depth,
						}
					end
				end
			end
		end
	end

	return storyAliases
end

local function buildOverrideCandidates(params)
	local lockfile = params.Lockfile
	local storyAliases = params.StoryAliases

	local graph = lockfile.graph
	if type(graph) ~= "table" then
		return {}, { Code = "InvalidLockfileGraph" }
	end

	local importers = graph.importers
	if type(importers) ~= "table" then
		return {}, { Code = "InvalidLockfileImporters" }
	end

	local nodes = graph.nodes
	if type(nodes) ~= "table" then
		return {}, { Code = "InvalidLockfileNodes" }
	end

	local storyAliasIdentities = {}
	local queue = {}
	for _, importerInfo in importers do
		if type(importerInfo) == "table" then
			local dependencies = importerInfo.dependencies
			if type(dependencies) == "table" then
				for alias, dependencyInfo in dependencies do
					if type(alias) == "string" then
						local packageId = getPackageIdFromTuple(dependencyInfo)
						if packageId ~= nil then
							if storyAliases[alias] then
								local identity = getPackageIdentity(packageId)
								if identity ~= nil then
									if storyAliasIdentities[alias] == nil then
										storyAliasIdentities[alias] = {}
									end
									storyAliasIdentities[alias][identity] = true
								end
							end

							table.insert(queue, {
								PackageId = packageId,
								Aliases = { alias },
								Depth = 1,
								VisitedPackageIds = {
									[packageId] = true,
								},
							})
						end
					end
				end
			end
		end
	end

	local overrideByPath = {}
	local queueIndex = 1
	while queueIndex <= #queue do
		local item = queue[queueIndex]
		queueIndex += 1

		if item.Depth < MAX_OVERRIDE_DEPTH then
			local nodeInfo = nodes[item.PackageId]
			if type(nodeInfo) == "table" then
				local dependencies = nodeInfo.dependencies
				if type(dependencies) == "table" then
					for alias, dependencyInfo in dependencies do
						if type(alias) == "string" then
							local nextAliases = copyArray(item.Aliases)
							table.insert(nextAliases, alias)

							local dependencyPackageId = getPackageIdFromTuple(dependencyInfo)
							if storyAliases[alias] and dependencyPackageId ~= nil then
								local identity = getPackageIdentity(dependencyPackageId)
								local expectedIdentitySet = storyAliasIdentities[alias]
								if identity ~= nil and expectedIdentitySet ~= nil and expectedIdentitySet[identity] then
									local path = table.concat(nextAliases, ">")
									if overrideByPath[path] == nil then
										overrideByPath[path] = alias
									end
								end
							end

							if dependencyPackageId ~= nil
								and not item.VisitedPackageIds[dependencyPackageId]
							then
								local visitedPackageIds = copySet(item.VisitedPackageIds)
								visitedPackageIds[dependencyPackageId] = true
								table.insert(queue, {
									PackageId = dependencyPackageId,
									Aliases = nextAliases,
									Depth = item.Depth + 1,
									VisitedPackageIds = visitedPackageIds,
								})
							end
						end
					end
				end
			end
		end
	end

	local overrideCandidates = {}
	for path, alias in overrideByPath do
		table.insert(overrideCandidates, {
			Path = path,
			Alias = alias,
		})
	end

	table.sort(overrideCandidates, function(left, right)
		return left.Path < right.Path
	end)

	return overrideCandidates, nil
end

local function addOverridesToContent(params)
	local content = params.Content
	local overrideCandidates = params.OverrideCandidates

	if #overrideCandidates == 0 then
		return content, {}
	end

	local hadTrailingNewline = content:sub(-1) == "\n"
	local lines = splitLines(content)
	local overridesStart = nil
	local overridesEnd = nil
	local currentSection = nil

	for index, line in lines do
		local trimmedLine = trim(stripComments(line))
		local sectionName = trimmedLine:match("^%[(.+)%]$")
		if sectionName ~= nil then
			if currentSection == "overrides" and overridesStart ~= nil and overridesEnd == nil then
				overridesEnd = index - 1
			end
			currentSection = sectionName
			if sectionName == "overrides" then
				overridesStart = index
				overridesEnd = nil
			end
		end
	end

	if overridesStart ~= nil and overridesEnd == nil then
		overridesEnd = #lines
	end

	local existingPaths = {}
	if overridesStart ~= nil and overridesEnd ~= nil then
		for index = overridesStart + 1, overridesEnd do
			local lineForParse = stripComments(lines[index])
			local key = lineForParse:match("^%s*\"(.-)\"%s*=")
			if key == nil then
				key = lineForParse:match("^%s*([%w%-%_%.]+)%s*=")
			end
			if key ~= nil then
				existingPaths[key] = true
			end
		end
	end

	local linesToAdd = {}
	local addedOverrides = {}
	for _, overrideCandidate in overrideCandidates do
		if not existingPaths[overrideCandidate.Path] then
			existingPaths[overrideCandidate.Path] = true
			table.insert(linesToAdd, `"{overrideCandidate.Path}" = "{overrideCandidate.Alias}"`)
			table.insert(addedOverrides, overrideCandidate)
		end
	end

	if #linesToAdd == 0 then
		return content, {}
	end

	local updatedLines = {}
	if overridesStart ~= nil and overridesEnd ~= nil then
		for index = 1, overridesEnd do
			table.insert(updatedLines, lines[index])
		end
		for _, line in linesToAdd do
			table.insert(updatedLines, line)
		end
		for index = overridesEnd + 1, #lines do
			table.insert(updatedLines, lines[index])
		end
	else
		for _, line in lines do
			table.insert(updatedLines, line)
		end
		if #updatedLines > 0 and updatedLines[#updatedLines] ~= "" then
			table.insert(updatedLines, "")
		end
		table.insert(updatedLines, "[overrides]")
		for _, line in linesToAdd do
			table.insert(updatedLines, line)
		end
	end

	return joinLines(updatedLines, hadTrailingNewline), addedOverrides
end

local function updateEntry(params)
	local entryText = params.Text
	local entryName = params.Name
	local token = params.Token

	local cleanText = stripCommentsFromText(entryText)
	local repo = extractStringValue(cleanText, "repo")
	if repo == nil then
		return entryText, nil, { Name = entryName, Reason = "MissingRepo" }, nil, false
	end

	local repoInfo = GitHubApi.ParseRepo(repo)
	if repoInfo == nil then
		return entryText, nil, { Name = entryName, Reason = "NotGitHub" }, nil, false
	end

	if repoInfo.Owner:lower() ~= "storybakery" then
		return entryText, nil, { Name = entryName, Reason = "NotStoryBakeryOwner" }, nil, false
	end

	local rev = extractStringValue(cleanText, "rev")
	if rev == nil then
		return entryText, nil, { Name = entryName, Reason = "MissingRev" }, nil, false
	end

	local branch = extractStringValue(cleanText, "branch")
	if branch == nil and not isCommitSha(rev) then
		branch = rev
	end

	local okResolve, resolveResult = GitHubApi.ResolveLatestCommit({
		Repo = repoInfo,
		Branch = branch,
		Token = token,
	})
	if not okResolve then
		return entryText,
			nil,
			nil,
			{
				Name = entryName,
				Repo = repo,
				Code = resolveResult.Code,
				StatusCode = resolveResult.StatusCode,
				Detail = resolveResult.Detail,
			},
			true
	end

	local newRev = resolveResult.Sha
	if newRev == rev then
		return entryText, nil, { Name = entryName, Reason = "UpToDate" }, nil, true
	end

	local updatedText, didReplace = replaceRev(entryText, newRev)
	if not didReplace then
		return entryText,
			nil,
			nil,
			{
				Name = entryName,
				Repo = repo,
				Code = "RevReplaceFailed",
			},
			true
	end

	return updatedText,
		{
			Name = entryName,
			Repo = repo,
			OldRev = rev,
			NewRev = newRev,
			Branch = resolveResult.Branch,
		},
		nil,
		nil,
		true
end

local function updateContent(params)
	local content = params.Content
	local token = params.Token

	local hadTrailingNewline = content:sub(-1) == "\n"
	local lines = splitLines(content)
	local updatedLines: { string } = {}
	local updates = {}
	local skipped = {}
	local errors = {}
	local managedGitHubEntries = 0
	local currentSection = nil
	local activeEntry = nil

	for _, line in lines do
		if activeEntry ~= nil then
			table.insert(activeEntry.Lines, line)
			local lineForParse = stripComments(line)
			activeEntry.Depth = updateBraceDepth(lineForParse, activeEntry.Depth)
			if activeEntry.Depth == 0 then
				local entryText = table.concat(activeEntry.Lines, "\n")
				local updatedText, updateInfo, skipInfo, errorInfo, isManagedGitHubEntry =
					updateEntry({
						Name = activeEntry.Name,
						Text = entryText,
						Token = token,
					})
				if isManagedGitHubEntry then
					managedGitHubEntries += 1
				end

				local updatedEntryLines = splitLines(updatedText)
				for _, entryLine in updatedEntryLines do
					table.insert(updatedLines, entryLine)
				end

				if updateInfo ~= nil then
					table.insert(updates, updateInfo)
				elseif skipInfo ~= nil then
					table.insert(skipped, skipInfo)
				elseif errorInfo ~= nil then
					table.insert(errors, errorInfo)
				end

				activeEntry = nil
			end
		else
			local lineForParse = stripComments(line)
			local trimmedLine = trim(lineForParse)
			local sectionName = trimmedLine:match("^%[(.+)%]$")
			if sectionName ~= nil then
				currentSection = sectionName
				table.insert(updatedLines, line)
			elseif isDependencySection(currentSection) then
				local alias = parseEntryAlias(lineForParse)
				if alias ~= nil then
					local depth = updateBraceDepth(lineForParse, 0)
					local entry = {
						Name = alias,
						Lines = { line },
						Depth = depth,
					}
					if entry.Depth == 0 then
						local updatedText, updateInfo, skipInfo, errorInfo, isManagedGitHubEntry =
							updateEntry({
								Name = entry.Name,
								Text = line,
								Token = token,
							})
						if isManagedGitHubEntry then
							managedGitHubEntries += 1
						end

						local updatedEntryLines = splitLines(updatedText)
						for _, entryLine in updatedEntryLines do
							table.insert(updatedLines, entryLine)
						end

						if updateInfo ~= nil then
							table.insert(updates, updateInfo)
						elseif skipInfo ~= nil then
							table.insert(skipped, skipInfo)
						elseif errorInfo ~= nil then
							table.insert(errors, errorInfo)
						end
					else
						activeEntry = entry
					end
				else
					table.insert(updatedLines, line)
				end
			else
				table.insert(updatedLines, line)
			end
		end
	end

	if activeEntry ~= nil then
		for _, entryLine in activeEntry.Lines do
			table.insert(updatedLines, entryLine)
		end
	end

	return joinLines(updatedLines, hadTrailingNewline),
		{
			Updated = updates,
			Skipped = skipped,
			Errors = errors,
			ManagedGitHubEntries = managedGitHubEntries,
		}
end

local function readFile(path: string)
	if not FileSystem.isFile(path) then
		return false, { Code = "MissingFile", Path = path }
	end

	local okRead, contentOrErr = pcall(FileSystem.readFile, path)
	if not okRead then
		return false,
			{
				Code = "ReadFailed",
				Path = path,
				Detail = tostring(contentOrErr),
			}
	end

	return true, contentOrErr
end

local function writeFile(path: string, content: string)
	local okWrite, err = pcall(function()
		FileSystem.writeFile(path, content)
	end)
	if not okWrite then
		return false, {
			Code = "WriteFailed",
			Path = path,
			Detail = tostring(err),
		}
	end
	return true, nil
end

local PesdeTomlUpdater = {}

function PesdeTomlUpdater.Update(params)
	local path = params.Path
	local token = params.Token

	local okRead, contentOrErr = readFile(path)
	if not okRead then
		return false, contentOrErr
	end

	local updatedContent, updateResult = updateContent({
		Content = contentOrErr,
		Token = token,
	})

	local storyAliases = collectStoryAliases(updatedContent)
	local lockfilePath = getSiblingPath(path, "pesde.lock")
	local overrideCandidates = {}
	local lockfileStatus = nil

	local hasStoryAlias = false
	for _ in storyAliases do
		hasStoryAlias = true
		break
	end

	if hasStoryAlias then
		local okLockfile, lockfileOrErr = readLockfile(lockfilePath)
		if okLockfile then
			local candidates, candidateErr = buildOverrideCandidates({
				Lockfile = lockfileOrErr,
				StoryAliases = storyAliases,
			})
			overrideCandidates = candidates
			if candidateErr ~= nil then
				lockfileStatus = {
					Code = candidateErr.Code,
					Path = lockfilePath,
				}
			end
		else
			lockfileStatus = lockfileOrErr
		end
	end

	local finalContent, addedOverrides = addOverridesToContent({
		Content = updatedContent,
		OverrideCandidates = overrideCandidates,
	})

	local changed = finalContent ~= contentOrErr
	if changed then
		local okWrite, writeErr = writeFile(path, finalContent)
		if not okWrite then
			return false, writeErr
		end
	end

	return true,
		{
			Updated = updateResult.Updated,
			Skipped = updateResult.Skipped,
			Errors = updateResult.Errors,
			Changed = changed,
			ManagedGitHubEntries = updateResult.ManagedGitHubEntries,
			OverrideCandidates = overrideCandidates,
			AddedOverrides = addedOverrides,
			LockfileStatus = lockfileStatus,
			LockfilePath = lockfilePath,
			HasStoryAlias = hasStoryAlias,
		}
end

return PesdeTomlUpdater
