local Parser = require("../src/Parser")
local Transformer = require("../src/Transformer")
local Generator = require("../src/Generator")
local process = require("@lune/process")

local fixtures = require("./fixtures")

local DefaultRules = {
	MinifyVariables = true,
	ConstantFold = true,
	RemoveRedundantParens = true,
	LocalizeGlobals = true,
	LocalizeBooleans = true,
	LocalizeStrings = true,
	DeadCodeElimination = true,
	RenameTableKeys = false,
	TableConstantFolding = false,
}

local Configurations = {
	{
		name = "minimal",
		rules = {
			MinifyVariables = false,
			ConstantFold = false,
			RemoveRedundantParens = false,
			LocalizeGlobals = false,
			LocalizeBooleans = false,
			LocalizeStrings = false,
			DeadCodeElimination = false,
			RenameTableKeys = false,
			TableConstantFolding = false,
		},
	},
	{
		name = "no-dce",
		rules = {
			DeadCodeElimination = false,
		},
	},
	{
		name = "no-localize",
		rules = {
			LocalizeGlobals = false,
			LocalizeBooleans = false,
			LocalizeStrings = false,
		},
	},
	{
		name = "no-globals",
		rules = {
			LocalizeGlobals = false,
		},
	},
	{
		name = "no-bools",
		rules = {
			LocalizeBooleans = false,
		},
	},
	{
		name = "no-strings",
		rules = {
			LocalizeStrings = false,
		},
	},
	{
		name = "default",
		rules = {},
	},
	{
		name = "all-rules",
		rules = {
			RenameTableKeys = true,
			TableConstantFolding = true,
		},
	},
}

local function getNumberArg(name: string, default: number): number
	for i, arg in process.args do
		if arg == name and process.args[i + 1] then
			return tonumber(process.args[i + 1]) or default
		end
	end
	return default
end

local runs = getNumberArg("--runs", 8)
local warmup = getNumberArg("--warmup", 2)

local function setRules(overrides)
	Transformer.Options.Rules = table.clone(DefaultRules)
	for name, value in overrides do
		Transformer.Options.Rules[name] = value
	end
end

local function runOnce(source: string)
	local started = os.clock()
	local ast, errors = Parser.Parse(source)
	if not ast then
		error(table.concat(errors, "\n"))
	end
	local parsed = os.clock()

	local transformed = Transformer.Transform(ast)
	local transformedAt = os.clock()
	local output = Generator.Generate(transformed)
	local finished = os.clock()

	return {
		parse = parsed - started,
		transform = transformedAt - parsed,
		generate = finished - transformedAt,
		total = finished - started,
		outputSize = #output,
	}
end

local function benchmark(source: string, configuration)
	setRules(configuration.rules)
	for _ = 1, warmup do
		runOnce(source)
	end

	local totals = { parse = 0, transform = 0, generate = 0, total = 0 }
	local outputSize = 0
	for _ = 1, runs do
		local result = runOnce(source)
		for phase in totals do
			totals[phase] += result[phase]
		end
		outputSize = result.outputSize
	end

	for phase in totals do
		totals[phase] /= runs
	end

	return totals, outputSize
end

local function milliseconds(seconds: number): string
	return string.format("%.3f", seconds * 1000)
end

print(string.format("luaia benchmark: %d measured runs, %d warmup runs", runs, warmup))
print("")

for _, fixture in fixtures do
	print(string.format("[%s] input=%d bytes", fixture.name, #fixture.source))
	for _, configuration in Configurations do
		local timings, outputSize = benchmark(fixture.source, configuration)
		print(string.format(
			"  %-10s total=%sms parse=%sms transform=%sms generate=%sms output=%d bytes",
			configuration.name,
			milliseconds(timings.total),
			milliseconds(timings.parse),
			milliseconds(timings.transform),
			milliseconds(timings.generate),
			outputSize
		))
	end
end
