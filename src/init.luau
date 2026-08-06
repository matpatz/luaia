local Parser = require("@self/Parser")
local Transformer = require("@self/Transformer")
local Generator = require("@self/Generator")

local luaia = {}

luaia.Parser = Parser
luaia.Transformer = Transformer
luaia.Generator = Generator

function luaia.Minify(Source: string, Options: { MinifyVariables: boolean?, ConstantFold: boolean?, Rules: { LocalizeGlobals: boolean? }? }?): (string?, { string }?)
	if Options then
		if Options.MinifyVariables ~= nil then
			Transformer.Options.MinifyVariables = Options.MinifyVariables
		end
		if Options.ConstantFold ~= nil then
			Transformer.Options.ConstantFold = Options.ConstantFold
		end
		if Options.Rules ~= nil and Options.Rules.LocalizeGlobals ~= nil then
			Transformer.Options.Rules.LocalizeGlobals = Options.Rules.LocalizeGlobals
		end
	end

	local AST, Errors = Parser.Parse(Source)
	if not AST then
		return nil, Errors
	end

	local Optimized = Transformer.Transform(AST)
	local Result = Generator.Generate(Optimized)

	return Result, nil
end

return luaia
