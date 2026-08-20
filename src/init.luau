local Parser = require("@self/Parser")
local Transformer = require("@self/Transformer")
local Generator = require("@self/Generator")
local VariablePacker = require("@self/VariablePacker")

local luaia = {}

luaia.Parser = Parser
luaia.Transformer = Transformer
luaia.Generator = Generator
luaia.VariablePacker = VariablePacker

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
	InlineSingleUse = true,
}

function luaia.Minify(Source: string, Options: { Rules: { MinifyVariables: boolean?, ConstantFold: boolean?, RemoveRedundantParens: boolean?, LocalizeGlobals: boolean?, LocalizeBooleans: boolean?, LocalizeStrings: boolean?, DeadCodeElimination: boolean?, RenameTableKeys: boolean?, TableConstantFolding: boolean?, InlineSingleUse: boolean? }? }?): (string?, { string }?)
	Transformer.Options.Rules = table.clone(DefaultRules)

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
			if Options.Rules.LocalizeStrings ~= nil then
				Transformer.Options.Rules.LocalizeStrings = Options.Rules.LocalizeStrings
			end
			if Options.Rules.DeadCodeElimination ~= nil then
				Transformer.Options.Rules.DeadCodeElimination = Options.Rules.DeadCodeElimination
			end
			if Options.Rules.RenameTableKeys ~= nil then
				Transformer.Options.Rules.RenameTableKeys = Options.Rules.RenameTableKeys
			end
			if Options.Rules.TableConstantFolding ~= nil then
				Transformer.Options.Rules.TableConstantFolding = Options.Rules.TableConstantFolding
			end
			if Options.Rules.InlineSingleUse ~= nil then
				Transformer.Options.Rules.InlineSingleUse = Options.Rules.InlineSingleUse
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

function luaia.PackVariables(Source: string): (string?, { string }?)
	local AST, Errors = Parser.Parse(Source)
	if not AST then
		return nil, Errors
	end

	return Generator.Generate(VariablePacker.Transform(AST)), nil
end

return luaia
