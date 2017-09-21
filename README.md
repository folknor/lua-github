# lua-github
lua-curl wrapper for the GitHub ReST API v3.

## How to install

```
$ git clone https://github.com/folknor/lua-github.git
$ cd lua-github
$ luarocks --local make rockspecs/lua-github-scm-0.rockspec
```

The module is not published on luarocks.org yet.

## Description

The code isn't very nice, because I just wanted to get it working ASAP. I don't really care about performance, because I only use it from shell scripts.

I welcome patches, and I welcome invasive and destructive patches - there is no API stability, there is no coding convention, there is no "please don't make whitespace changes", there are no limits. If you want to contribute, then please do - unhinged.

Note that the API is not async (I could have used lluv-lua-curl), because I mostly use it in shell scripts, so async would just be annoying.

The only API I use myself is exposed through the `.easy` key.

```lua
local gh = require("lua-github").easy
for k, v in pairs(gh) do
	print(k .. ": " .. v.signature)
end
```

Prints:
```
getRelease: owner, repo, id
createRelease: body, owner, repo
listReleases: owner, repo
getUserRepositories: username, ?type(=all), ?sort(=full_name), ?direction(=desc)
getOrgRepositories: org, ?type(=all)
getYourRepositories: ?type(=all), ?sort(=full_name), ?direction(=desc), ?visibility(=all), ?affiliation(=owner,collaborator,organization_member)
uploadReleaseAsset: owner, repo, releaseId, qualifiedFile, ?contentType(=guess), ?label(=nil), ?uploadUrl(=nil)
```
(uploadReleaseAssets qualifiedFile is simply passed directly to io.open)

But most of the API is actually contained in `require("lua-github").GET, .POST, .DELETE, .PUT` (there are no `.PATCH` APIS implemented yet). For example `require("lua-github").GET["repos/:owner/:repo/releases/latest"](owner, repo)`.

## Help text

The library has a .describe function that produces an automated help text. I'm not sure why I made it. `print(require("lua-github").easy.uploadReleaseAsset.helpText)` will produce the following:

```
  gh = require("lua-github")
  headers, data1, ... = gh.POST["repos/:owner/:repo/releases"](owner, repo, releaseId, qualifiedFile, ?contentType(=guess), ?label(=nil), ?uploadUrl(=nil))

  HTTP
  POST /repos/:owner/:repo/releases

  PARAMETERS
  owner: (required) string, organization or user name.
  repo: (required) string, repository name.
  releaseId: (required) number, release identifier.
  qualifiedFile: (required) string.
  contentType: (optional) default is "guess", takes string, or nil to guess.
  label: (optional) default is "nil", takes string or nil.
  uploadUrl: (optional) default is "nil", takes hypermedia url. If set, skips a GET /repos/:owner/:repo/releases/:id call.

  RETURNS
  headers:   Parsed HTTP headers in table format, with two custom fields: statusCode and statusMessage.
             This only contains the headers for the last request made, if more than one.

  data1...N: Table result(s) of dkjson.decode parsing the response(s).
             There are potentially multiple returns because the "Link" headers
             "next" relation is automatically requested, until done.

  Any optional parameter you want to skip, just use nil.

  It's important to note that any function in the library may in fact simply return 304 on consecutive
  requests, along with the cached json table returned the last time the same URL was requested.
```

Only the shorthand aliases in `.easy` are described on `require`. If you want the signature or help text of a "core" method, you need to send that reference to `require("lua-github").describe(ref)` first. `.signature` and `.helpText` should be wrapped in a metatable access check and autodescribed, but I don't care about any of this right now.

## Adding a runtime alias

If you don't want to invoke REST methods like `gh.GET["repos/:owner/:repo/releases/latest"](owner, repo)`, you can add aliases to make things easier for yourself. Of course you can also just simply wrap the methods yourself, so I have no idea why I added the aliasing aspect really. But here it is anyway.

```lua
local gh = require("lua-github")
local name = gh.AddAlias("GET", "repos/:owner/:repo/releases/latest")
print(name) -- getRepoReleasesLatest
local name = gh.AddAlias("GET", "repos/:owner/:repo/releases/latest", "latest")
print(name) -- latest
```
So the third argument is optional, and if you don't pass anything, the library has an internal function that creates the name based on the given path. Regardless, the name is returned from `AddAlias`, or it returns `nil` if an alias with the name already exists.

Any method can be aliased as many times as you want.
