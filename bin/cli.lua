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
	print("  --version    Show version")
	print("  --help       Show this help message")
	process.exit(1)
end

local inputFile: string? = nil
local outputFile: string? = nil
local runOutput = false
local timeMinify = false
local fromStdin = false
local constantFold = true
local renameVars = true
local localizeGlobals = true

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
		timeMinify = true
	elseif arg == "--no-fold" then
		constantFold = false
	elseif arg == "--no-rename" then
		renameVars = false
	elseif arg == "--no-localize" then
		localizeGlobals = false
	elseif arg:sub(1, 1) ~= "-" then
		inputFile = arg
	end
	i += 1
end

local source: string
if fromStdin then
	source = stdio.read() or ""
elseif inputFile then
	if not fs.isFile(inputFile) then
		warn("Error: file not found: " .. inputFile)
		process.exit(1)
	end
	source = fs.readFile(inputFile)
else
	warn("Error: no input. Provide a file or --stdin")
	process.exit(1)
end

local startTime = os.clock()
local result, errors = luaia.Minify(source, {
	ConstantFold = constantFold,
	MinifyVariables = renameVars,
	Rules = {
		LocalizeGlobals = localizeGlobals,
	},
})
local elapsedMs = (os.clock() - startTime) * 1000

if not result then
	for _, err in errors do
		warn("Error: " .. err)
	end
	process.exit(1)
end

if outputFile then
	fs.writeFile(outputFile, result)
end

if runOutput then
	local runPath = outputFile or (process.cwd .. "/__luaia_tmp__.luau")
	if not outputFile then
		fs.writeFile(runPath, result)
	end
	local execResult = process.exec("lune", { "run", runPath })
	if not outputFile then
		fs.removeFile(runPath)
	end
	if execResult.stdout ~= "" then
		print(execResult.stdout)
	end
	if execResult.stderr ~= "" then
		warn(execResult.stderr)
	end
	if not execResult.ok then
		process.exit(1)
	end
elseif not outputFile then
	print(result)
end

if timeMinify then
	print(string.format("Minified in %.1fms", elapsedMs))
end
