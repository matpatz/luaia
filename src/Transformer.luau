local Utils = require("./utils")

local Transformer = {}

local math_floor = math.floor
local string_char = string.char
local string_find = string.find
local string_sub = string.sub
local table_clone = table.clone
local table_insert = table.insert
local table_sort = table.sort

Transformer.Options = {
	Rules = {
		MinifyVariables = true,
		ConstantFold = true,
		RemoveRedundantParens = true,
		LocalizeGlobals = true,
		LocalizeBooleans = true,
	},
}

local VariableMap: { [string]: string } = {}
local VariableCounter = 0
local UsedNames: { [string]: boolean } = {}

local ReservedNames = {
	["self"] = true,
	["true"] = true,
	["false"] = true,
	["nil"] = true,
	["and"] = true,
	["break"] = true,
	["do"] = true,
	["else"] = true,
	["elseif"] = true,
	["end"] = true,
	["for"] = true,
	["function"] = true,
	["if"] = true,
	["in"] = true,
	["local"] = true,
	["not"] = true,
	["or"] = true,
	["repeat"] = true,
	["return"] = true,
	["then"] = true,
	["until"] = true,
	["while"] = true,
	["continue"] = true,
	["type"] = true,
	["typeof"] = true,
	["declare"] = true,
	["export"] = true,
} -- @native

local function GenerateName(): string
	VariableCounter += 1
	local count = VariableCounter
	local name = ""
	local base = count

	while base > 0 do
		base -= 1
		local char = base % 52
		if char < 26 then
			name = string_char(97 + char) .. name
		else
			name = string_char(65 + char - 26) .. name
		end
		base = math_floor(base / 52)
	end

	if #name == 0 then
		name = "a"
	end

	if ReservedNames[name] or UsedNames[name] then
		return GenerateName()
	end

	UsedNames[name] = true
	return name
end

local function FoldConstantBinary(left: number, op: string, right: number): number?
	if op == "+" then
		return left + right
	elseif op == "-" then
		return left - right
	elseif op == "*" then
		return left * right
	elseif op == "/" then
		if right ~= 0 then
			return left / right
		end
	elseif op == "%" then
		if right ~= 0 then
			return left % right
		end
	elseif op == "^" then
		return left ^ right
	elseif op == "//" then
		if right ~= 0 then
			return math_floor(left / right)
		end
	elseif op == ".." then
		return nil
	end
	return nil
end

local OpToString = {
	[0] = "+", [1] = "-", [2] = "*", [3] = "/", [4] = "//",
	[5] = "%", [6] = "^", [7] = "..", [8] = "~=", [9] = "==",
	[10] = "<", [11] = "<=", [12] = ">", [13] = ">=",
	[14] = "and", [15] = "or",
}

local UnaryPrecedence = 11
local PrimaryPrecedence = 13

local BinaryPrecedence = {
	[0] = 9, [1] = 9, [2] = 10, [3] = 10, [4] = 10, [5] = 10,
	[6] = 12, [7] = 8, [8] = 3, [9] = 3, [10] = 3, [11] = 3,
	[12] = 3, [13] = 3, [14] = 2, [15] = 1,
}

local RightAssociative = {
	[6] = true, -- ^
	[7] = true, -- ..
}

local AlwaysSafeKinds = {
	ExprConstantNil = true,
	ExprConstantBool = true,
	ExprConstantNumber = true,
	ExprConstantInteger = true,
	ExprConstantString = true,
	ExprLocal = true,
	ExprGlobal = true,
	ExprIndexName = true,
	ExprIndexExpr = true,
	ExprInterpString = true,
}

local CallablePrefixKinds = {
	ExprLocal = true,
	ExprGlobal = true,
	ExprIndexName = true,
	ExprIndexExpr = true,
	ExprCall = true,
	ExprInterpString = true,
}

local function IsMultiValue(node): boolean
	return node.kind == "ExprCall" or node.kind == "ExprVarargs"
end

local function StripAllGroups(node)
	if Transformer.Options.Rules.RemoveRedundantParens then
		while node ~= nil and node.kind == "ExprGroup" do
			node = node.expr
		end
	end
	return node
end

local function StripGroupList(node, isLast)
	if not Transformer.Options.Rules.RemoveRedundantParens then
		return node
	end
	if not isLast then
		return StripAllGroups(node)
	end
	local stripped = StripAllGroups(node)
	if stripped ~= node and IsMultiValue(stripped) then
		return node
	end
	return stripped
end

local function StripPrefixGroups(node, allowedKinds)
	if not Transformer.Options.Rules.RemoveRedundantParens then
		return node
	end
	while node ~= nil and node.kind == "ExprGroup" and allowedKinds[node.expr.kind] do
		node = node.expr
	end
	return node
end

local TransformExpressionPrefix

local function ExprPrecedence(node): number
	if node == nil then
		return 0
	elseif node.kind == "ExprBinary" then
		return BinaryPrecedence[node.op] or 0
	elseif node.kind == "ExprUnary" then
		return UnaryPrecedence
	elseif node.kind == "ExprGroup" then
		return ExprPrecedence(node.expr)
	end
	return PrimaryPrecedence
end

local function StripBinaryOperand(node, parentPrec, allowEqual)
	if not Transformer.Options.Rules.RemoveRedundantParens then
		return node
	end
	while node ~= nil and node.kind == "ExprGroup" do
		local inner = node.expr
		local prec = ExprPrecedence(inner)
		if prec > parentPrec or (allowEqual and prec == parentPrec) then
			node = inner
		else
			break
		end
	end
	return node
end

local function StripUnaryOperand(node)
	return StripBinaryOperand(node, UnaryPrecedence, false)
end

local MinimumGlobalUses = 1

local function IsLocalizableRef(node): boolean
	if node.kind == "ExprGlobal" then
		return true
	elseif node.kind == "ExprIndexName" then
		return node.expr ~= nil and node.expr.kind == "ExprGlobal"
	end
	return false
end

local function RefKey(node): string
	if node.kind == "ExprGlobal" then
		return node.name
	end
	return node.expr.name .. "." .. node.index
end

local function BaseOfKey(key: string): string
	local dot = string_find(key, ".", 1, true)
	if dot then
		return string_sub(key, 1, dot - 1)
	end
	return key
end

local function BuildHoistStat(key: string)
	local dot = string_find(key, ".", 1, true)
	local loc = { begin = { x = 0, y = 0 }, end_ = { x = 0, y = 0 } }
	local value
	if dot then
		value = {
			kind = "ExprIndexName",
			location = loc,
			expr = {
				kind = "ExprGlobal",
				location = loc,
				name = string_sub(key, 1, dot - 1),
			},
			index = string_sub(key, dot + 1),
			indexLocation = loc,
			opPosition = loc.begin,
			op = 46,
		}
	else
		value = {
			kind = "ExprGlobal",
			location = loc,
			name = key,
		}
	end
	return {
		kind = "StatLocal",
		location = loc,
		vars = {
			{
				name = key,
				location = loc,
				functionDepth = 0,
				loopDepth = 0,
				isConst = false,
				isExported = false,
			},
		},
		values = { value },
		isConst = false,
		isExported = false,
		equalsSignLocation = {},
	}
end

local function WalkGlobalUses(node, context, counts, chosen, globals, mutated, mutatedBases, rewrite)
	if type(node) ~= "table" or node.kind == nil then
		return node
	end

	if rewrite then
		if context == "value" and IsLocalizableRef(node) and chosen[RefKey(node)] then
			local key = RefKey(node)
			return {
				kind = "ExprLocal",
				location = node.location,
				["local"] = {
					name = key,
					location = node.location,
					functionDepth = 0,
					loopDepth = 0,
					isConst = false,
					isExported = false,
				},
				upvalue = false,
			}
		end
	elseif context == "value" and counts and IsLocalizableRef(node) then
		local key = RefKey(node)
		counts[key] = (counts[key] or 0) + 1
	elseif context == "target" and mutated and IsLocalizableRef(node) then
		if node.kind == "ExprGlobal" then
			mutated[node.name] = true
			if mutatedBases then
				mutatedBases[node.name] = true
			end
		else
			mutated[RefKey(node)] = true
		end
	end

	if node.kind == "ExprGlobal" then
		if globals then
			globals[node.name] = true
		end
	elseif node.kind == "ExprIndexName" then
		node.expr = WalkGlobalUses(node.expr, "skip", counts, chosen, globals, mutated, mutatedBases, rewrite)
	elseif node.kind == "ExprIndexExpr" then
		node.expr = WalkGlobalUses(node.expr, "skip", counts, chosen, globals, mutated, mutatedBases, rewrite)
		node.index = WalkGlobalUses(node.index, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
	elseif node.kind == "ExprCall" then
		if node.self then
			node.func = WalkGlobalUses(node.func, "skip", counts, chosen, globals, mutated, mutatedBases, rewrite)
		else
			node.func = WalkGlobalUses(node.func, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
		end
		for i, arg in node.args do
			node.args[i] = WalkGlobalUses(arg, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
		end
	elseif node.kind == "ExprFunction" then
		if node.body then
			node.body = WalkGlobalUses(node.body, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
		end
	elseif node.kind == "ExprTable" then
		for i, item in node.items do
			if item.kind == "List" then
				item.value = WalkGlobalUses(item.value, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
			elseif item.kind == "Record" then
				item.value = WalkGlobalUses(item.value, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
			elseif item.kind == "General" then
				if item.key then
					item.key = WalkGlobalUses(item.key, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
				end
				item.value = WalkGlobalUses(item.value, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
			end
		end
	elseif node.kind == "ExprUnary" then
		node.expr = WalkGlobalUses(node.expr, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
	elseif node.kind == "ExprBinary" then
		node.left = WalkGlobalUses(node.left, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
		node.right = WalkGlobalUses(node.right, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
	elseif node.kind == "ExprTypeAssertion" then
		node.expr = WalkGlobalUses(node.expr, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
	elseif node.kind == "ExprIfElse" then
		node.condition = WalkGlobalUses(node.condition, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
		node.trueExpr = WalkGlobalUses(node.trueExpr, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
		node.falseExpr = WalkGlobalUses(node.falseExpr, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
	elseif node.kind == "ExprInterpString" then
		for i, expr in node.expressions do
			node.expressions[i] = WalkGlobalUses(expr, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
		end
	elseif node.kind == "ExprGroup" then
		node.expr = WalkGlobalUses(node.expr, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
	elseif node.kind == "ExprInstantiate" then
		node.expr = WalkGlobalUses(node.expr, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
	elseif node.kind == "StatBlock" then
		for i, stat in node.body do
			node.body[i] = WalkGlobalUses(stat, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
		end
	elseif node.kind == "StatIf" then
		node.condition = WalkGlobalUses(node.condition, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
		node.thenbody = WalkGlobalUses(node.thenbody, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
		if node.elsebody then
			node.elsebody = WalkGlobalUses(node.elsebody, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
		end
	elseif node.kind == "StatWhile" then
		node.condition = WalkGlobalUses(node.condition, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
		node.body = WalkGlobalUses(node.body, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
	elseif node.kind == "StatRepeat" then
		node.body = WalkGlobalUses(node.body, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
		node.condition = WalkGlobalUses(node.condition, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
	elseif node.kind == "StatFor" then
		node.from = WalkGlobalUses(node.from, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
		node.to = WalkGlobalUses(node.to, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
		if node.step then
			node.step = WalkGlobalUses(node.step, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
		end
		node.body = WalkGlobalUses(node.body, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
	elseif node.kind == "StatForIn" then
		for i, value in node.values do
			node.values[i] = WalkGlobalUses(value, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
		end
		node.body = WalkGlobalUses(node.body, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
	elseif node.kind == "StatLocal" then
		for i, value in node.values do
			node.values[i] = WalkGlobalUses(value, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
		end
	elseif node.kind == "StatAssign" then
		for i, target in node.vars do
			node.vars[i] = WalkGlobalUses(target, "target", counts, chosen, globals, mutated, mutatedBases, rewrite)
		end
		for i, value in node.values do
			node.values[i] = WalkGlobalUses(value, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
		end
	elseif node.kind == "StatCompoundAssign" then
		node.var = WalkGlobalUses(node.var, "target", counts, chosen, globals, mutated, mutatedBases, rewrite)
		node.value = WalkGlobalUses(node.value, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
	elseif node.kind == "StatReturn" then
		for i, value in node.list do
			node.list[i] = WalkGlobalUses(value, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
		end
	elseif node.kind == "StatExpr" then
		node.expr = WalkGlobalUses(node.expr, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
	elseif node.kind == "StatFunction" then
		node.name = WalkGlobalUses(node.name, "target", counts, chosen, globals, mutated, mutatedBases, rewrite)
		node.func = WalkGlobalUses(node.func, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
	elseif node.kind == "StatLocalFunction" then
		node.func = WalkGlobalUses(node.func, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
	end

	return node
end

local function WalkBooleanUses(node, counts, rewrite, trueName, falseName, returnsOnly, collect)
	if type(node) ~= "table" or node.kind == nil then
		return node
	end
	if collect == nil then
		collect = not returnsOnly
	end

	if node.kind == "ExprConstantBool" then
		if collect and rewrite then
			local name = node.value and trueName or falseName
			return {
				kind = "ExprLocal",
				location = node.location,
				["local"] = {
					name = name,
					location = node.location,
					functionDepth = 0,
					loopDepth = 0,
					isConst = false,
					isExported = false,
				},
				upvalue = false,
			}
		elseif collect then
			if node.value then
				counts["true"] = counts["true"] + 1
			else
				counts["false"] = counts["false"] + 1
			end
		end
	end

	if node.kind == "ExprIndexName" then
		node.expr = WalkBooleanUses(node.expr, counts, rewrite, trueName, falseName, returnsOnly, collect)
	elseif node.kind == "ExprIndexExpr" then
		node.expr = WalkBooleanUses(node.expr, counts, rewrite, trueName, falseName, returnsOnly, collect)
		node.index = WalkBooleanUses(node.index, counts, rewrite, trueName, falseName, returnsOnly, collect)
	elseif node.kind == "ExprCall" then
		node.func = WalkBooleanUses(node.func, counts, rewrite, trueName, falseName, returnsOnly, collect)
		for i, arg in node.args do
			node.args[i] = WalkBooleanUses(arg, counts, rewrite, trueName, falseName, returnsOnly, collect)
		end
	elseif node.kind == "ExprFunction" then
		if node.body then
			node.body = WalkBooleanUses(node.body, counts, rewrite, trueName, falseName, returnsOnly, collect)
		end
	elseif node.kind == "ExprTable" then
		for i, item in node.items do
			if item.kind == "List" then
				item.value = WalkBooleanUses(item.value, counts, rewrite, trueName, falseName, returnsOnly, collect)
			elseif item.kind == "Record" then
				item.value = WalkBooleanUses(item.value, counts, rewrite, trueName, falseName, returnsOnly, collect)
			elseif item.kind == "General" then
				if item.key then
					item.key = WalkBooleanUses(item.key, counts, rewrite, trueName, falseName, returnsOnly, collect)
				end
				item.value = WalkBooleanUses(item.value, counts, rewrite, trueName, falseName, returnsOnly, collect)
			end
		end
	elseif node.kind == "ExprUnary" then
		node.expr = WalkBooleanUses(node.expr, counts, rewrite, trueName, falseName, returnsOnly, collect)
	elseif node.kind == "ExprBinary" then
		node.left = WalkBooleanUses(node.left, counts, rewrite, trueName, falseName, returnsOnly, collect)
		node.right = WalkBooleanUses(node.right, counts, rewrite, trueName, falseName, returnsOnly, collect)
	elseif node.kind == "ExprTypeAssertion" then
		node.expr = WalkBooleanUses(node.expr, counts, rewrite, trueName, falseName, returnsOnly, collect)
	elseif node.kind == "ExprIfElse" then
		node.condition = WalkBooleanUses(node.condition, counts, rewrite, trueName, falseName, returnsOnly, collect)
		node.trueExpr = WalkBooleanUses(node.trueExpr, counts, rewrite, trueName, falseName, returnsOnly, collect)
		node.falseExpr = WalkBooleanUses(node.falseExpr, counts, rewrite, trueName, falseName, returnsOnly, collect)
	elseif node.kind == "ExprInterpString" then
		for i, expr in node.expressions do
			node.expressions[i] = WalkBooleanUses(expr, counts, rewrite, trueName, falseName, returnsOnly, collect)
		end
	elseif node.kind == "ExprGroup" then
		node.expr = WalkBooleanUses(node.expr, counts, rewrite, trueName, falseName, returnsOnly, collect)
	elseif node.kind == "ExprInstantiate" then
		node.expr = WalkBooleanUses(node.expr, counts, rewrite, trueName, falseName, returnsOnly, collect)
	elseif node.kind == "StatBlock" then
		for i, stat in node.body do
			node.body[i] = WalkBooleanUses(stat, counts, rewrite, trueName, falseName, returnsOnly, collect)
		end
	elseif node.kind == "StatIf" then
		node.condition = WalkBooleanUses(node.condition, counts, rewrite, trueName, falseName, returnsOnly, collect)
		node.thenbody = WalkBooleanUses(node.thenbody, counts, rewrite, trueName, falseName, returnsOnly, collect)
		if node.elsebody then
			node.elsebody = WalkBooleanUses(node.elsebody, counts, rewrite, trueName, falseName, returnsOnly, collect)
		end
	elseif node.kind == "StatWhile" then
		node.condition = WalkBooleanUses(node.condition, counts, rewrite, trueName, falseName, returnsOnly, collect)
		node.body = WalkBooleanUses(node.body, counts, rewrite, trueName, falseName, returnsOnly, collect)
	elseif node.kind == "StatRepeat" then
		node.body = WalkBooleanUses(node.body, counts, rewrite, trueName, falseName, returnsOnly, collect)
		node.condition = WalkBooleanUses(node.condition, counts, rewrite, trueName, falseName, returnsOnly, collect)
	elseif node.kind == "StatFor" then
		node.from = WalkBooleanUses(node.from, counts, rewrite, trueName, falseName, returnsOnly, collect)
		node.to = WalkBooleanUses(node.to, counts, rewrite, trueName, falseName, returnsOnly, collect)
		if node.step then
			node.step = WalkBooleanUses(node.step, counts, rewrite, trueName, falseName, returnsOnly, collect)
		end
		node.body = WalkBooleanUses(node.body, counts, rewrite, trueName, falseName, returnsOnly, collect)
	elseif node.kind == "StatForIn" then
		for i, value in node.values do
			node.values[i] = WalkBooleanUses(value, counts, rewrite, trueName, falseName, returnsOnly, collect)
		end
		node.body = WalkBooleanUses(node.body, counts, rewrite, trueName, falseName, returnsOnly, collect)
	elseif node.kind == "StatLocal" then
		for i, value in node.values do
			node.values[i] = WalkBooleanUses(value, counts, rewrite, trueName, falseName, returnsOnly, collect)
		end
	elseif node.kind == "StatAssign" then
		for i, target in node.vars do
			node.vars[i] = WalkBooleanUses(target, counts, rewrite, trueName, falseName, returnsOnly, collect)
		end
		for i, value in node.values do
			node.values[i] = WalkBooleanUses(value, counts, rewrite, trueName, falseName, returnsOnly, collect)
		end
	elseif node.kind == "StatCompoundAssign" then
		node.var = WalkBooleanUses(node.var, counts, rewrite, trueName, falseName, returnsOnly, collect)
		node.value = WalkBooleanUses(node.value, counts, rewrite, trueName, falseName, returnsOnly, collect)
	elseif node.kind == "StatReturn" then
		for i, value in node.list do
			node.list[i] = WalkBooleanUses(value, counts, rewrite, trueName, falseName, returnsOnly, returnsOnly and true or collect)
		end
	elseif node.kind == "StatExpr" then
		node.expr = WalkBooleanUses(node.expr, counts, rewrite, trueName, falseName, returnsOnly, collect)
	elseif node.kind == "StatFunction" then
		node.name = WalkBooleanUses(node.name, counts, rewrite, trueName, falseName, returnsOnly, collect)
		node.func = WalkBooleanUses(node.func, counts, rewrite, trueName, falseName, returnsOnly, collect)
	elseif node.kind == "StatLocalFunction" then
		node.func = WalkBooleanUses(node.func, counts, rewrite, trueName, falseName, returnsOnly, collect)
	end

	return node
end

local TransformStatement: (typeof(node)) -> typeof(node)
local TransformStatementBlock: (typeof(node)) -> typeof(node)

local function TransformExpression(node): typeof(node)
	if node == nil then
		return nil
	end

	if node.kind == "ExprConstantNil" or node.kind == "ExprConstantBool"
		or node.kind == "ExprConstantNumber" or node.kind == "ExprConstantInteger"
		or node.kind == "ExprConstantString" or node.kind == "ExprVarargs" then
		return node

	elseif node.kind == "ExprLocal" then
		local newName = VariableMap[node["local"].name] or node["local"].name
		return {
			kind = "ExprLocal",
			location = node.location,
			["local"] = {
				name = newName,
				location = node["local"].location,
				functionDepth = node["local"].functionDepth,
				loopDepth = node["local"].loopDepth,
				isConst = node["local"].isConst,
				isExported = node["local"].isExported,
			},
			upvalue = node.upvalue,
		}

	elseif node.kind == "ExprGlobal" then
		return node

	elseif node.kind == "ExprCall" then
		local newArgs = {}
		local count = #node.args
		for i, arg in node.args do
			local t = TransformExpression(arg)
			if Transformer.Options.Rules.RemoveRedundantParens then
				t = StripGroupList(t, i == count)
			end
			table_insert(newArgs, t)
		end
		return {
			kind = "ExprCall",
			location = node.location,
			func = StripPrefixGroups(TransformExpressionPrefix(node.func), CallablePrefixKinds),
			args = newArgs,
			self = node.self,
		}

	elseif node.kind == "ExprIndexName" then
		return {
			kind = "ExprIndexName",
			location = node.location,
			expr = StripPrefixGroups(TransformExpressionPrefix(node.expr), CallablePrefixKinds),
			index = node.index,
			indexLocation = node.indexLocation,
			opPosition = node.opPosition,
			op = node.op,
		}

	elseif node.kind == "ExprIndexExpr" then
		return {
			kind = "ExprIndexExpr",
			location = node.location,
			expr = StripPrefixGroups(TransformExpressionPrefix(node.expr), CallablePrefixKinds),
			index = StripAllGroups(TransformExpression(node.index)),
		}

	elseif node.kind == "ExprFunction" then
		local savedMap = table_clone(VariableMap)
		local savedCounter = VariableCounter
		local savedNames = table_clone(UsedNames)

		local selfParam = nil
		if node.self then
			if not VariableMap[node.self.name] then
				VariableMap[node.self.name] = GenerateName()
			end
			selfParam = {
				name = VariableMap[node.self.name],
				location = node.self.location,
				functionDepth = node.self.functionDepth,
				loopDepth = node.self.loopDepth,
				isConst = node.self.isConst,
				isExported = node.self.isExported,
			}
		end

		local newParams = {}
		for _, param in node.args do
			if not VariableMap[param.name] then
				VariableMap[param.name] = GenerateName()
			end
			table_insert(newParams, {
				name = VariableMap[param.name],
				location = param.location,
				functionDepth = param.functionDepth,
				loopDepth = param.loopDepth,
				isConst = param.isConst,
				isExported = param.isExported,
			})
		end

		local newBody = TransformStatementBlock(node.body)

		VariableMap = savedMap
		VariableCounter = savedCounter
		UsedNames = savedNames

		return {
			kind = "ExprFunction",
			location = node.location,
			generics = node.generics,
			genericPacks = node.genericPacks,
			args = newParams,
			self = selfParam,
			body = newBody,
			vararg = node.vararg,
			attributes = node.attributes,
			argLocation = node.argLocation,
			functionDepth = node.functionDepth,
			debugname = node.debugname,
		}

	elseif node.kind == "ExprTable" then
		local newItems = {}
		local count = #node.items
		local lastExpands = count > 0 and node.items[count].kind == "List"
		for i, item in node.items do
			if item.kind == "List" then
				table_insert(newItems, {
					kind = "List",
					value = StripGroupList(TransformExpression(item.value), i == count and lastExpands),
				})
			elseif item.kind == "Record" then
				table_insert(newItems, {
					kind = "Record",
					key = item.key,
					value = StripAllGroups(TransformExpression(item.value)),
				})
			elseif item.kind == "General" then
				table_insert(newItems, {
					kind = "General",
					key = item.key and StripAllGroups(TransformExpression(item.key)) or nil,
					value = StripAllGroups(TransformExpression(item.value)),
				})
			end
		end
		return {
			kind = "ExprTable",
			location = node.location,
			items = newItems,
		}

	elseif node.kind == "ExprUnary" then
		return {
			kind = "ExprUnary",
			location = node.location,
			op = node.op,
			expr = StripUnaryOperand(TransformExpression(node.expr)),
		}

	elseif node.kind == "ExprBinary" then
		local left = TransformExpression(node.left)
		local right = TransformExpression(node.right)

		if Transformer.Options.Rules.RemoveRedundantParens then
			left = StripBinaryOperand(left, BinaryPrecedence[node.op], not RightAssociative[node.op])
			right = StripBinaryOperand(right, BinaryPrecedence[node.op], RightAssociative[node.op])
		end

		if Transformer.Options.Rules.ConstantFold then
			if left.kind == "ExprConstantNumber" and right.kind == "ExprConstantNumber" then
				local opName = OpToString[node.op]
				if opName then
					local result = FoldConstantBinary(left.value, opName, right.value)
					if result then
						return {
							kind = "ExprConstantNumber",
							location = node.location,
							value = result,
							parseResult = "Ok",
						}
					end
				end
			end
		end

		return {
			kind = "ExprBinary",
			location = node.location,
			op = node.op,
			left = left,
			right = right,
		}

	elseif node.kind == "ExprIfElse" then
		return {
			kind = "ExprIfElse",
			location = node.location,
			condition = StripAllGroups(TransformExpression(node.condition)),
			trueExpr = StripAllGroups(TransformExpression(node.trueExpr)),
			falseExpr = StripAllGroups(TransformExpression(node.falseExpr)),
			hasThen = node.hasThen,
			hasElse = node.hasElse,
		}

	elseif node.kind == "ExprInterpString" then
		local newExprs = {}
		for _, expr in node.expressions do
			table_insert(newExprs, StripAllGroups(TransformExpression(expr)))
		end
		return {
			kind = "ExprInterpString",
			location = node.location,
			strings = node.strings,
			expressions = newExprs,
		}

	elseif node.kind == "ExprTypeAssertion" then
		return {
			kind = "ExprTypeAssertion",
			location = node.location,
			expr = StripAllGroups(TransformExpression(node.expr)),
			annotation = node.annotation,
		}

	elseif node.kind == "ExprGroup" then
		local inner = TransformExpression(node.expr)
		if Transformer.Options.Rules.RemoveRedundantParens and AlwaysSafeKinds[inner.kind] then
			return inner
		end
		return {
			kind = "ExprGroup",
			location = node.location,
			expr = inner,
		}

	elseif node.kind == "ExprInstantiate" then
		return {
			kind = "ExprInstantiate",
			location = node.location,
			expr = TransformExpression(node.expr),
		}
	end

	return node
end

TransformExpressionPrefix = function(node)
	if node.kind == "ExprGroup" then
		local inner = TransformExpression(node.expr)
		return {
			kind = "ExprGroup",
			location = node.location,
			expr = inner,
		}
	end
	return TransformExpression(node)
end

local function IsSafeBoolCondition(expr): boolean
	if expr == nil then
		return false
	elseif expr.kind == "ExprConstantBool" then
		return true
	elseif expr.kind == "ExprUnary" then
		return expr.op == 0
	elseif expr.kind == "ExprGroup" then
		return IsSafeBoolCondition(expr.expr)
	elseif expr.kind == "ExprBinary" then
		return expr.op >= 8 and expr.op <= 13
	end
	return false
end

local function NegateExpr(expr, location)
	if ExprPrecedence(expr) <= UnaryPrecedence then
		return {
			kind = "ExprUnary",
			location = location,
			op = 0,
			expr = {
				kind = "ExprGroup",
				location = location,
				expr = expr,
			},
		}
	end
	return {
		kind = "ExprUnary",
		location = location,
		op = 0,
		expr = expr,
	}
end

local function BoolReturnValue(stat): boolean?
	if stat.kind ~= "StatReturn" or #stat.list ~= 1 then
		return nil
	end
	local value = stat.list[1]
	if value.kind ~= "ExprConstantBool" then
		return nil
	end
	return value.value
end

local function MakeBoolReturn(condition, thenIsTrue, location)
	local value = condition
	if not thenIsTrue then
		value = NegateExpr(condition, location)
	end
	return {
		kind = "StatReturn",
		location = location,
		list = { value },
	}
end

local function CollapseIfElse(stat)
	if stat.kind ~= "StatIf" or stat.elsebody == nil then
		return nil
	end
	if not IsSafeBoolCondition(stat.condition) then
		return nil
	end
	local thenbody = stat.thenbody
	local elsebody = stat.elsebody
	if thenbody.kind ~= "StatBlock" or #thenbody.body ~= 1 then
		return nil
	end
	if elsebody.kind ~= "StatBlock" or #elsebody.body ~= 1 then
		return nil
	end
	local thenValue = BoolReturnValue(thenbody.body[1])
	local elseValue = BoolReturnValue(elsebody.body[1])
	if thenValue == nil or elseValue == nil or thenValue == elseValue then
		return nil
	end
	return MakeBoolReturn(stat.condition, thenValue, stat.location)
end

local function CollapseTailReturn(stat, nextStat)
	if stat.kind ~= "StatIf" or stat.elsebody ~= nil then
		return nil
	end
	if not IsSafeBoolCondition(stat.condition) then
		return nil
	end
	if nextStat == nil then
		return nil
	end
	local thenbody = stat.thenbody
	if thenbody.kind ~= "StatBlock" or #thenbody.body ~= 1 then
		return nil
	end
	local thenValue = BoolReturnValue(thenbody.body[1])
	local nextValue = BoolReturnValue(nextStat)
	if thenValue == nil or nextValue == nil or nextValue == thenValue then
		return nil
	end
	return MakeBoolReturn(stat.condition, thenValue, stat.location)
end

local CollapseBoolReturnsInStat

local function CollapseBoolReturnsInBlock(body)
	for _, stat in body do
		CollapseBoolReturnsInStat(stat)
	end
	local result = {}
	local i = 1
	while i <= #body do
		local stat = body[i]
		local collapsed = CollapseIfElse(stat)
		if collapsed then
			table_insert(result, collapsed)
			i += 1
			continue
		end
		collapsed = CollapseTailReturn(stat, body[i + 1])
		if collapsed then
			table_insert(result, collapsed)
			i += 2
			continue
		end
		table_insert(result, stat)
		i += 1
	end
	return result
end

CollapseBoolReturnsInStat = function(stat)
	if stat.kind == "StatIf" then
		stat.thenbody.body = CollapseBoolReturnsInBlock(stat.thenbody.body)
		if stat.elsebody then
			if stat.elsebody.kind == "StatIf" then
				CollapseBoolReturnsInStat(stat.elsebody)
			else
				stat.elsebody.body = CollapseBoolReturnsInBlock(stat.elsebody.body)
			end
		end
	elseif stat.kind == "StatBlock" then
		stat.body = CollapseBoolReturnsInBlock(stat.body)
	elseif stat.kind == "StatFunction" or stat.kind == "StatLocalFunction" then
		stat.func.body.body = CollapseBoolReturnsInBlock(stat.func.body.body)
	elseif stat.kind == "StatWhile" or stat.kind == "StatRepeat"
		or stat.kind == "StatFor" or stat.kind == "StatForIn" then
		stat.body.body = CollapseBoolReturnsInBlock(stat.body.body)
	end
	return stat
end

TransformStatementBlock = function(node): typeof(node)
	local newStats = {}
	for _, stat in node.body do
		table_insert(newStats, TransformStatement(stat))
	end
	return {
		kind = "StatBlock",
		location = node.location,
		body = newStats,
		hasEnd = node.hasEnd,
	}
end

TransformStatement = function(node): typeof(node)
	if node.kind == "StatBlock" then
		return TransformStatementBlock(node)

	elseif node.kind == "StatLocal" then
		local newValues = {}
		local count = #node.values
		for i, value in node.values do
			local t = TransformExpression(value)
			if Transformer.Options.Rules.RemoveRedundantParens then
				t = StripGroupList(t, i == count)
			end
			table_insert(newValues, t)
		end

		local newNames = {}
		for _, name in node.vars do
			if not VariableMap[name.name] then
				VariableMap[name.name] = GenerateName()
			end
			table_insert(newNames, {
				name = VariableMap[name.name],
				location = name.location,
				functionDepth = name.functionDepth,
				loopDepth = name.loopDepth,
				isConst = name.isConst,
				isExported = name.isExported,
			})
		end

		return {
			kind = "StatLocal",
			location = node.location,
			vars = newNames,
			values = newValues,
			isConst = node.isConst,
			isExported = node.isExported,
			equalsSignLocation = node.equalsSignLocation,
		}

	elseif node.kind == "StatIf" then
		local newThenBody = TransformStatementBlock(node.thenbody)
		local newElseBody = nil
		if node.elsebody then
			if node.elsebody.kind == "StatIf" then
				newElseBody = TransformStatement(node.elsebody)
			else
				newElseBody = TransformStatementBlock(node.elsebody)
			end
		end
		return {
			kind = "StatIf",
			location = node.location,
			condition = StripAllGroups(TransformExpression(node.condition)),
			thenbody = newThenBody,
			elsebody = newElseBody,
		}

	elseif node.kind == "StatWhile" then
		return {
			kind = "StatWhile",
			location = node.location,
			condition = StripAllGroups(TransformExpression(node.condition)),
			body = TransformStatementBlock(node.body),
		}

	elseif node.kind == "StatRepeat" then
		return {
			kind = "StatRepeat",
			location = node.location,
			body = TransformStatementBlock(node.body),
			condition = StripAllGroups(TransformExpression(node.condition)),
		}

	elseif node.kind == "StatFor" then
		if not VariableMap[node.var.name] then
			VariableMap[node.var.name] = GenerateName()
		end
		return {
			kind = "StatFor",
			location = node.location,
			var = {
				name = VariableMap[node.var.name],
				location = node.var.location,
				functionDepth = node.var.functionDepth,
				loopDepth = node.var.loopDepth,
				isConst = node.var.isConst,
				isExported = node.var.isExported,
			},
			from = StripAllGroups(TransformExpression(node.from)),
			to = StripAllGroups(TransformExpression(node.to)),
			step = node.step and StripAllGroups(TransformExpression(node.step)) or nil,
			body = TransformStatementBlock(node.body),
		}

	elseif node.kind == "StatForIn" then
		local newNames = {}
		for _, name in node.vars do
			if not VariableMap[name.name] then
				VariableMap[name.name] = GenerateName()
			end
			table_insert(newNames, {
				name = VariableMap[name.name],
				location = name.location,
				functionDepth = name.functionDepth,
				loopDepth = name.loopDepth,
				isConst = name.isConst,
				isExported = name.isExported,
			})
		end

		local newValues = {}
		local count = #node.values
		for i, value in node.values do
			local t = TransformExpression(value)
			if Transformer.Options.Rules.RemoveRedundantParens then
				t = StripGroupList(t, i == count)
			end
			table_insert(newValues, t)
		end

		return {
			kind = "StatForIn",
			location = node.location,
			vars = newNames,
			values = newValues,
			body = TransformStatementBlock(node.body),
		}

	elseif node.kind == "StatAssign" then
		local newTargets = {}
		for _, target in node.vars do
			table_insert(newTargets, TransformExpression(target))
		end
		local newValues = {}
		local count = #node.values
		for i, value in node.values do
			local t = TransformExpression(value)
			if Transformer.Options.Rules.RemoveRedundantParens then
				t = StripGroupList(t, i == count)
			end
			table_insert(newValues, t)
		end
		return {
			kind = "StatAssign",
			location = node.location,
			vars = newTargets,
			values = newValues,
		}

	elseif node.kind == "StatCompoundAssign" then
		return {
			kind = "StatCompoundAssign",
			location = node.location,
			op = node.op,
			var = TransformExpression(node.var),
			value = StripAllGroups(TransformExpression(node.value)),
		}

	elseif node.kind == "StatReturn" then
		local newValues = {}
		local count = #node.list
		for i, value in node.list do
			local t = TransformExpression(value)
			if Transformer.Options.Rules.RemoveRedundantParens then
				t = StripGroupList(t, i == count)
			end
			table_insert(newValues, t)
		end
		return {
			kind = "StatReturn",
			location = node.location,
			list = newValues,
		}

	elseif node.kind == "StatExpr" then
		return {
			kind = "StatExpr",
			location = node.location,
			expr = StripAllGroups(TransformExpression(node.expr)),
		}

	elseif node.kind == "StatFunction" then
		return {
			kind = "StatFunction",
			location = node.location,
			name = TransformExpression(node.name),
			func = TransformExpression(node.func),
			attributes = node.attributes,
		}

	elseif node.kind == "StatLocalFunction" then
		if not VariableMap[node.name.name] then
			VariableMap[node.name.name] = GenerateName()
		end
		return {
			kind = "StatLocalFunction",
			location = node.location,
			name = {
				name = VariableMap[node.name.name],
				location = node.name.location,
				functionDepth = node.name.functionDepth,
				loopDepth = node.name.loopDepth,
				isConst = node.name.isConst,
				isExported = node.name.isExported,
			},
			func = TransformExpression(node.func),
			isConst = node.isConst,
		}

	elseif node.kind == "StatTypeAlias" or node.kind == "StatTypeFunction"
		or node.kind == "StatDeclareGlobal" or node.kind == "StatDeclareFunction"
		or node.kind == "StatDeclareExternType" or node.kind == "StatClass"
		or node.kind == "StatBreak" or node.kind == "StatContinue" then
		return node

	elseif node.kind == "StatError" then
		return node
	end

	return node
end

function Transformer.Transform(ast)
	VariableMap = {}
	VariableCounter = 0
	UsedNames = {}

	if Transformer.Options.Rules.LocalizeGlobals then
		local counts = {}
		local globals = {}
		local mutated = {}
		local mutatedBases = {}

		WalkGlobalUses(ast, "value", counts, nil, globals, mutated, mutatedBases, false)

		local chosen = {}
		for key, count in pairs(counts) do
			if count >= MinimumGlobalUses
				and not mutated[key]
				and not mutatedBases[BaseOfKey(key)] then
				chosen[key] = true
			end
		end

		if next(chosen) ~= nil then
			WalkGlobalUses(ast, "value", counts, chosen, globals, mutated, mutatedBases, true)

			local hoists = {}
			for key in pairs(chosen) do
				table_insert(hoists, BuildHoistStat(key))
			end
			table_sort(hoists, function(a, b)
				return a.vars[1].name < b.vars[1].name
			end)

			for i, stat in hoists do
				table_insert(ast.body, i, stat)
			end
		end

		for name in pairs(globals) do
			UsedNames[name] = true
		end
	end

	if Transformer.Options.Rules.ConstantFold then
		ast.body = CollapseBoolReturnsInBlock(ast.body)
	end

	local function LocalizeBools(ast, returnsOnly)
		local counts = { ["true"] = 0, ["false"] = 0 }
		WalkBooleanUses(ast, counts, false, nil, nil, returnsOnly)

		local trueCount = counts["true"]
		local falseCount = counts["false"]
		local declCost = 0
		if trueCount > 0 and falseCount > 0 then
			declCost = 21
		elseif trueCount > 0 then
			declCost = 13
		elseif falseCount > 0 then
			declCost = 14
		end

		if declCost > 0 and 3 * trueCount + 4 * falseCount > declCost then
			local trueName = "luaia_bool_true"
			local falseName = "luaia_bool_false"
			if trueCount > 0 then
				VariableMap[trueName] = GenerateName()
			end
			if falseCount > 0 then
				VariableMap[falseName] = GenerateName()
			end

			WalkBooleanUses(ast, counts, true, trueName, falseName, returnsOnly)

			local loc = { begin = { x = 0, y = 0 }, end_ = { x = 0, y = 0 } }
			local vars = {}
			local values = {}
			if trueCount > 0 then
				table_insert(vars, {
					name = trueName,
					location = loc,
					functionDepth = 0,
					loopDepth = 0,
					isConst = false,
					isExported = false,
				})
				table_insert(values, { kind = "ExprConstantBool", location = loc, value = true })
			end
			if falseCount > 0 then
				table_insert(vars, {
					name = falseName,
					location = loc,
					functionDepth = 0,
					loopDepth = 0,
					isConst = false,
					isExported = false,
				})
				table_insert(values, { kind = "ExprConstantBool", location = loc, value = false })
			end
			table_insert(ast.body, 1, {
				kind = "StatLocal",
				location = loc,
				vars = vars,
				values = values,
				isConst = false,
				isExported = false,
				equalsSignLocation = {},
			})
		end
	end

	if Transformer.Options.Rules.LocalizeBooleans then
		LocalizeBools(ast, false)
	else
		LocalizeBools(ast, true)
	end

	ast = TransformStatementBlock(ast)

	return ast
end

return Transformer
