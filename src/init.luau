local Parser = require("@self/Parser")
local Transformer = require("@self/Transformer")
local Generator = require("@self/Generator")

local luaia = {}

luaia.Parser = Parser
luaia.Transformer = Transformer
luaia.Generator = Generator

function luaia.Minify(Source: string, Options: { Rules: { MinifyVariables: boolean?, ConstantFold: boolean?, RemoveRedundantParens: boolean?, LocalizeGlobals: boolean?, LocalizeBooleans: boolean? }? }?): (string?, { string }?)
	if Options then
		if Options.Rules then
			if Options.Rules.MinifyVariables ~= nil then
				Transformer.Options.Rules.MinifyVariables = Options.Rules.MinifyVariables
			end
			if Options.Rules.ConstantFold ~= nil then
				Transformer.Options.Rules.ConstantFold = Options.Rules.ConstantFold
			end
			if Options.Rules.RemoveRedundantParens ~= nil then
				Transformer.Options.Rules.RemoveRedundantParens = Options.Rules.RemoveRedundantParens
			end
			if Options.Rules.LocalizeGlobals ~= nil then
				Transformer.Options.Rules.LocalizeGlobals = Options.Rules.LocalizeGlobals
			end
			if Options.Rules.LocalizeBooleans ~= nil then
				Transformer.Options.Rules.LocalizeBooleans = Options.Rules.LocalizeBooleans
			end
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
