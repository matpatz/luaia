-- sorry for the ai slop

-- Bundles luaia's source + CLI into a single file so that `lune build` can
-- compile it into a standalone binary. `lune build` only compiles the single
-- input file (it does not inline requires), so this script merges every
-- reachable module into one self-contained file first.
--
-- Usage (from the repo root):
--   lune run scripts/bundle.luau [entry] [output]
--   entry  defaults to bin/cli.lua
--   output defaults to build/bundled.luau
--
-- Requires starting with `@lune/` are kept as-is so the Lune runtime resolves
-- them when the binary runs.

local fs = require("@lune/fs")
local process = require("@lune/process")

local EntryPath = process.args[1] or "bin/cli.lua"
local OutputPath = process.args[2] or "build/bundled.luau"

local ProjectRoot = process.cwd:gsub("\\", "/")
if ProjectRoot:sub(-1) == "/" then
	ProjectRoot = ProjectRoot:sub(1, -2)
end

local function split(p: string): { string }
	local parts: { string } = {}
	for part in p:gmatch("[^/]+") do
		parts[#parts + 1] = part
	end
	return parts
end

-- Collapses ".", ".." and duplicate slashes, forward-slash only.
local function normalize(p: string): string
	local out: { string } = {}
	for _, part in split(p:gsub("\\", "/")) do
		if part == "." or part == "" then
			-- skip
		elseif part == ".." then
			if #out > 0 and out[#out] ~= ".." then
				table.remove(out)
			else
				out[#out + 1] = part
			end
		else
			out[#out + 1] = part
		end
	end
	return table.concat(out, "/")
end

local function dirname(p: string): string
	local idx = p:find("/[^/]*$")
	if idx then
		return p:sub(1, idx - 1)
	end
	return "."
end

local function stripExt(p: string): string
	if p:sub(-5) == ".luau" then
		return p:sub(1, -6)
	end
	if p:sub(-4) == ".lua" then
		return p:sub(1, -5)
	end
	return p
end

-- Read every lua/luau file in the project into memory (keyed by normalized
-- path). Done up front because Lune's fs calls are async and cannot yield
-- inside gsub callbacks.
local contents: { [string]: string } = {}

local function collectFiles(dir: string)
	for _, name in fs.readDir(dir) do
		local p = normalize(dir .. "/" .. name)
		if fs.isDir(p) then
			collectFiles(p)
		elseif name:sub(-5) == ".luau" or name:sub(-4) == ".lua" then
			contents[p] = fs.readFile(p)
		end
	end
end

collectFiles(ProjectRoot)

-- Resolves a require literal to an absolute-ish file path (including the
-- project root prefix). Returns nil for external (`@lune/*`) or unresolvable.
local function resolveModule(fromFile: string, lit: string): string?
	local base: string
	if lit:sub(1, 6) == "@lune/" then
		return nil
	elseif lit:sub(1, 6) == "@self/" then
		base = dirname(fromFile)
		lit = lit:sub(7)
	else
		base = dirname(fromFile)
	end

	local candidate = normalize(base .. "/" .. lit)

	for _, ext in { ".luau", ".lua" } do
		if contents[candidate .. ext] ~= nil then
			return candidate .. ext
		end
	end
	for _, ext in { ".luau", ".lua" } do
		if contents[candidate .. "/init" .. ext] ~= nil then
			return candidate .. "/init" .. ext
		end
	end
	return nil
end

local function toKey(absPath: string): string
	local rel = normalize(absPath)
	local prefix = normalize(ProjectRoot) .. "/"
	if rel:sub(1, #prefix) == prefix then
		rel = rel:sub(#prefix + 1)
	end
	return stripExt(rel)
end

-- Collect every require string literal (any quoting / paren style).
local function iterLiterals(src: string): { string }
	local lits: { string } = {}
	local function add(_whole: string, lit: string)
		lits[#lits + 1] = lit
	end
	src:gsub('(require%(%s*"([^"]*)"%s*%))', add)
	src:gsub("(require%(%s*'([^']*)'%s*%))", add)
	src:gsub('(require%s*"([^"]*)")', add)
	src:gsub("(require%s*'([^']*)')", add)
	return lits
end

-- Replace bundlable requires with __bundle_require("<key>"); keep @lune/*.
local function rewrite(src: string, fromFile: string): string
	local function repl(whole: string, lit: string): string
		if lit:sub(1, 6) == "@lune/" then
			return whole
		end
		local resolved = resolveModule(fromFile, lit)
		if resolved then
			return '__bundle_require("' .. toKey(resolved) .. '")'
		end
		return whole
	end
	src = src:gsub('(require%(%s*"([^"]*)"%s*%))', repl)
	src = src:gsub("(require%(%s*'([^']*)'%s*%))", repl)
	src = src:gsub('(require%s*"([^"]*)")', repl)
	src = src:gsub("(require%s*'([^']*)')", repl)
	return src
end

local modules: { [string]: string } = {}
local visited: { [string]: boolean } = {}

local function collect(file: string)
	local abs = normalize(file)
	if visited[abs] then
		return
	end
	visited[abs] = true

	local src = contents[abs]
	local key = toKey(abs)

	for _, lit in iterLiterals(src) do
		if lit:sub(1, 6) ~= "@lune/" then
			local resolved = resolveModule(abs, lit)
			if resolved then
				collect(resolved)
			end
		end
	end

	modules[key] = rewrite(src, abs)
end

local entryAbs = normalize(ProjectRoot .. "/" .. EntryPath)
collect(entryAbs)

local entrySource = modules[toKey(entryAbs)]
modules[toKey(entryAbs)] = nil

local out: { string } = {}
local function line(s: string)
	out[#out + 1] = s
end

line("-- bundled by scripts/bundle.luau (generated, do not edit)")
line("local __modules = {}")
line("local __cache = {}")
line("local function __bundle_require(key)")
line("	local cached = __cache[key]")
line("	if cached ~= nil then return cached end")
line("	local loader = __modules[key]")
line("	if loader == nil then error(\"missing bundled module: \" .. key, 2) end")
line("	local value = loader()")
line("	__cache[key] = value")
line("	return value")
line("end")
line("")

local keys: { string } = {}
for k in modules do
	keys[#keys + 1] = k
end
table.sort(keys)
for _, k in keys do
	line("__modules[\"" .. k .. "\"] = function()")
	line(modules[k])
	line("end")
	line("")
end

line("-- entry: " .. EntryPath)
line(entrySource)

local outDir = dirname(OutputPath)
if outDir ~= "." then
	pcall(fs.writeDir, normalize(ProjectRoot .. "/" .. outDir))
end
fs.writeFile(normalize(ProjectRoot .. "/" .. OutputPath), table.concat(out, "\n"))
print("bundled " .. tostring(#keys) .. " module(s) -> " .. OutputPath)
