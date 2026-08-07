local process = require("@lune/process")
local fs = require("@lune/fs")
local stdio = require("@lune/stdio")
local luaia = require("@luaia")

local args = process.args

if #args == 0 then
	print("luaia - Luau minifier")
	print("")
	print("Usage:")
	print("  lune run bin/cli.lua <file>           Minify a file")
	print("  lune run bin/cli.lua <file> -o <out>  Minify and write to output file")
	print("  lune run bin/cli.lua <file> -r        Minify and run output")
	print("  lune run bin/cli.lua --stdin          Minify from stdin")
	print("")
	print("Options:")
	print("  -o <file>    Write output to file (default: stdout)")
	print("  -r           Run the minified output")
	print("  -t           Print time taken to minify")
	print("  --no-fold    Disable constant folding")
	print("  --no-rename  Disable variable renaming")
	print("  --no-localize  Disable global function localization")
	print("  --no-bools     Disable boolean literal localization")
	print("  --version    Show version")
	print("  --help       Show this help message")
	process.exit(1)
end

local Options = {
	InputFile = nil,
	OutputFile = nil,
	RunOutput = false,
	TimeMinify = false,
	FromStdin = false,

	ConstantFold = true,
	RenameVariables = true,
	LocalizeGlobals = true,
	LocalizeBooleans = true,
}

local i = 1
while i <= #args do
	local arg = args[i]
	if arg == "--version" then
		print("luaia v0.1.0")
		process.exit(0)
	elseif arg == "--help" then
		print("luaia - Luau minifier")
		print("")
		print("Usage:")
		print("  lune run bin/cli.lua <file>           Minify a file")
		print("  lune run bin/cli.lua <file> -o <out>  Minify and write to output file")
		print("  lune run bin/cli.lua <file> -r        Minify and run output")
		print("  lune run bin/cli.lua --stdin          Minify from stdin")
		print("")
		print("Options:")
		print("  -o <file>    Write output to file (default: stdout)")
		print("  -r           Run the minified output")
		print("  -t           Print time taken to minify")
		print("  --no-fold    Disable constant folding")
		print("  --no-rename  Disable variable renaming")
		print("  --no-localize  Disable global function localization")
		print("  --no-bools     Disable boolean literal localization")
		print("  --version    Show version")
		print("  --help       Show this help message")
		process.exit(0)
	elseif arg == "--stdin" then
		fromStdin = true
	elseif arg == "-o" then
		i += 1
		outputFile = args[i]
	elseif arg == "-r" then
		runOutput = true
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
	elseif arg:sub(1, 1) ~= "-" then
		Options.InputFile = arg
	end
	i += 1
end

local source: string
if fromStdin then
	source = stdio.read() or ""
elseif Options.InputFile then
	if not fs.isFile(Options.InputFile) then
		warn("Error: file not found: " .. Options.InputFile)
		process.exit(1)
	end
	source = fs.readFile(Options.InputFile)
else
	warn("Error: no input. Provide a file or --stdin")
	process.exit(1)
end

local Start = os.clock()
local Result, Errors = luaia.Minify(source, {
	Rules = {
		MinifyVariables = Options.RenameVariables,
		ConstantFold = Options.ConstantFold,
		LocalizeGlobals = Options.LocalizeGlobals,
		LocalizeBooleans = Options.LocalizeBooleans,
	},
})
local Elapsed = (os.clock() - Start) * 1000

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
	local runPath = Options.OutputFile or (process.cwd() .. "/__luaia_tmp__.luau")
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
	print(string.format("Minified in %.1fms", Elapsed))
end
