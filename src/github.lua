-- file match pattern from paul kulchenko at
-- stackoverflow.com/questions/5243179/

local guessMime
do
	local mimes = {
		bz2  = "application/x-bzip2",
		exe  = "application/x-msdownload",
		gz   = "application/x-gzip",
		tgz  = "application/x-gzip",
		jpg  = "image/jpeg",
		jpeg = "image/jpeg",
		jpe  = "image/jpeg",
		jfif = "image/jpeg",
		json = "application/json",
		pdf  = "application/pdf",
		png  = "image/png",
		rpm  = "application/x-rpm",
		svg  = "image/svg+xml",
		svgz = "image/svg+xml",
		tar  = "application/x-tar",
		yaml = "application/x-yaml",
		zip  = "application/zip",
	}
	guessMime = function(name)
		local ext = name:match(".-[^\\/]-%.?([^%.\\/]*)$")
		if ext then ext = ext:lower()
		else return "application/zip" end
		return ext and mimes[ext] or "application/zip"
	end
end

local parseHeaders
do
	local _funcParse = {
		["Link"] = function(raw)
			local links = {}
			for group in raw:gmatch("([^%,]+)%p?%s?") do
				local url, options = group:match("%<(%S+)%>;%s?(.*)")
				for _, v in options:gmatch("(%w+)=\"(%w+)\"") do
					links[v] = url
				end
			end
			return links
		end,
	}
	local _isNumeric = {
		["X-RateLimit-Limit"] = true,
		["X-RateLimit-Remaining"] = true,
		["X-RateLimit-Reset"] = true,
		["X-Runtime-rack"] = true,
		["Content-Length"] = true,
	}
	local _stripQuotes = {
		ETag = true,
	}

	parseHeaders = function(raw)
		local code, message = raw:match("HTTP%/1%.1%s(%d+)%s(%C+)\13\n")
		local ret = {
			statusCode = tonumber(code),
			statusMessage = message,
		}
		for header in raw:gmatch("(%C+)\13\n") do
			local p, v = header:match("^(%S+):%s?(%C+)$")
			if p then
				if _isNumeric[p] then
					ret[p] = tonumber(v)
				elseif _stripQuotes[p] then
					ret[p] = v:gsub("\"", "")
				elseif _funcParse[p] then
					ret[p] = _funcParse[p](v)
				else
					ret[p] = v
				end
			end
		end
		return ret
	end
end

local _neturl = require("net.url")
local _dkjson = require("dkjson")
local _curl = require("lcurl")

local _H_ACCEPT = "Accept: application/vnd.github.v3+json"
local _H_CONTENT_TYPE = "Content-Type: %s"
local _H_CONTENT_LENGTH = "Content-Length: %d"
local _H_USER_AGENT = "User-Agent: lua-github/scm (folk@folk.wtf) (libcurl)"
local _H_IF_NONE_MATCH = "If-None-Match: %q"
local _H_CONTENT_LENGTH_ZERO = "Content-Length: 0"

local _doGet
do
	local _reqCache = {}
	local _HEADER_ETAG = "ETag"
	local _HEADER_LINK = "Link"

	_doGet = function(_, path, _, contentType)
		if type(path) ~= "string" then return nil, "Path required" end
		if type(contentType) ~= "string" then contentType = "application/json" end

		local headers = {
			_H_ACCEPT,
			_H_CONTENT_TYPE:format(contentType),
			_H_USER_AGENT,
		}

		if _reqCache[path] then
			headers[#headers+1] = _H_IF_NONE_MATCH:format(_reqCache[path])
		end

		local rawData = ""
		local rawHeaders = ""
		local easy = _curl.easy({
			url = path,
			netrc = 1,
			httpheader = headers,
			headerfunction = function(incoming)
				rawHeaders = rawHeaders .. incoming
				return true
			end,
			writefunction = function(incoming)
				rawData = rawData .. incoming
				return true
			end
		})
		easy:perform()

		local pH = parseHeaders(rawHeaders)

		if pH.statusCode > 399 then
			easy:close()
			return pH
		end

		local returnData = {}
		while (pH.statusCode >= 200 and pH.statusCode <= 209) do
			local json = _dkjson.decode(rawData)
			if pH[_HEADER_ETAG] then _reqCache[path] = json end
			table.insert(returnData, json)
			rawData = ""
			if pH[_HEADER_LINK] and pH[_HEADER_LINK].next then
				rawHeaders = ""
				path = pH[_HEADER_LINK].next
				easy:setopt(_curl.OPT_URL, path)
				easy:perform()
				pH = parseHeaders(rawHeaders)
			else
				break
			end
		end
		easy:close()

		if pH.statusCode == 304 then return pH, _reqCache[path] end
		return pH, unpack(returnData)
	end
end

local function _doDelete(_, path, _, _)
	if type(path) ~= "string" then return nil, "Path required" end
	local headers = {
		_H_ACCEPT,
		_H_USER_AGENT,
	}

	local rawHeaders = ""
	local ez = {
		url = path,
		netrc = 1,
		httpheader = headers,
		customrequest = "DELETE",
		headerfunction = function(incoming)
			rawHeaders = rawHeaders .. incoming
			return true
		end
	}
	local easy = _curl.easy(ez)
	easy:perform()
	easy:close()

	return parseHeaders(rawHeaders)
end

local function _doPostFile(_, path, file, contentType)
	if type(path) ~= "string" then return nil, "Invalid path" end
	if type(file) ~= "string" then return nil, "Invalid file path" end
	if type(contentType) ~= "string" then contentType = guessMime(file) end

	local stream = io.open(file, "rb")
	if not stream then return nil, ("Failed to open file %q."):format(file) end
	local size = stream:seek("end")
	stream:seek("set", 0)
	if type(size) ~= "number" then return nil, "Failed to get file size." end

	local headers = {
		_H_ACCEPT,
		_H_CONTENT_TYPE:format(contentType),
		_H_USER_AGENT,
		_H_CONTENT_LENGTH:format(size)
	}

	local rawHeaders = ""
	local rawData = ""
	local ez = {
		url = path,
		netrc = 1,
		post = true,
		httpheader = headers,
		headerfunction = function(incoming)
			rawHeaders = rawHeaders .. incoming
			return true
		end,
		writefunction = function(incoming)
			rawData = rawData .. incoming
			return true
		end,
		readfunction = function()
			return stream:read(4096)
		end,
	}
	local easy = _curl.easy(ez)
	easy:perform()
	easy:close()
	stream:close()

	return parseHeaders(rawHeaders), _dkjson.decode(rawData)
end

local function _doPostJson(self, path, data, _)
	if type(path) ~= "string" then return nil, "Invalid path" end
	if type(data) ~= "table" then return nil, "Invalid json data" end

	if type(self.verifyAll) == "table" then
		for k, v in pairs(data) do
			if not self.verifyAll[k] then return nil, ("key %q in json data not expected."):format(k) end
			if type(v) ~= self.verifyAll[k][2] then
				return nil, ("value type %q for key %q should be %q"):format(type(v), k, self.verifyAll[k][2])
			end
		end
		for k, v in pairs(self.verifyAll) do
			if v[1] == true and type(data[k]) ~= v[2] then
				return nil, ("field %q is required and must be of type %q"):format(k, v[2])
			end
		end
	end

	local headers = {
		_H_ACCEPT,
		_H_CONTENT_TYPE:format("application/json"),
		_H_USER_AGENT,
	}
	local rawHeaders = ""
	local rawData = ""
	local ez = {
		url = path,
		netrc = 1,
		post = true,
		httpheader = headers,
		headerfunction = function(incoming)
			rawHeaders = rawHeaders .. incoming
			return true
		end,
		writefunction = function(incoming)
			rawData = rawData .. incoming
			return true
		end,
		postfields = _dkjson.encode(data)
	}
	local easy = _curl.easy(ez)
	easy:perform()
	easy:close()

	return parseHeaders(rawHeaders), _dkjson.decode(rawData)
end

local function _doPut(_, path, _, _)
	if type(path) ~= "string" then return nil, "Invalid path" end
	local headers = {
		_H_ACCEPT,
		_H_USER_AGENT,
		_H_CONTENT_LENGTH_ZERO, -- XXX so far, no put requests use a body
	}
	local rawHeaders = ""
	local rawData = ""
	local ez = {
		url = path,
		netrc = 1,
		upload = 1, -- XXX put is deprecated? I have no idea if I should be using customrequest instead
		httpheader = headers,
		headerfunction = function(incoming)
			rawHeaders = rawHeaders .. incoming
			return true
		end,
		writefunction = function(incoming)
			rawData = rawData .. incoming
			return true
		end,
	}
	local easy = _curl.easy(ez)
	easy:perform()
	easy:close()

	return parseHeaders(rawHeaders), _dkjson.decode(rawData)
end

-- path, verifyFunc, (... optional args)
local M = {}

-------------------------------------------------------------------------------
-- REST API
--
do -- wraps the REST API section

local function add(n, fn)
	if n then M[n] = fn end
	if not M[fn.method] then M[fn.method] = {} end
	M[fn.method][fn.rawPath] = fn
	return n, fn
end

local get, put, delete, post
do
	local function invokeFunc(self, ...)
		local walker = 1
		if self.body then
			self.body = (select(walker, ...))
			walker = walker + 1
			if not self.body then return nil, "body is a required parameter." end
		end
		if self.contentType then
			self.contentType = (select(walker, ...))
			if type(self.contentType) ~= "string" then
				self.contentType = guessMime(self.body)
			end
			walker = walker + 1
			if not self.contentType then return nil, "contentType is a required parameter." end
		end
		local tokens = {}
		for _, arg in next, self.requiredArgs do
			local tok = select(walker, ...)
			tokens[#tokens+1] = tok
			walker = walker + 1
			if type(tok) ~= "string" then return nil, ("%q is a required parameter."):format(arg) end
		end
		local pms = {}
		for _, opt in next, self.optionalArgs do
			local pm, def, ver = opt.parameter, opt.default, opt.verify
			local arg = select(walker, ...)
			walker = walker + 1
			if type(arg) ~= "nil" then
				local verifyType = type(ver)
				if verifyType == "table" then
					pms[pm] = ver[arg] and arg or def
				elseif verifyType == "function" then
					pms[pm] = ver(arg, pm, def, self)
				elseif verifyType == "string" then
					pms[pm] = type(arg) == ver and arg or nil
				end
			end
		end
		if type(self.verifyAll) == "function" then
			local msg = self.verifyAll(pms, self)
			if msg then return nil, msg end
		end

		local tokenized = self.tokens:format(unpack(tokens))
		local u = _neturl.parse( self.baseUrl .. tokenized )
		for pm, val in pairs(pms) do
			u.query[pm] = val
		end
		return self.run( self, (tostring(u)), self.body, self.contentType )
	end

	local function wrap(method, prefix, path, verifyAll, ...)
		local func = {}
		func.method = prefix:upper()
		func.rawPath = path
		func.verifyAll = verifyAll
		func.baseUrl = "https://api.github.com/"
		func.tokens = path:gsub(":([^/]+)", "%%s")
		func.requiredArgs = {}
		for token in path:gmatch(":([^/]+)") do
			func.requiredArgs[#func.requiredArgs+1] = token
		end
		func.optionalArgs = {}
		for i = 1, select("#", ...), 3 do
			local var, def, verify = select(i, ...)
			func.optionalArgs[#func.optionalArgs + 1] = {
				parameter = var,
				default = def,
				verify = verify,
			}
		end
		func.run = method

		return nil, setmetatable(func, {
			__call = invokeFunc,
		})
	end

	get = function(...) return add(wrap(_doGet, "get", ...)) end
	put = function(...) return add(wrap(_doPut, "put", ...)) end
	delete = function(...) return add(wrap(_doDelete, "delete", ...)) end
	post = function(...)
		local n, fn = add(wrap(_doPostJson, "post", ...))
		fn.body = "lua table, passed to _dkjson.encode and sent as request body"
		return n, fn
	end
end

-------------------------------------------------------------------------------
-- https://developer.github.com/v3/issues/
--

do
	local parameters = {
		"filter", "assigned", {
			assigned = true,
			created = true,
			mentioned = true,
			subscribed = true,
			all = true,
		},
		"state", "open", {
			open = true,
			closed = true,
			all = true,
		},
		"labels", nil, "string",
		"sort", "created", {
			created = true,
			updated = true,
			comments = true,
		},
		"direction", "desc", {
			asc = true,
			desc = true,
		},
		"since", nil, "string"
	}
	get("issues", nil, unpack(parameters))
	get("user/issues", nil, unpack(parameters))
	get("orgs/:org/issues", nil, unpack(parameters))
end

get("repos/:owner/:repo/issues", nil,
	"milestone", nil, function(arg)
		if type(arg) == "string" then
			if arg == "*" or arg == "none" then return arg end
		elseif type(arg) == "number" then
			return arg
		end
	end,
	"state", "open", {
		open = true,
		closed = true,
		all = true,
	},
	"assignee", nil, "string",
	"creator", nil, "string",
	"mentioned", nil, "string",
	"labels", nil, "string",
	"sort", "created", {
		created = true,
		updated = true,
		comments = true,
	},
	"direction", "desc", {
		asc = true,
		desc = true,
	},
	"since", nil, "string"
)

-------------------------------------------------------------------------------
-- https://developer.github.com/v3/issues/assignees/
--

-- GET /repos/:owner/:repo/assignees
-- GET /repos/:owner/:repo/assignees/:assignee
-- POST /repos/:owner/:repo/issues/:number/assignees
-- DELETE /repos/:owner/:repo/issues/:number/assignees

-------------------------------------------------------------------------------
-- https://developer.github.com/v3/issues/comments/
--

-- GET /repos/:owner/:repo/issues/:number/comments
-- GET /repos/:owner/:repo/issues/comments
-- GET /repos/:owner/:repo/issues/comments/:id
-- POST /repos/:owner/:repo/issues/:number/comments
-- PATCH /repos/:owner/:repo/issues/comments/:id
-- DELETE /repos/:owner/:repo/issues/comments/:id

-------------------------------------------------------------------------------
-- https://developer.github.com/v3/issues/events/
--

-- GET /repos/:owner/:repo/issues/:issue_number/events
-- GET /repos/:owner/:repo/issues/events
-- GET /repos/:owner/:repo/issues/events/:id

-------------------------------------------------------------------------------
-- https://developer.github.com/v3/issues/labels/
--

get("repos/:owner/:repo/labels")
get("repos/:owner/:repo/labels/:name")
post("repos/:owner/:repo/labels", {
	name = {true, "string"},
	color = {true, "string"},
})
-- PATCH /repos/:owner/:repo/labels/:name
-- DELETE /repos/:owner/:repo/labels/:name
-- GET /repos/:owner/:repo/issues/:number/labels
-- POST /repos/:owner/:repo/issues/:number/labels
-- DELETE /repos/:owner/:repo/issues/:number/labels/:name
-- PUT /repos/:owner/:repo/issues/:number/labels
-- DELETE /repos/:owner/:repo/issues/:number/labels
-- GET /repos/:owner/:repo/milestones/:number/labels

-------------------------------------------------------------------------------
-- https://developer.github.com/v3/issues/milestones/
--

get("repos/:owner/:repo/milestones", nil,
	"state", "open", {
		open = true,
		closed = true,
		all = true,
	},
	"sort", "due_on", {
		due_on = true,
		completeness = true,
	},
	"direction", "asc", {
		asc = true,
		desc = true,
	}
)
get("repos/:owner/:repo/milestones/:number")
post("repos/:owner/:repo/milestones", {
	title = {true, "string"},
	-- XXX add support for table below
	-- should be {false, {open=true, closed=true}}
	state = {false, "string"},
	description = {false, "string"},
	due_on = {false, "string"}
})
--PATCH /repos/:owner/:repo/milestones/:number
--DELETE /repos/:owner/:repo/milestones/:number




-------------------------------------------------------------------------------
-- https://developer.github.com/v3/orgs/
--

get("user/orgs")
--GET /organizations = lulz
get("users/:username/orgs")
get("orgs/:org")
--PATCH /orgs/:org

-------------------------------------------------------------------------------
-- https://developer.github.com/v3/orgs/members/
--

get("orgs/:org/members", nil,
	"filter", "all", {
		all = true,
		["2fa_disabled"] = true,
	},
	"role", "all", {
		all = true,
		admin = true,
		member = true,
	}
)
get("orgs/:org/members/:username")
delete("orgs/:org/members/:username")
get("orgs/:org/public_members")
get("orgs/:org/public_members/:username")
put("orgs/:org/public_members/:username")
delete("orgs/:org/public_members/:username")
get("orgs/:org/memberships/:username")
put("orgs/:org/memberships/:username", nil,
	"role", "member", {
		admin = true,
		member = true,
	}
)
delete("orgs/:org/memberships/:username")
get("orgs/:org/invitations")
get("user/memberships/orgs")
get("user/memberships/orgs/:org")
--PATCH /user/memberships/orgs/:org

-------------------------------------------------------------------------------
-- https://developer.github.com/v3/orgs/outside_collaborators/
--

get("orgs/:org/outside_collaborators", nil,
	"filter", "all", {
		["2fa_disabled"] = true,
		all = true,
	}
)
delete("orgs/:org/outside_collaborators/:username")
put("orgs/:org/outside_collaborators/:username")

-------------------------------------------------------------------------------
-- https://developer.github.com/v3/orgs/teams/
--

get("orgs/:org/teams")
get("teams/:id")
-- POST /orgs/:org/teams
-- PATCH /teams/:id
delete("teams/:id")
get("teams/:id/teams")
get("teams/:id/members")
get("teams/:id/memberships/:username")
put("teams/:id/memberships/:username", nil,
	"role", "member", {
		member = true,
		maintainer = true,
	}
)
delete("teams/:id/memberships/:username")
get("teams/:id/repos")
get("teams/:id/invitations")
-- XXX should send Accept: application/vnd.github.v3.repository+json
-- need to modify to read body on 204?
get("teams/:id/repos/:owner/:repo")
put("teams/:id/repos/:org/:repo", nil,
	"permission", "pull", { -- XXX should not send any by default
		pull = true,
		push = true,
		admin = true,
	}
)
delete("teams/:id/repos/:owner/:repo")
get("user/teams")

-------------------------------------------------------------------------------
-- https://developer.github.com/v3/orgs/blocking/#list-blocked-users
--

get("orgs/:org/blocks")
get("orgs/:org/blocks/:username")
put("orgs/:org/blocks/:username")
delete("orgs/:org/blocks/:username")

-------------------------------------------------------------------------------
-- https://developer.github.com/v3/projects/
--
-- Preview: application/vnd.github.inertia-preview+json

-- do
-- 	local state = {
-- 		"state", "open", {
-- 			open = true,
-- 			closed = true,
-- 			all = true,
-- 		}
-- 	}
-- 	get("repos/:owner/:repo/projects", nil, unpack(state))
-- 	get("orgs/:org/projects", nil, unpack(state))
-- end

-- get("projects/:id")
-- do
-- 	local validProject = {
-- 		name = {true, "string"},
-- 		body = {false, "string"},
-- 	}
-- 	post("repos/:owner/:repo/projects", validProject)
-- 	post("orgs/:org/projects", validProject)
-- end
-- -- PATCH /projects/:id
-- delete("projects/:id")

-------------------------------------------------------------------------------
-- https://developer.github.com/v3/pulls/
--

--get("repos/:owner/:repo/pulls", nil, ... lots of parameters)
--get("repos/:owner/:repo/pulls/:number")
-- post("repos/:owner/:repo/pulls", {
-- 	... lots of json
-- })
--PATCH /repos/:owner/:repo/pulls/:number
--get("repos/:owner/:repo/pulls/:number/commits")
--get("repos/:owner/:repo/pulls/:number/files")
--get("repos/:owner/:repo/pulls/:number/merge")
--put("repos/:owner/:repo/pulls/:number/merge", nil, "commit_title", nil, "string", ... bla bla)

-------------------------------------------------------------------------------
-- https://developer.github.com/v3/reactions/
--
-- Preview application/vnd.github.squirrel-girl-preview

-- do
-- 	local reacts = {
-- 		["+1"] = true,
-- 		["-1"] = true,
-- 		laugh = true,
-- 		confused = true,
-- 		heart = true,
-- 		hooray = true,
-- 	}
-- 	get("repos/:owner/:repo/comments/:id/reactions", nil, "content", nil, reacts)
-- 	post("repos/:owner/:repo/comments/:id/reactions", {
-- 		content = {true, "string"} -- XXX need to validate json towards reacts table
-- 	})
-- 	get("repos/:owner/:repo/issues/:number/reactions", nil, "content", nil, reacts)
-- 	post("repos/:owner/:repo/issues/:number/reactions", {
-- 		content = {true, "string"}
-- 	})
-- 	get("repos/:owner/:repo/issues/comments/:id/reactions", nil, "content", nil, reacts)
-- 	post("repos/:owner/:repo/issues/comments/:id/reactions", {
-- 		content = {true, "string"}
-- 	})
-- 	get("repos/:owner/:repo/pulls/comments/:id/reactions", nil, "content", nil, reacts)
-- 	post("repos/:owner/:repo/pulls/comments/:id/reactions", {
-- 		content = {true, "string"}
-- 	})
-- 	delete("reactions/:id")
-- end

-------------------------------------------------------------------------------
-- https://developer.github.com/v3/repos/
--

do
	local allowedAffiliation = {
		owner = true,
		collaborator = true,
		organization_member = true,
	}
	get(
		"user/repos",
		function(params)
			if params.type and (params.visibility or params.affiliation) then
				return "You can't set both type and visibility/affiliation."
			end
		end,
		"type", "all", {
			all = true,
			owner = true,
			public = true,
			private = true,
			member = true,
		},
		"sort", "full_name", {
			created = true,
			updated = true,
			pushed = true,
			full_name = true,
		},
		"direction", "desc", {
			asc = true,
			desc = true,
		},
		"visibility", "all", {
			all = true,
			public = true,
			private = true,
		},
		-- XXX the validation function could do a better job :-P
		"affiliation", "owner,collaborator,organization_member", function(arg, _, def)
			for token in arg:gmatch("[^,]+") do if not allowedAffiliation[token] then return def end end
			if arg:gsub(",", ""):gsub("_", ""):find("%A") then return def end
			return arg
		end
	)
end

get("users/:username/repos", nil,
	"type", "all", {
		all = true,
		owner = true,
		public = true,
		private = true,
		member = true,
	},
	"sort", "full_name", {
		created = true,
		updated = true,
		pushed = true,
		full_name = true,
	},
	"direction", "desc", {
		asc = true,
		desc = true,
	}
)

get("orgs/:org/repos", nil,
	"type", "all", {
		all = true,
		public = true,
		private = true,
		forks = true,
		sources = true,
		member = true,
	}
)

-- GET /repositories lulz
do
	local create = {
		name = {true, "string"},
		description = {false, "string"},
		homepage = {false, "string"},
		private = {false, "boolean"},
		has_issues = {false, "boolean"},
		has_projects = {false, "boolean"},
		has_wiki = {false, "boolean"},
		team_id = {false, "number"},
		auto_init = {false, "boolean"},
		gitignore_template = {false, "string"},
		license_template = {false, "string"},
		allow_squash_merge = {false, "boolean"},
		allow_merge_commit = {false, "boolean"},
		allow_rebase_merge = {false, "boolean"},
	}
	post("user/repos", create)
	post("orgs/:org/repos", create)
end

get("repos/:owner/:repo")
-- PATCH /repos/:owner/:repo
-- GET /repos/:owner/:repo/topics preview application/vnd.github.mercy-preview+json
-- PUT /repos/:owner/:repo/topics
get("repos/:owner/:repo/contributors", nil, "anon", nil, "boolean")
get("repos/:owner/:repo/languages")
-- get("repos/:owner/:repo/teams") application/vnd.github.hellcat-preview+json
get("repos/:owner/:repo/tags")
delete("repos/:owner/:repo")

-------------------------------------------------------------------------------
-- https://developer.github.com/v3/repos/branches/
--
-- srsly wtf dis api

get("repos/:owner/:repo/branches", nil, "protected", false, "boolean")
get("repos/:owner/:repo/branches/:branch")
--get("repos/:owner/:repo/branches/:branch/protection")
--put("repos/:owner/:repo/branches/:branch/protection") -- cant be arsed to validate that input, jeez
--delete("repos/:owner/:repo/branches/:branch/protection")
--get("repos/:owner/:repo/branches/:branch/protection/required_status_checks")
-- PATCH /repos/:owner/:repo/branches/:branch/protection/required_status_checks
--delete("repos/:owner/:repo/branches/:branch/protection/required_status_checks")
--get("repos/:owner/:repo/branches/:branch/protection/required_status_checks/contexts")
--put("repos/:owner/:repo/branches/:branch/protection/required_status_checks/contexts") -- wut?
-- POST repos/:owner/:repo/branches/:branch/protection/required_status_checks/contexts -- wutz?
-- DELETE /repos/:owner/:repo/branches/:branch/protection/required_status_checks/contexts
-- GET repos/:owner/:repo/branches/:branch/protection/required_pull_request_reviews
-- PATCH /repos/:owner/:repo/branches/:branch/protection/required_pull_request_reviews
-- DELETE /repos/:owner/:repo/branches/:branch/protection/required_pull_request_reviews
-- GET /repos/:owner/:repo/branches/:branch/protection/enforce_admins
-- POST /repos/:owner/:repo/branches/:branch/protection/enforce_admins
-- DELETE /repos/:owner/:repo/branches/:branch/protection/enforce_admins
-- GET /repos/:owner/:repo/branches/:branch/protection/restrictions
-- DELETE /repos/:owner/:repo/branches/:branch/protection/restrictions
-- GET /repos/:owner/:repo/branches/:branch/protection/restrictions/teams
-- PUT /repos/:owner/:repo/branches/:branch/protection/restrictions/teams
-- POST /repos/:owner/:repo/branches/:branch/protection/restrictions/teams
-- DELETE /repos/:owner/:repo/branches/:branch/protection/restrictions/teams
-- GET /repos/:owner/:repo/branches/:branch/protection/restrictions/users
-- PUT /repos/:owner/:repo/branches/:branch/protection/restrictions/users
-- POST /repos/:owner/:repo/branches/:branch/protection/restrictions/users
-- DELETE /repos/:owner/:repo/branches/:branch/protection/restrictions/users

-------------------------------------------------------------------------------
-- https://developer.github.com/v3/repos/collaborators/
--

get("repos/:owner/:repo/collaborators", nil,
	"affiliation", "all", {
		outside = true,
		direct = true,
		all = true,
	}
)
get("repos/:owner/:repo/collaborators/:username")
get("repos/:owner/:repo/collaborators/:username/permission")
put("repos/:owner/:repo/collaborators/:username", nil,
	"permission", "push", {
		pull = true,
		push = true,
		admin = true,
	}
)
delete("repos/:owner/:repo/collaborators/:username")

-------------------------------------------------------------------------------
-- https://developer.github.com/v3/repos/comments/
--

--get("repos/:owner/:repo/comments")
--get("repos/:owner/:repo/commits/:ref/comments")
--post("repos/:owner/:repo/commits/:sha/comments", {})
--get("repos/:owner/:repo/comments/:id")
--PATCH /repos/:owner/:repo/comments/:id
--DELETE /repos/:owner/:repo/comments/:id

-------------------------------------------------------------------------------
-- https://developer.github.com/v3/repos/community/
--
-- preview application/vnd.github.black-panther-preview+json

-- get("https://developer.github.com/v3/repos/community/")
-- ...

-------------------------------------------------------------------------------
-- https://developer.github.com/v3/repos/commits/
--

-- get("repos/:owner/:repo/commits") -- sha,path,bla bla
get("repos/:owner/:repo/commits/:sha")
-- GET /repos/:owner/:repo/commits/:ref
-- GET /repos/:owner/:repo/compare/:base...:head
-- preview GET /repos/:owner/:repo/commits/:sha application/vnd.github.cryptographer-preview

-------------------------------------------------------------------------------
-- https://developer.github.com/v3/repos/contents/
--

get("repos/:owner/:repo/readme", nil, "ref", "master", "string")
get("repos/:owner/:repo/contents/:path", nil, "path", nil, "string", "ref", "master", "string")
-- put("repos/:owner/:repo/contents/:path", json garble garble lots of stuff to code)
-- PUT /repos/:owner/:repo/contents/:path
--delete("repos/:owner/:repo/contents/:path", lots and lots of parameters)
-- GET /repos/:owner/:repo/:archive_format/:ref

-------------------------------------------------------------------------------
-- https://developer.github.com/v3/repos/keys/
--

--GET /repos/:owner/:repo/keys
--GET /repos/:owner/:repo/keys/:id
--POST /repos/:owner/:repo/keys
--DELETE /repos/:owner/:repo/keys/:id

-------------------------------------------------------------------------------
-- https://developer.github.com/v3/repos/deployments/
--

-- GET /repos/:owner/:repo/deployments
-- GET /repos/:owner/:repo/deployments/:deployment_id
-- POST /repos/:owner/:repo/deployments
-- GET /repos/:owner/:repo/deployments/:id/statuses
-- GET /repos/:owner/:repo/deployments/:id/statuses/:status_id
-- POST /repos/:owner/:repo/deployments/:id/statuses

-------------------------------------------------------------------------------
-- https://developer.github.com/v3/repos/forks/
--

get("repos/:owner/:repo/forks", nil, "sort", "newest", {
	newest = true,
	oldest = true,
	stargazers = true,
})
-- POST /repos/:owner/:repo/forks this doesn't seem to take JSON, but simply a query parameter?

-------------------------------------------------------------------------------
-- https://developer.github.com/v3/repos/invitations/
--

-- GET /repos/:owner/:repo/invitations
-- DELETE /repos/:owner/:repo/invitations/:invitation_id
-- PATCH /repos/:owner/:repo/invitations/:invitation_id
-- GET /user/repository_invitations
-- PATCH /user/repository_invitations/:invitation_id
-- DELETE /user/repository_invitations/:invitation_id

-------------------------------------------------------------------------------
-- https://developer.github.com/v3/repos/merging/
--

--POST /repos/:owner/:repo/merges

-------------------------------------------------------------------------------
-- https://developer.github.com/v3/repos/pages/
--

-- GET /repos/:owner/:repo/pages
-- POST /repos/:owner/:repo/pages/builds
-- GET /repos/:owner/:repo/pages/builds
-- GET /repos/:owner/:repo/pages/builds/latest
-- GET /repos/:owner/:repo/pages/builds/:id

-------------------------------------------------------------------------------
-- https://developer.github.com/v3/repos/releases/
--

get("repos/:owner/:repo/releases")
do
	local _, releaseGet = get("repos/:owner/:repo/releases/:id")

	add("uploadReleaseAsset", setmetatable({
		rawPath = "repos/:owner/:repo/releases",
		method = "POST",
		requiredArgs = { "owner", "repo", "releaseId", "qualifiedFile" },
		optionalArgs = {
			{
				parameter = "contentType",
				default = "guess",
				verify = "string, or nil to guess."
			},
			{
				parameter = "label",
				default = "nil",
				verify = "string or nil."
			},
			{
				parameter = "uploadUrl",
				default = "nil",
				verify = "hypermedia url. If set, skips a GET /repos/:owner/:repo/releases/:id call."
			}
		}
	}, {
		__call = function(_, owner, repo, releaseId, qualifiedFile, contentType, label, uploadUrl)
			if not uploadUrl then
				local h, data = releaseGet(owner, repo, releaseId)
				if h.statusCode ~= 200 then return h, data end
				uploadUrl = data.upload_url
			end
			local u = _neturl.parse(uploadUrl:gsub("{.*}", ""))

			u.query.name = qualifiedFile:match(".-([^\\/]-%.?[^%.\\/]*)$")
			u.query.label = label
			return _doPostFile( nil, (tostring(u)), qualifiedFile, contentType)
		end
	}))
end
get("repos/:owner/:repo/releases/latest")
get("repos/:owner/:repo/releases/tags/:tag")
post("repos/:owner/:repo/releases", {
	tag_name = {true, "string"},
	target_commitish = {false, "string"},
	name = {false, "string"},
	body = {false, "string"},
	draft = {false, "boolean"},
	prerelease = {false, "boolean"},
})
-- PATCH /repos/:owner/:repo/releases/:id
delete("repos/:owner/:repo/releases/:id")
get("repos/:owner/:repo/releases/:id/assets")
--postReposReleasesAssets above

-- XXX set accept header to application/octet-stream to actually get content
get("repos/:owner/:repo/releases/assets/:id")
--PATCH /repos/:owner/:repo/releases/assets/:id
--DELETE /repos/:owner/:repo/releases/assets/:id

-------------------------------------------------------------------------------
-- https://developer.github.com/v3/repos/statistics/
--

-- GET /repos/:owner/:repo/stats/contributors
-- GET /repos/:owner/:repo/stats/commit_activity
-- GET /repos/:owner/:repo/stats/code_frequency
-- GET /repos/:owner/:repo/stats/participation
-- GET /repos/:owner/:repo/stats/punch_card

-------------------------------------------------------------------------------
-- https://developer.github.com/v3/repos/statuses/
--

-- POST /repos/:owner/:repo/statuses/:sha
-- GET /repos/:owner/:repo/commits/:ref/statuses
-- GET /repos/:owner/:repo/commits/:ref/status

-------------------------------------------------------------------------------
-- https://developer.github.com/v3/repos/traffic/
--

-- GET /repos/:owner/:repo/traffic/popular/referrers
-- GET /repos/:owner/:repo/traffic/popular/paths
-- GET  /repos/:owner/:repo/traffic/views
-- GET  /repos/:owner/:repo/traffic/clones

-------------------------------------------------------------------------------
-- https://developer.github.com/v3/repos/hooks/
--

-- GET /repos/:owner/:repo/hooks
-- GET /repos/:owner/:repo/hooks/:id
-- POST /repos/:owner/:repo/hooks
-- PATCH /repos/:owner/:repo/hooks/:id
-- POST /repos/:owner/:repo/hooks/:id/tests

end -- wraps the REST API section

do
	local fnDoc = [[
  gh = require("lua-github")
  headers, data1, ... = gh.%s["%s"](%s)

  HTTP
  %s /%s

  PARAMETERS
%s

  RETURNS
  headers:   Parsed HTTP headers in table format, with two custom fields: statusCode and statusMessage.
             This only contains the headers for the last request made, if more than one.

  data1...N: Table result(s) of dkjson.decode parsing the response(s).
             There are potentially multiple returns because the "Link" headers
             "next" relation is automatically requested, until done.

  Any optional parameter you want to skip, just use nil.

  It's important to note that any function in the library may in fact simply return 304 on consecutive
  requests, along with the cached json table returned the last time the same URL was requested.
]]
	local commonArgs = {
		owner = "string, organization or user name.",
		org = "string, organization name.",
		repo = "string, repository name.",
		id = "number, object identifier.",
		username = "string, user name.",
		releaseId = "number, release identifier."
	}
	-- XXX should move this to be lazyloaded through the fn.helpText/signature properties
	function M.describe(fn)
		if not fn then return ("No function of name %q."):format(fn.rawPath) end
		if fn.helpText then return fn.helpText end

		local opts = {}
		local optDescs = {}
		if fn.body then
			opts[#opts+1] = "body"
			if type(fn.verifyAll) == "table" then
				optDescs[#optDescs+1] = "  body: (required) " .. fn.body .. ", keys:"
				for k, d in pairs(fn.verifyAll) do
					if d[1] == true then
						optDescs[#optDescs+1] = "    " .. k .. " (required) " .. d[2]
					else
						optDescs[#optDescs+1] = "    " .. k .. " (optional) " .. d[2]
					end
				end
			else
				optDescs[#optDescs+1] = "  body: (required) " .. fn.body
			end
		end
		if fn.contentType then
			opts[#opts+1] = "contentType"
			optDescs[#optDescs+1] = "  contentType: (optional) mime type string or nil to autodetect."
		end
		if fn.requiredArgs then
			local reqDescFmt = "  %s: (required) %s"
			for _, arg in next, fn.requiredArgs do
				opts[#opts+1] = arg
				optDescs[#optDescs+1] = reqDescFmt:format(arg, commonArgs[arg] or "string.")
			end
		end
		if fn.optionalArgs then
			local optFmt = "?%s(=%s)"
			local optDescFmt = "  %s: (optional) default is %q, takes %s"
			for _, opt in next, fn.optionalArgs do
				opts[#opts+1] = optFmt:format(opt.parameter, tostring(opt.default))
				local desc
				local vt = type(opt.verify)
				if vt == "table" then
					desc = "one of: "
					for k in pairs(opt.verify) do desc = desc .. k .. " " end
				elseif vt == "function" then
					desc = "custom type, please check the github docs for valid input"
				elseif vt == "string" then
					desc = opt.verify
				end
				optDescs[#optDescs+1] = optDescFmt:format(opt.parameter, tostring(opt.default), desc)
			end
		end

		fn.signature = table.concat(opts, ", ")
		fn.helpText = fnDoc:format(
			fn.method,
			fn.rawPath,
			table.concat(opts, ", "),
			fn.method, fn.rawPath,
			table.concat(optDescs, "\n")
		)
		return fn.helpText
	end
end

do
	local function constructName(prefix, path)
		local primary = {}
		local secondary = {}
		for token in path:gmatch("[^/]+") do
			token = token:gsub("_(%a)", string.upper)
			if token:sub(1, 1) == ":" then
				local tk = token:gsub(":", ""):gsub("^(%l)", string.upper)
				table.insert(secondary, tk)
			else
				local tk = token:gsub("^(%l)", string.upper)
				table.insert(primary, tk)
			end
		end
		-- depluralize the first primary token, if there's more than one
		if #primary ~= 1 and primary[1]:sub(#primary[1]) == "s" then
			primary[1] = primary[1]:sub(1, #primary[1] - 1)
		end
		local name = prefix .. table.concat(primary)
		while M[name] and #secondary ~= 0 do
			name = name .. table.remove(secondary)
		end
		local start = 2
		while M[name] do
			name = name .. start
			start = start + 1
		end
		return name
	end

	local easy = { uploadReleaseAsset = M.uploadReleaseAsset }
	M.describe(M.uploadReleaseAsset)

	local function addAlias(method, path, alias)
		if not M[method] then return end
		if not M[method][path] then return end
		local fn = M[method][path]
		if not alias then alias = constructName(fn.method:lower(), fn.rawPath) end
		M.describe(fn)
		if easy[alias] then return end
		easy[alias] = fn
		return alias
	end
	M.AddAlias = addAlias

	addAlias("GET",    "orgs/:org/repos",                    "getOrgRepositories")
	addAlias("GET",    "user/repos",                         "getYourRepositories")
	addAlias("GET",    "users/:username/repos",              "getUserRepositories")
	addAlias("GET",    "repos/:owner/:repo/releases",        "listReleases")
	addAlias("GET",    "repos/:owner/:repo/releases/:id",    "getRelease")
	addAlias("POST",   "repos/:owner/:repo/releases",        "createRelease")
	addAlias("GET",    "repos/:owner/:repo/releases/latest", "latestRelease")

	M.easy = easy
end

return M
