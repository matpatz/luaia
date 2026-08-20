local process = require("@lune/process")
local fs = require("@lune/fs")
local stdio = require("@lune/stdio")
-- local DateTime = require("@lune/datetime")
-- Require luaia by relative path so `lune build` bundles it into the
-- standalone binary (the `@luaia` alias is not bundled).
local luaia = require("../src")

local args = process.args

if #args == 0 then
	print("luaia - Luau minifier")
	print("")
	print("Usage:")
	print("  lune run bin/cli.lua <file>           Minify a file")
	print("  lune run bin/cli.lua -s <source>     Minify raw source")
	print("  lune run bin/cli.lua <file> -o <out>  Minify and write to output file")
	print("  lune run bin/cli.lua <file> -r        Minify and run output")
	print("  lune run bin/cli.lua --stdin          Minify from stdin")
	print("  lune run bin/cli.lua --pack-locals    Pack locals into tables")
	print("")
	print("Options:")
	print("  -s <source>  Minify raw source (instead of a file)")
	print("  -o <file>    Write output to file (default: stdout)")
	print("  -r           Run the minified output")
	print("  -t           Print time taken to minify")
	print("  --no-fold    Disable constant folding")
	print("  --no-rename  Disable variable renaming")
	print("  --no-localize  Disable global function localization")
	print("  --no-bools     Disable boolean literal localization")
	print("  --no-strings   Disable repeated string localization")
	print("  --no-dce       Disable dead code elimination")
	print("  --no-inline-single-use  Disable inlining of constant locals")
	print("  --table-keys   Enable table field renaming (off by default)")
	print("  --table-fold   Enable table constant folding (off by default)")
	print("  --pack-locals  Store locals in tables to bypass Luau's local limit")
	print("  --version    Show version")
	print("  --help       Show this help message")
	process.exit(1)
end

local Options = {
	InputFile = nil,
	OutputFile = nil,
	Source = nil,
	RunOutput = false,
	TimeMinify = false,
	FromStdin = false,

	ConstantFold = true,
	RenameVariables = true,
	LocalizeGlobals = true,
	LocalizeBooleans = true,
	LocalizeStrings = true,
	DeadCodeElimination = true,
	RenameTableKeys = false,
	TableConstantFolding = false,
	PackLocals = false,
	InlineSingleUse = true,
}

local i = 1
while i <= #args do
	local arg = args[i]
	if arg == "--version" then
		print("luaia v0.6.0")
		process.exit(0)
	elseif arg == "--help" then
		print("luaia - Luau minifier")
		print("")
		print("Usage:")
		print("  lune run bin/cli.lua <file>           Minify a file")
		print("  lune run bin/cli.lua -s <source>     Minify raw source")
		print("  lune run bin/cli.lua <file> -o <out>  Minify and write to output file")
		print("  lune run bin/cli.lua <file> -r        Minify and run output")
		print("  lune run bin/cli.lua --stdin          Minify from stdin")
		print("  lune run bin/cli.lua --pack-locals    Pack locals into tables")
		print("")
		print("Options:")
		print("  -s <source>  Minify raw source (instead of a file)")
		print("  -o <file>    Write output to file (default: stdout)")
		print("  -r           Run the minified output")
		print("  -t           Print time taken to minify")
		print("  --no-fold    Disable constant folding")
		print("  --no-rename  Disable variable renaming")
		print("  --no-localize  Disable global function localization")
		print("  --no-bools     Disable boolean literal localization")
		print("  --no-strings   Disable repeated string localization")
		print("  --no-dce       Disable dead code elimination")
		print("  --no-inline-single-use  Disable inlining of constant locals")
		print("  --table-keys   Enable table field renaming (off by default)")
		print("  --table-fold   Enable table constant folding (off by default)")
		print("  --pack-locals  Store locals in tables to bypass Luau's local limit")
		print("  --version    Show version")
		print("  --help       Show this help message")
		process.exit(0)
	elseif arg == "--stdin" then
		Options.FromStdin = true
	elseif arg == "-s" then
		i += 1
		Options.Source = args[i]
	elseif arg == "-o" then
		i += 1
		Options.OutputFile = args[i]
	elseif arg == "-r" then
		Options.RunOutput = true
	elseif arg == "-t" then
		Options.TimeMinify = true
	elseif arg == "--no-fold" then
		Options.ConstantFold = false
	elseif arg == "--no-rename" then
		Options.RenameVariables = false
	elseif arg == "--no-localize" then
		Options.LocalizeGlobals = false
	elseif arg == "--no-bools" then
		Options.LocalizeBooleans = false
	elseif arg == "--no-strings" then
		Options.LocalizeStrings = false
	elseif arg == "--no-dce" then
		Options.DeadCodeElimination = false
	elseif arg == "--no-inline-single-use" then
		Options.InlineSingleUse = false
	elseif arg == "--table-keys" then
		Options.RenameTableKeys = true
	elseif arg == "--table-fold" then
		Options.TableConstantFolding = true
	elseif arg == "--pack-locals" then
		Options.PackLocals = true
	elseif arg:sub(1, 1) ~= "-" then
		Options.InputFile = arg
	end
	i += 1
end

local source: string
if Options.Source then
	source = Options.Source
elseif Options.FromStdin then
	source = stdio.readToEnd() or ""
elseif Options.InputFile then
	if not fs.isFile(Options.InputFile) then
		warn("Error: file not found: " .. Options.InputFile)
		process.exit(1)
	end
	source = fs.readFile(Options.InputFile)
else
	warn("Error: no input. Provide a file, -s <source>, or --stdin")
	process.exit(1)
end

local StartClock = os.clock()

local Result, Errors
if Options.PackLocals then
	Result, Errors = luaia.PackVariables(source)
else
	Result, Errors = luaia.Minify(source, {
		Rules = {
			MinifyVariables = Options.RenameVariables,
			ConstantFold = Options.ConstantFold,
			LocalizeGlobals = Options.LocalizeGlobals,
			LocalizeBooleans = Options.LocalizeBooleans,
			LocalizeStrings = Options.LocalizeStrings,
			DeadCodeElimination = Options.DeadCodeElimination,
			RenameTableKeys = Options.RenameTableKeys,
			TableConstantFolding = Options.TableConstantFolding,
			InlineSingleUse = Options.InlineSingleUse,
		},
	})
end
local ElapsedSeconds = os.clock() - StartClock

if not Result then
	for _, Error in Errors do
		warn("Error: " .. Error)
	end
	process.exit(1)
end

if Options.OutputFile then
	fs.writeFile(Options.OutputFile, Result)
end

if Options.RunOutput then
	local runPath = Options.OutputFile or (process.cwd .. "/__luaia_tmp__.luau")
	if not Options.OutputFile then
		fs.writeFile(runPath, Result)
	end
	local OutputResult = process.exec("lune", { "run", runPath })
	if not Options.OutputFile then
		fs.removeFile(runPath)
	end
	if OutputResult.stdout ~= "" then
		print(OutputResult.stdout)
	end
	if OutputResult.stderr ~= "" then
		warn(OutputResult.stderr)
	end
	if not OutputResult.ok then
		process.exit(1)
	end
elseif not Options.OutputFile then
	print(Result)
end

if Options.TimeMinify then
    local ns = ElapsedSeconds * 1e9
    print(string.format("Minified in %d ns (%.1f ms)", ns, ElapsedSeconds * 1000))
end
