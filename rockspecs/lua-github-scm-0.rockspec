package = "lua-github"
version = "scm-0"

source = {
	url = "https://github.com/folknor/lua-github/archive/master.zip",
	dir = "lua-github-master",
}

description = {
	summary    = "lua-curl interface to the GitHub ReST API v3.",
	homepage   = "https://github.com/folknor/lua-github",
	license    = "MIT/X11",
	maintainer = "folk@folk.wtf",
	detailed   = [[
		Simple wrapper around the GitHub ReST API v3 using lua-curl.
	]],
}

dependencies = {
	"lua >= 5.1, < 5.4",
	"lua-curl",
	"dkjson",
	"net-url",
}

build = {
	copy_directories = {"examples"},
	type = "builtin",
	modules = {
		["lcurl-github"] = "src/github.lua",
	}
}
