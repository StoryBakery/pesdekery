--[[
	깃허브 저장소의 기본 브랜치와 최신 커밋을 조회하는 모듈입니다.
]]

local Net = require("@lune/net")
local Serde = require("@lune/serde")

local DEFAULT_HEADERS = {
	Accept = "application/vnd.github+json",
	["User-Agent"] = "pesdekery",
	["X-GitHub-Api-Version"] = "2022-11-28",
}

local defaultBranchByRepo: { [string]: string } = {}
local latestCommitByRepoAndBranch: { [string]: string } = {}

local function copyHeaders()
	local headers = {}
	for key, value in DEFAULT_HEADERS do
		headers[key] = value
	end
	return headers
end

local function buildHeaders(token: string?): { [string]: string }
	local headers = copyHeaders()
	if token ~= nil and token ~= "" then
		headers.Authorization = `Bearer {token}`
	end
	return headers
end

local function requestJson(url: string, token: string?)
	local response = Net.http.request({
		url = url,
		method = "GET",
		headers = buildHeaders(token),
	})

	local statusCode = response.statusCode
	if statusCode < 200 or statusCode >= 300 then
		return false, {
			Code = "RepoFetchFailed",
			StatusCode = statusCode,
			Body = response.body,
		}
	end

	local okDecode, dataOrErr = pcall(function()
		return Serde.decode("json", response.body)
	end)
	if not okDecode then
		return false, {
			Code = "JsonDecodeFailed",
			Detail = tostring(dataOrErr),
		}
	end

	return true, dataOrErr
end

local function normalizeRepoName(name: string): string
	local normalized = name:gsub("%.git$", "")
	normalized = normalized:gsub("/+$", "")
	return normalized
end

local function parseGitHubRepo(repo: string)
	local owner, name = repo:match("^github/([^/]+)/([^/]+)$")
	if owner ~= nil and name ~= nil then
		return {
			Owner = owner,
			Name = normalizeRepoName(name),
		}
	end

	owner, name = repo:match("^github%.com/([^/]+)/([^/]+)$")
	if owner ~= nil and name ~= nil then
		return {
			Owner = owner,
			Name = normalizeRepoName(name),
		}
	end

	owner, name = repo:match("^https?://github%.com/([^/]+)/([^/]+)$")
	if owner ~= nil and name ~= nil then
		return {
			Owner = owner,
			Name = normalizeRepoName(name),
		}
	end

	owner, name = repo:match("^git@github%.com:([^/]+)/([^/]+)$")
	if owner ~= nil and name ~= nil then
		return {
			Owner = owner,
			Name = normalizeRepoName(name),
		}
	end

	owner, name = repo:match("^ssh://git@github%.com/([^/]+)/([^/]+)$")
	if owner ~= nil and name ~= nil then
		return {
			Owner = owner,
			Name = normalizeRepoName(name),
		}
	end

	return nil
end

local function getRepoKey(repo)
	return `{repo.Owner}/{repo.Name}`
end

local function getDefaultBranch(repo, token: string?)
	local repoKey = getRepoKey(repo)
	local cached = defaultBranchByRepo[repoKey]
	if cached ~= nil then
		return true, cached
	end

	local url = `https://api.github.com/repos/{repo.Owner}/{repo.Name}`
	local ok, dataOrErr = requestJson(url, token)
	if not ok then
		return false, dataOrErr
	end

	local branch = dataOrErr.default_branch
	if branch == nil or branch == "" then
		return false, { Code = "MissingDefaultBranch" }
	end

	defaultBranchByRepo[repoKey] = branch
	return true, branch
end

local function getLatestCommit(repo, branch: string, token: string?)
	local repoKey = `{repo.Owner}/{repo.Name}@{branch}`
	local cached = latestCommitByRepoAndBranch[repoKey]
	if cached ~= nil then
		return true, cached
	end

	local encodedBranch = Net.urlEncode(branch)
	local url =
		`https://api.github.com/repos/{repo.Owner}/{repo.Name}/commits/{encodedBranch}`
	local ok, dataOrErr = requestJson(url, token)
	if not ok then
		return false, dataOrErr
	end

	local sha = dataOrErr.sha
	if sha == nil or sha == "" then
		return false, { Code = "MissingSha" }
	end

	latestCommitByRepoAndBranch[repoKey] = sha
	return true, sha
end

local GitHubApi = {
	ParseRepo = parseGitHubRepo,
}

function GitHubApi.ResolveLatestCommit(params)
	local repo = params.Repo
	local branch = params.Branch
	local token = params.Token

	if branch == nil or branch == "" then
		local okBranch, branchOrErr = getDefaultBranch(repo, token)
		if not okBranch then
			return false, branchOrErr
		end
		branch = branchOrErr
	end

	local okCommit, shaOrErr = getLatestCommit(repo, branch, token)
	if not okCommit then
		return false, shaOrErr
	end

	return true, {
		Sha = shaOrErr,
		Branch = branch,
	}
end

return GitHubApi
