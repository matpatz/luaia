local Utils = require("./utils")

local Transformer = {}

local math_floor = math.floor
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
		DeadCodeElimination = true,
		RenameTableKeys = false,
	},
}

local VariableMap: { [string]: string } = {}

local NameGenerator = Utils.CreateNameGenerator()

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
		local savedNames = NameGenerator:Snapshot()

		local selfParam = nil
		if node.self then
			if not VariableMap[node.self.name] then
				VariableMap[node.self.name] = NameGenerator:Generate()
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
				VariableMap[param.name] = NameGenerator:Generate()
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
		NameGenerator:Restore(savedNames)

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
				VariableMap[name.name] = NameGenerator:Generate()
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
			VariableMap[node.var.name] = NameGenerator:Generate()
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
				VariableMap[name.name] = NameGenerator:Generate()
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
			VariableMap[node.name.name] = NameGenerator:Generate()
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

-- // Dead Code Elimination
-- Folds statically-known conditions (constant locals, literals, constant
-- arithmetic), removes unreachable branches, and drops unused locals.

local DCE_NilConst = {}
local DCE_OtherConst = {}

local function DCEIsPure(node): boolean
	if type(node) ~= "table" or node.kind == nil then
		return true
	end
	if node.kind == "ExprConstantNil" or node.kind == "ExprConstantBool"
		or node.kind == "ExprConstantNumber" or node.kind == "ExprConstantInteger"
		or node.kind == "ExprConstantString" or node.kind == "ExprLocal"
		or node.kind == "ExprGlobal" or node.kind == "ExprVarargs"
		or node.kind == "ExprFunction" then
		return true
	elseif node.kind == "ExprGroup" then
		return DCEIsPure(node.expr)
	elseif node.kind == "ExprIndexName" then
		return DCEIsPure(node.expr)
	elseif node.kind == "ExprIndexExpr" then
		return DCEIsPure(node.expr) and DCEIsPure(node.index)
	elseif node.kind == "ExprUnary" then
		return DCEIsPure(node.expr)
	elseif node.kind == "ExprBinary" then
		return DCEIsPure(node.left) and DCEIsPure(node.right)
	elseif node.kind == "ExprTypeAssertion" then
		return DCEIsPure(node.expr)
	elseif node.kind == "ExprIfElse" then
		return DCEIsPure(node.condition) and DCEIsPure(node.trueExpr) and DCEIsPure(node.falseExpr)
	elseif node.kind == "ExprInterpString" then
		for _, expr in node.expressions do
			if not DCEIsPure(expr) then
				return false
			end
		end
		return true
	elseif node.kind == "ExprInstantiate" then
		return DCEIsPure(node.expr)
	elseif node.kind == "ExprTable" then
		for _, item in node.items do
			if item.key and not DCEIsPure(item.key) then
				return false
			end
			if not DCEIsPure(item.value) then
				return false
			end
		end
		return true
	end
	return false
end

-- Evaluates a condition expression to a constant when possible.
-- Returns: boolean | number | string | DCE_NilConst | DCE_OtherConst, or nil when unknown.
local function DCEEvalConst(node, env): any
	if type(node) ~= "table" or node.kind == nil then
		return nil
	end
	if node.kind == "ExprConstantNil" then
		return DCE_NilConst
	elseif node.kind == "ExprConstantBool" then
		return node.value
	elseif node.kind == "ExprConstantNumber" then
		return node.value
	elseif node.kind == "ExprConstantInteger" then
		return DCE_OtherConst
	elseif node.kind == "ExprConstantString" then
		return node.value
	elseif node.kind == "ExprLocal" then
		return env[node["local"]]
	elseif node.kind == "ExprGroup" then
		return DCEEvalConst(node.expr, env)
	elseif node.kind == "ExprUnary" then
		if node.op == 0 then -- not
			local v = DCEEvalConst(node.expr, env)
			if v == nil then
				return nil
			end
			if v == false or v == DCE_NilConst then
				return true
			end
			return false
		end
	elseif node.kind == "ExprBinary" then
		if node.op == 8 or node.op == 9 then -- ~=, ==
			local l = DCEEvalConst(node.left, env)
			local r = DCEEvalConst(node.right, env)
			if l == nil or r == nil then
				return nil
			end
			if l == DCE_OtherConst or r == DCE_OtherConst then
				return nil
			end
			if node.op == 9 then
				return l == r
			end
			return l ~= r
		elseif node.op == 14 or node.op == 15 then -- and, or
			local l = DCEEvalConst(node.left, env)
			if l == nil then
				return nil
			end
			local lFalsy = (l == false or l == DCE_NilConst)
			if node.op == 14 then
				if lFalsy then
					return l
				end
				return DCEEvalConst(node.right, env)
			else
				if lFalsy then
					return DCEEvalConst(node.right, env)
				end
				return l
			end
		elseif node.op == 7 then -- ..
			local l = DCEEvalConst(node.left, env)
			local r = DCEEvalConst(node.right, env)
			if type(l) == "string" and type(r) == "string" then
				return l .. r
			end
			return nil
		elseif node.op >= 10 and node.op <= 13 then -- comparisons
			local l = DCEEvalConst(node.left, env)
			local r = DCEEvalConst(node.right, env)
			if type(l) == "number" and type(r) == "number" then
				if node.op == 10 then return l < r
				elseif node.op == 11 then return l <= r
				elseif node.op == 12 then return l > r
				elseif node.op == 13 then return l >= r end
			end
			return nil
		else
			local l = DCEEvalConst(node.left, env)
			local r = DCEEvalConst(node.right, env)
			if type(l) == "number" and type(r) == "number" then
				local opName = OpToString[node.op]
				if opName then
					local result = FoldConstantBinary(l, opName, r)
					if result ~= nil then
						return result
					end
				end
			end
			return nil
		end
	end
	return nil
end

local function DCETruthiness(value): boolean
	return value ~= false and value ~= DCE_NilConst
end

local function DCEMakeBoolNode(location, value)
	return {
		kind = "ExprConstantBool",
		location = location,
		value = value,
	}
end

local function DCECollectAssigned(node, assigned)
	if type(node) ~= "table" or node.kind == nil then
		return
	end
	if node.kind == "ExprLocal" then
		return
	elseif node.kind == "ExprIndexName" then
		DCECollectAssigned(node.expr, assigned)
	elseif node.kind == "ExprIndexExpr" then
		DCECollectAssigned(node.expr, assigned)
		DCECollectAssigned(node.index, assigned)
	elseif node.kind == "ExprCall" then
		DCECollectAssigned(node.func, assigned)
		for _, arg in node.args do
			DCECollectAssigned(arg, assigned)
		end
	elseif node.kind == "ExprFunction" then
		if node.body then
			DCECollectAssigned(node.body, assigned)
		end
	elseif node.kind == "ExprTable" then
		for _, item in node.items do
			if item.key then
				DCECollectAssigned(item.key, assigned)
			end
			DCECollectAssigned(item.value, assigned)
		end
	elseif node.kind == "ExprUnary" then
		DCECollectAssigned(node.expr, assigned)
	elseif node.kind == "ExprBinary" then
		DCECollectAssigned(node.left, assigned)
		DCECollectAssigned(node.right, assigned)
	elseif node.kind == "ExprTypeAssertion" then
		DCECollectAssigned(node.expr, assigned)
	elseif node.kind == "ExprIfElse" then
		DCECollectAssigned(node.condition, assigned)
		DCECollectAssigned(node.trueExpr, assigned)
		DCECollectAssigned(node.falseExpr, assigned)
	elseif node.kind == "ExprInterpString" then
		for _, expr in node.expressions do
			DCECollectAssigned(expr, assigned)
		end
	elseif node.kind == "ExprGroup" then
		DCECollectAssigned(node.expr, assigned)
	elseif node.kind == "ExprInstantiate" then
		DCECollectAssigned(node.expr, assigned)
	elseif node.kind == "StatBlock" then
		for _, stat in node.body do
			DCECollectAssigned(stat, assigned)
		end
	elseif node.kind == "StatIf" then
		DCECollectAssigned(node.condition, assigned)
		DCECollectAssigned(node.thenbody, assigned)
		if node.elsebody then
			DCECollectAssigned(node.elsebody, assigned)
		end
	elseif node.kind == "StatWhile" then
		DCECollectAssigned(node.condition, assigned)
		DCECollectAssigned(node.body, assigned)
	elseif node.kind == "StatRepeat" then
		DCECollectAssigned(node.body, assigned)
		DCECollectAssigned(node.condition, assigned)
	elseif node.kind == "StatFor" then
		DCECollectAssigned(node.from, assigned)
		DCECollectAssigned(node.to, assigned)
		if node.step then
			DCECollectAssigned(node.step, assigned)
		end
		DCECollectAssigned(node.body, assigned)
	elseif node.kind == "StatForIn" then
		for _, value in node.values do
			DCECollectAssigned(value, assigned)
		end
		DCECollectAssigned(node.body, assigned)
	elseif node.kind == "StatLocal" then
		for _, var in node.vars do
			assigned[var] = true
		end
		for _, value in node.values do
			DCECollectAssigned(value, assigned)
		end
	elseif node.kind == "StatAssign" then
		for _, target in node.vars do
			if target.kind == "ExprLocal" then
				assigned[target["local"]] = true
			else
				DCECollectAssigned(target, assigned)
			end
		end
		for _, value in node.values do
			DCECollectAssigned(value, assigned)
		end
	elseif node.kind == "StatCompoundAssign" then
		if node.var.kind == "ExprLocal" then
			assigned[node.var["local"]] = true
		else
			DCECollectAssigned(node.var, assigned)
		end
		DCECollectAssigned(node.value, assigned)
	elseif node.kind == "StatReturn" then
		for _, value in node.list do
			DCECollectAssigned(value, assigned)
		end
	elseif node.kind == "StatExpr" then
		DCECollectAssigned(node.expr, assigned)
	elseif node.kind == "StatFunction" then
		DCECollectAssigned(node.name, assigned)
		DCECollectAssigned(node.func, assigned)
	elseif node.kind == "StatLocalFunction" then
		if node.name then
			assigned[node.name] = true
		end
		DCECollectAssigned(node.func, assigned)
	end
end

local DCEProcessFunction: (any, any) -> ()
local DCEProcessExpr: (any, any) -> ()
local DCEFoldStat: (any, any) -> ()
local DCEFoldBlock: (any, any) -> any

DCEProcessFunction = function(func, env)
	local assigned = {}
	DCECollectAssigned(func.body, assigned)
	for l in pairs(assigned) do
		env[l] = nil
	end
	DCEFoldBlock(func.body, {})
end

DCEProcessExpr = function(node, env)
	if type(node) ~= "table" or node.kind == nil then
		return
	end
	if node.kind == "ExprFunction" then
		DCEProcessFunction(node, env)
	elseif node.kind == "ExprCall" then
		DCEProcessExpr(node.func, env)
		for _, arg in node.args do
			DCEProcessExpr(arg, env)
		end
	elseif node.kind == "ExprIndexName" then
		DCEProcessExpr(node.expr, env)
	elseif node.kind == "ExprIndexExpr" then
		DCEProcessExpr(node.expr, env)
		DCEProcessExpr(node.index, env)
	elseif node.kind == "ExprTable" then
		for _, item in node.items do
			if item.key then
				DCEProcessExpr(item.key, env)
			end
			DCEProcessExpr(item.value, env)
		end
	elseif node.kind == "ExprUnary" then
		DCEProcessExpr(node.expr, env)
	elseif node.kind == "ExprBinary" then
		DCEProcessExpr(node.left, env)
		DCEProcessExpr(node.right, env)
	elseif node.kind == "ExprTypeAssertion" then
		DCEProcessExpr(node.expr, env)
	elseif node.kind == "ExprIfElse" then
		DCEProcessExpr(node.condition, env)
		DCEProcessExpr(node.trueExpr, env)
		DCEProcessExpr(node.falseExpr, env)
	elseif node.kind == "ExprInterpString" then
		for _, expr in node.expressions do
			DCEProcessExpr(expr, env)
		end
	elseif node.kind == "ExprGroup" then
		DCEProcessExpr(node.expr, env)
	elseif node.kind == "ExprInstantiate" then
		DCEProcessExpr(node.expr, env)
	end
end

local function DCEFoldIf(stat, env)
	DCEProcessExpr(stat.condition, env)
	local c = DCEEvalConst(stat.condition, env)
	if c ~= nil then
		stat.condition = DCEMakeBoolNode(stat.condition.location, DCETruthiness(c))
		if stat.condition.value then
			local thenEnv = table_clone(env)
			DCEFoldBlock(stat.thenbody, thenEnv)
			local assigned = {}
			DCECollectAssigned(stat.thenbody, assigned)
			for l in pairs(assigned) do
				env[l] = thenEnv[l]
			end
		else
			local elseNode = stat.elsebody
			if elseNode then
				local elseEnv = table_clone(env)
				if elseNode.kind == "StatIf" then
					DCEFoldIf(elseNode, elseEnv)
				else
					DCEFoldBlock(elseNode, elseEnv)
				end
				local assigned = {}
				DCECollectAssigned(elseNode, assigned)
				for l in pairs(assigned) do
					env[l] = elseEnv[l]
				end
			end
		end
		return
	end

	local thenEnv = table_clone(env)
	DCEFoldBlock(stat.thenbody, thenEnv)
	if stat.elsebody then
		if stat.elsebody.kind == "StatIf" then
			DCEFoldIf(stat.elsebody, table_clone(env))
		else
			DCEFoldBlock(stat.elsebody, table_clone(env))
		end
	end
	local assigned = {}
	DCECollectAssigned(stat.thenbody, assigned)
	if stat.elsebody then
		DCECollectAssigned(stat.elsebody, assigned)
	end
	for l in pairs(assigned) do
		env[l] = nil
	end
end

DCEFoldStat = function(stat, env)
	if stat.kind == "StatBlock" then
		DCEFoldBlock(stat, env)
	elseif stat.kind == "StatIf" then
		DCEFoldIf(stat, env)
	elseif stat.kind == "StatWhile" then
		DCEProcessExpr(stat.condition, env)
		local c = DCEEvalConst(stat.condition, env)
		if c ~= nil then
			stat.condition = DCEMakeBoolNode(stat.condition.location, DCETruthiness(c))
		end
		if stat.condition.kind == "ExprConstantBool" and stat.condition.value == false then
			return
		end
		local bodyEnv = table_clone(env)
		DCEFoldBlock(stat.body, bodyEnv)
		local assigned = {}
		DCECollectAssigned(stat.body, assigned)
		for l in pairs(assigned) do
			env[l] = nil
		end
	elseif stat.kind == "StatRepeat" then
		local bodyEnv = table_clone(env)
		DCEFoldBlock(stat.body, bodyEnv)
		DCEProcessExpr(stat.condition, bodyEnv)
		local c = DCEEvalConst(stat.condition, bodyEnv)
		if c ~= nil then
			stat.condition = DCEMakeBoolNode(stat.condition.location, DCETruthiness(c))
		end
		local assigned = {}
		DCECollectAssigned(stat.body, assigned)
		for l in pairs(assigned) do
			env[l] = nil
		end
	elseif stat.kind == "StatFor" then
		DCEProcessExpr(stat.from, env)
		DCEProcessExpr(stat.to, env)
		if stat.step then
			DCEProcessExpr(stat.step, env)
		end
		local bodyEnv = table_clone(env)
		DCEFoldBlock(stat.body, bodyEnv)
		local assigned = {}
		DCECollectAssigned(stat.body, assigned)
		for l in pairs(assigned) do
			env[l] = nil
		end
	elseif stat.kind == "StatForIn" then
		for _, value in stat.values do
			DCEProcessExpr(value, env)
		end
		local bodyEnv = table_clone(env)
		DCEFoldBlock(stat.body, bodyEnv)
		local assigned = {}
		DCECollectAssigned(stat.body, assigned)
		for l in pairs(assigned) do
			env[l] = nil
		end
	elseif stat.kind == "StatLocal" then
		for _, value in stat.values do
			DCEProcessExpr(value, env)
		end
		if #stat.vars == #stat.values then
			for i, var in stat.vars do
				env[var] = DCEEvalConst(stat.values[i], env)
			end
		else
			for _, var in stat.vars do
				env[var] = nil
			end
		end
	elseif stat.kind == "StatLocalFunction" then
		DCEProcessFunction(stat.func, env)
		env[stat.name] = nil
	elseif stat.kind == "StatFunction" then
		DCEProcessFunction(stat.func, env)
		DCEProcessExpr(stat.name, env)
	elseif stat.kind == "StatAssign" then
		for _, value in stat.values do
			DCEProcessExpr(value, env)
		end
		local newBindings = {}
		if #stat.vars == #stat.values then
			local allLocal = true
			for _, target in stat.vars do
				if target.kind ~= "ExprLocal" then
					allLocal = false
					break
				end
			end
			if allLocal then
				for i, target in stat.vars do
					newBindings[target["local"]] = DCEEvalConst(stat.values[i], env)
				end
			else
				for _, target in stat.vars do
					if target.kind == "ExprLocal" then
						newBindings[target["local"]] = nil
					end
				end
			end
		else
			for _, target in stat.vars do
				if target.kind == "ExprLocal" then
					newBindings[target["local"]] = nil
				end
			end
		end
		for l, v in pairs(newBindings) do
			env[l] = v
		end
		for _, target in stat.vars do
			DCEProcessExpr(target, env)
		end
	elseif stat.kind == "StatCompoundAssign" then
		DCEProcessExpr(stat.value, env)
		DCEProcessExpr(stat.var, env)
		if stat.var.kind == "ExprLocal" then
			env[stat.var["local"]] = nil
		end
	elseif stat.kind == "StatReturn" then
		for _, value in stat.list do
			DCEProcessExpr(value, env)
		end
	elseif stat.kind == "StatExpr" then
		DCEProcessExpr(stat.expr, env)
	end
end

DCEFoldBlock = function(block, env)
	for _, stat in block.body do
		DCEFoldStat(stat, env)
	end
	return block
end

local function DCESpliceBranch(block)
	for _, s in block.body do
		if s.kind == "StatLocal" or s.kind == "StatLocalFunction"
			or s.kind == "StatFor" or s.kind == "StatForIn"
			or s.kind == "StatClass" then
			block.hasEnd = true
			return { block }
		end
	end
	return block.body
end

local DCERemoveDeadExpr: (any) -> any
local DCERemoveDeadBlock: (any) -> any
local DCERemoveDeadStat: (any) -> { any }

DCERemoveDeadExpr = function(node)
	if type(node) ~= "table" or node.kind == nil then
		return node
	end
	if node.kind == "ExprFunction" then
		node.body = DCERemoveDeadBlock(node.body)
	elseif node.kind == "ExprCall" then
		node.func = DCERemoveDeadExpr(node.func)
		for i, arg in node.args do
			node.args[i] = DCERemoveDeadExpr(arg)
		end
	elseif node.kind == "ExprIndexName" then
		node.expr = DCERemoveDeadExpr(node.expr)
	elseif node.kind == "ExprIndexExpr" then
		node.expr = DCERemoveDeadExpr(node.expr)
		node.index = DCERemoveDeadExpr(node.index)
	elseif node.kind == "ExprTable" then
		for _, item in node.items do
			if item.key then
				item.key = DCERemoveDeadExpr(item.key)
			end
			item.value = DCERemoveDeadExpr(item.value)
		end
	elseif node.kind == "ExprUnary" then
		node.expr = DCERemoveDeadExpr(node.expr)
	elseif node.kind == "ExprBinary" then
		node.left = DCERemoveDeadExpr(node.left)
		node.right = DCERemoveDeadExpr(node.right)
	elseif node.kind == "ExprTypeAssertion" then
		node.expr = DCERemoveDeadExpr(node.expr)
	elseif node.kind == "ExprIfElse" then
		node.condition = DCERemoveDeadExpr(node.condition)
		node.trueExpr = DCERemoveDeadExpr(node.trueExpr)
		node.falseExpr = DCERemoveDeadExpr(node.falseExpr)
	elseif node.kind == "ExprInterpString" then
		for i, expr in node.expressions do
			node.expressions[i] = DCERemoveDeadExpr(expr)
		end
	elseif node.kind == "ExprGroup" then
		node.expr = DCERemoveDeadExpr(node.expr)
	elseif node.kind == "ExprInstantiate" then
		node.expr = DCERemoveDeadExpr(node.expr)
	end
	return node
end

local function DCEMakeDoBlock(location, body)
	return {
		kind = "StatBlock",
		location = location,
		body = body,
		hasEnd = true,
	}
end

DCERemoveDeadStat = function(stat)
	if stat.kind == "StatBlock" then
		return { DCERemoveDeadBlock(stat) }
	elseif stat.kind == "StatIf" then
		if stat.condition.kind == "ExprConstantBool" then
			if stat.condition.value then
				return DCESpliceBranch(DCERemoveDeadBlock(stat.thenbody))
			end
			if stat.elsebody == nil then
				return {}
			elseif stat.elsebody.kind == "StatIf" then
				return DCERemoveDeadStat(stat.elsebody)
			end
			return DCESpliceBranch(DCERemoveDeadBlock(stat.elsebody))
		end
		local thenbody = DCERemoveDeadBlock(stat.thenbody)
		local elsebody = nil
		if stat.elsebody then
			if stat.elsebody.kind == "StatIf" then
				local list = DCERemoveDeadStat(stat.elsebody)
				if #list == 0 then
					elsebody = nil
				elseif #list == 1 and (list[1].kind == "StatIf" or list[1].kind == "StatBlock") then
					elsebody = list[1]
				else
					elsebody = DCEMakeDoBlock(stat.elsebody.location, list)
				end
			else
				elsebody = DCERemoveDeadBlock(stat.elsebody)
			end
		end
		return { {
			kind = "StatIf",
			location = stat.location,
			condition = stat.condition,
			thenbody = thenbody,
			elsebody = elsebody,
		} }
	elseif stat.kind == "StatWhile" then
		if stat.condition.kind == "ExprConstantBool" and stat.condition.value == false then
			return {}
		end
		stat.body = DCERemoveDeadBlock(stat.body)
		return { stat }
	elseif stat.kind == "StatRepeat" then
		stat.body = DCERemoveDeadBlock(stat.body)
		return { stat }
	elseif stat.kind == "StatFor" then
		stat.body = DCERemoveDeadBlock(stat.body)
		return { stat }
	elseif stat.kind == "StatForIn" then
		stat.body = DCERemoveDeadBlock(stat.body)
		return { stat }
	elseif stat.kind == "StatLocal" then
		for i, value in stat.values do
			stat.values[i] = DCERemoveDeadExpr(value)
		end
		return { stat }
	elseif stat.kind == "StatLocalFunction" then
		stat.func.body = DCERemoveDeadBlock(stat.func.body)
		return { stat }
	elseif stat.kind == "StatFunction" then
		stat.func.body = DCERemoveDeadBlock(stat.func.body)
		return { stat }
	elseif stat.kind == "StatAssign" then
		for i, value in stat.values do
			stat.values[i] = DCERemoveDeadExpr(value)
		end
		return { stat }
	elseif stat.kind == "StatCompoundAssign" then
		stat.value = DCERemoveDeadExpr(stat.value)
		return { stat }
	elseif stat.kind == "StatReturn" then
		for i, value in stat.list do
			stat.list[i] = DCERemoveDeadExpr(value)
		end
		return { stat }
	elseif stat.kind == "StatExpr" then
		stat.expr = DCERemoveDeadExpr(stat.expr)
		return { stat }
	end
	return { stat }
end

DCERemoveDeadBlock = function(block)
	local result = {}
	for _, stat in block.body do
		local list = DCERemoveDeadStat(stat)
		for _, s in list do
			table_insert(result, s)
		end
	end
	return {
		kind = "StatBlock",
		location = block.location,
		body = result,
		hasEnd = block.hasEnd,
	}
end

local function DCECollectReferences(node, referenced)
	if type(node) ~= "table" or node.kind == nil then
		return
	end
	if node.kind == "ExprLocal" then
		referenced[node["local"]] = true
	elseif node.kind == "ExprIndexName" then
		DCECollectReferences(node.expr, referenced)
	elseif node.kind == "ExprIndexExpr" then
		DCECollectReferences(node.expr, referenced)
		DCECollectReferences(node.index, referenced)
	elseif node.kind == "ExprCall" then
		DCECollectReferences(node.func, referenced)
		for _, arg in node.args do
			DCECollectReferences(arg, referenced)
		end
	elseif node.kind == "ExprFunction" then
		if node.body then
			DCECollectReferences(node.body, referenced)
		end
	elseif node.kind == "ExprTable" then
		for _, item in node.items do
			if item.key then
				DCECollectReferences(item.key, referenced)
			end
			DCECollectReferences(item.value, referenced)
		end
	elseif node.kind == "ExprUnary" then
		DCECollectReferences(node.expr, referenced)
	elseif node.kind == "ExprBinary" then
		DCECollectReferences(node.left, referenced)
		DCECollectReferences(node.right, referenced)
	elseif node.kind == "ExprTypeAssertion" then
		DCECollectReferences(node.expr, referenced)
	elseif node.kind == "ExprIfElse" then
		DCECollectReferences(node.condition, referenced)
		DCECollectReferences(node.trueExpr, referenced)
		DCECollectReferences(node.falseExpr, referenced)
	elseif node.kind == "ExprInterpString" then
		for _, expr in node.expressions do
			DCECollectReferences(expr, referenced)
		end
	elseif node.kind == "ExprGroup" then
		DCECollectReferences(node.expr, referenced)
	elseif node.kind == "ExprInstantiate" then
		DCECollectReferences(node.expr, referenced)
	elseif node.kind == "StatBlock" then
		for _, stat in node.body do
			DCECollectReferences(stat, referenced)
		end
	elseif node.kind == "StatIf" then
		DCECollectReferences(node.condition, referenced)
		DCECollectReferences(node.thenbody, referenced)
		if node.elsebody then
			DCECollectReferences(node.elsebody, referenced)
		end
	elseif node.kind == "StatWhile" then
		DCECollectReferences(node.condition, referenced)
		DCECollectReferences(node.body, referenced)
	elseif node.kind == "StatRepeat" then
		DCECollectReferences(node.body, referenced)
		DCECollectReferences(node.condition, referenced)
	elseif node.kind == "StatFor" then
		DCECollectReferences(node.from, referenced)
		DCECollectReferences(node.to, referenced)
		if node.step then
			DCECollectReferences(node.step, referenced)
		end
		DCECollectReferences(node.body, referenced)
	elseif node.kind == "StatForIn" then
		for _, value in node.values do
			DCECollectReferences(value, referenced)
		end
		DCECollectReferences(node.body, referenced)
	elseif node.kind == "StatLocal" then
		for _, value in node.values do
			DCECollectReferences(value, referenced)
		end
	elseif node.kind == "StatAssign" then
		for _, target in node.vars do
			DCECollectReferences(target, referenced)
		end
		for _, value in node.values do
			DCECollectReferences(value, referenced)
		end
	elseif node.kind == "StatCompoundAssign" then
		DCECollectReferences(node.var, referenced)
		DCECollectReferences(node.value, referenced)
	elseif node.kind == "StatReturn" then
		for _, value in node.list do
			DCECollectReferences(value, referenced)
		end
	elseif node.kind == "StatExpr" then
		DCECollectReferences(node.expr, referenced)
	elseif node.kind == "StatFunction" then
		DCECollectReferences(node.name, referenced)
		DCECollectReferences(node.func, referenced)
	elseif node.kind == "StatLocalFunction" then
		DCECollectReferences(node.func, referenced)
	end
end

local function DCERemoveUnused(node, referenced)
	if type(node) ~= "table" or node.kind == nil then
		return node
	end
	if node.kind == "StatBlock" then
		local result = {}
		for _, stat in node.body do
			local keep = true
			if stat.kind == "StatLocal" then
				local allUnused = true
				for _, var in stat.vars do
					if referenced[var] then
						allUnused = false
						break
					end
				end
				if allUnused then
					local allPure = true
					for _, value in stat.values do
						if not DCEIsPure(value) then
							allPure = false
							break
						end
					end
					if allPure then
						keep = false
					end
				end
			elseif stat.kind == "StatLocalFunction" then
				if stat.name and not referenced[stat.name] then
					keep = false
				end
			end
			if keep then
				table_insert(result, DCERemoveUnused(stat, referenced))
			end
		end
		node.body = result
		return node
	end

	if node.kind == "ExprLocal" then
		return node
	elseif node.kind == "ExprIndexName" then
		node.expr = DCERemoveUnused(node.expr, referenced)
	elseif node.kind == "ExprIndexExpr" then
		node.expr = DCERemoveUnused(node.expr, referenced)
		node.index = DCERemoveUnused(node.index, referenced)
	elseif node.kind == "ExprCall" then
		node.func = DCERemoveUnused(node.func, referenced)
		for i, arg in node.args do
			node.args[i] = DCERemoveUnused(arg, referenced)
		end
	elseif node.kind == "ExprFunction" then
		if node.body then
			node.body = DCERemoveUnused(node.body, referenced)
		end
	elseif node.kind == "ExprTable" then
		for _, item in node.items do
			if item.key then
				item.key = DCERemoveUnused(item.key, referenced)
			end
			item.value = DCERemoveUnused(item.value, referenced)
		end
	elseif node.kind == "ExprUnary" then
		node.expr = DCERemoveUnused(node.expr, referenced)
	elseif node.kind == "ExprBinary" then
		node.left = DCERemoveUnused(node.left, referenced)
		node.right = DCERemoveUnused(node.right, referenced)
	elseif node.kind == "ExprTypeAssertion" then
		node.expr = DCERemoveUnused(node.expr, referenced)
	elseif node.kind == "ExprIfElse" then
		node.condition = DCERemoveUnused(node.condition, referenced)
		node.trueExpr = DCERemoveUnused(node.trueExpr, referenced)
		node.falseExpr = DCERemoveUnused(node.falseExpr, referenced)
	elseif node.kind == "ExprInterpString" then
		for i, expr in node.expressions do
			node.expressions[i] = DCERemoveUnused(expr, referenced)
		end
	elseif node.kind == "ExprGroup" then
		node.expr = DCERemoveUnused(node.expr, referenced)
	elseif node.kind == "ExprInstantiate" then
		node.expr = DCERemoveUnused(node.expr, referenced)
	elseif node.kind == "StatIf" then
		node.condition = DCERemoveUnused(node.condition, referenced)
		node.thenbody = DCERemoveUnused(node.thenbody, referenced)
		if node.elsebody then
			node.elsebody = DCERemoveUnused(node.elsebody, referenced)
		end
	elseif node.kind == "StatWhile" then
		node.condition = DCERemoveUnused(node.condition, referenced)
		node.body = DCERemoveUnused(node.body, referenced)
	elseif node.kind == "StatRepeat" then
		node.body = DCERemoveUnused(node.body, referenced)
		node.condition = DCERemoveUnused(node.condition, referenced)
	elseif node.kind == "StatFor" then
		node.from = DCERemoveUnused(node.from, referenced)
		node.to = DCERemoveUnused(node.to, referenced)
		if node.step then
			node.step = DCERemoveUnused(node.step, referenced)
		end
		node.body = DCERemoveUnused(node.body, referenced)
	elseif node.kind == "StatForIn" then
		for i, value in node.values do
			node.values[i] = DCERemoveUnused(value, referenced)
		end
		node.body = DCERemoveUnused(node.body, referenced)
	elseif node.kind == "StatLocal" then
		for i, value in node.values do
			node.values[i] = DCERemoveUnused(value, referenced)
		end
	elseif node.kind == "StatAssign" then
		for i, target in node.vars do
			node.vars[i] = DCERemoveUnused(target, referenced)
		end
		for i, value in node.values do
			node.values[i] = DCERemoveUnused(value, referenced)
		end
	elseif node.kind == "StatCompoundAssign" then
		node.var = DCERemoveUnused(node.var, referenced)
		node.value = DCERemoveUnused(node.value, referenced)
	elseif node.kind == "StatReturn" then
		for i, value in node.list do
			node.list[i] = DCERemoveUnused(value, referenced)
		end
	elseif node.kind == "StatExpr" then
		node.expr = DCERemoveUnused(node.expr, referenced)
	elseif node.kind == "StatFunction" then
		node.name = DCERemoveUnused(node.name, referenced)
		node.func = DCERemoveUnused(node.func, referenced)
	elseif node.kind == "StatLocalFunction" then
		node.func = DCERemoveUnused(node.func, referenced)
	end
	return node
end

-- // Table Key Renaming
-- Renames the fields of table literals assigned to locals (including nested
-- tables) to short generated names and rewrites every access accordingly.
-- Off by default (RenameTableKeys). A table is left untouched whenever it can
-- be observed from code we can't rewrite: the local is reassigned, the table
-- is returned, stored into a global/env field (_G.x, shared.x, getfenv().x,
-- getgenv().x, ...), aliased to another local, embedded in another table,
-- passed to a call, or used as a call target / table key / method receiver.

local TableKeyCandidates: { any } = {}
local TableKeyMutated: { any } = {}
local TableKeyEscaped: { any } = {}
local TableKeyMaps: { any } = {}

local function NormTableKey(v)
	if type(v) == "string" then
		local n = tonumber(v)
		if n ~= nil then
			return n
		end
	end
	return v
end

local function ConstExprKey(expr)
	if expr == nil then
		return nil
	elseif expr.kind == "ExprConstantString" then
		return NormTableKey(expr.value)
	elseif expr.kind == "ExprConstantInteger" then
		return expr.low
	elseif expr.kind == "ExprConstantNumber" then
		return expr.value
	end
	return nil
end

local function ChainBaseExpr(expr)
	local e = expr
	while e ~= nil do
		if e.kind == "ExprGroup" then
			e = e.expr
		elseif e.kind == "ExprIndexName" or e.kind == "ExprIndexExpr" then
			e = e.expr
		else
			break
		end
	end
	if e ~= nil and e.kind == "ExprLocal" then
		return e
	end
	return nil
end

local function BuildTableKeyMap(tableNode)
	local map = {}
	for _, item in tableNode.items do
		local key
		if item.kind == "Record" then
			key = item.key.value
		elseif item.kind == "General" and item.key then
			key = ConstExprKey(item.key)
		else
			continue
		end
		if key == nil then
			continue
		end
		local entry = map[key]
		if entry == nil then
			entry = { name = NameGenerator:Generate() }
			map[key] = entry
		end
		if item.value and item.value.kind == "ExprTable" then
			entry.sub = BuildTableKeyMap(item.value)
		end
	end
	return map
end

local function ChainValueIsTable(value, var, map)
	if value.kind == "ExprLocal" then
		return value["local"] == var
	end
	if value.kind == "ExprGroup" then
		return ChainValueIsTable(value.expr, var, map)
	end
	if value.kind ~= "ExprIndexName" and value.kind ~= "ExprIndexExpr" then
		return false
	end
	local base = ChainBaseExpr(value)
	if base == nil or base["local"] ~= var then
		return false
	end
	local chain = {}
	local e = value
	while e.kind == "ExprIndexName" or e.kind == "ExprIndexExpr" or e.kind == "ExprGroup" do
		if e.kind == "ExprGroup" then
			e = e.expr
			continue
		end
		local k
		if e.kind == "ExprIndexName" then
			k = e.index
		else
			k = ConstExprKey(e.index)
			if k == nil then
				return false
			end
		end
		table_insert(chain, { key = k })
		e = e.expr
	end
	local m = map
	for i = #chain, 1, -1 do
		local entry = m and m[chain[i].key]
		if entry == nil then
			return false
		end
		if i == 1 then
			return entry.sub ~= nil
		end
		m = entry.sub
	end
	return false
end

local function MarkTableKeyAliased(value)
	local base = ChainBaseExpr(value)
	if base == nil then
		return
	end
	local var = base["local"]
	if TableKeyMaps[var] and ChainValueIsTable(value, var, TableKeyMaps[var]) then
		TableKeyEscaped[var] = true
	end
end

local CollectTableKeyRefs

local function CollectTableKeyRefsImpl(node, context)
	if type(node) ~= "table" or node.kind == nil then
		return
	end

	if node.kind == "ExprLocal" then
		local var = node["local"]
		if var and TableKeyCandidates[var] then
			if context == "escape" then
				TableKeyEscaped[var] = true
			elseif context == "target" then
				TableKeyMutated[var] = true
			end
		end
		return
	end

	if (node.kind == "ExprIndexName" or node.kind == "ExprIndexExpr") and context == "escape" then
		MarkTableKeyAliased(node)
	end

	if node.kind == "ExprIndexName" then
		CollectTableKeyRefs(node.expr, "value")
	elseif node.kind == "ExprIndexExpr" then
		CollectTableKeyRefs(node.expr, "value")
		CollectTableKeyRefs(node.index, "value")
	elseif node.kind == "ExprCall" then
		if node.self then
			local base = ChainBaseExpr(node.func)
			if base and TableKeyCandidates[base["local"]] then
				TableKeyEscaped[base["local"]] = true
			end
			CollectTableKeyRefs(node.func, "value")
		else
			CollectTableKeyRefs(node.func, "escape")
		end
		for _, arg in node.args do
			CollectTableKeyRefs(arg, "escape")
		end
	elseif node.kind == "ExprFunction" then
		if node.body then
			CollectTableKeyRefs(node.body, "value")
		end
	elseif node.kind == "ExprTable" then
		for _, item in node.items do
			if item.kind == "List" then
				MarkTableKeyAliased(item.value)
				CollectTableKeyRefs(item.value, "value")
			elseif item.kind == "Record" then
				MarkTableKeyAliased(item.value)
				CollectTableKeyRefs(item.value, "value")
			elseif item.kind == "General" then
				if item.key then
					CollectTableKeyRefs(item.key, "escape")
				end
				MarkTableKeyAliased(item.value)
				CollectTableKeyRefs(item.value, "value")
			end
		end
	elseif node.kind == "ExprUnary" then
		CollectTableKeyRefs(node.expr, "value")
	elseif node.kind == "ExprBinary" then
		CollectTableKeyRefs(node.left, "value")
		CollectTableKeyRefs(node.right, "value")
	elseif node.kind == "ExprTypeAssertion" then
		CollectTableKeyRefs(node.expr, "value")
	elseif node.kind == "ExprIfElse" then
		CollectTableKeyRefs(node.condition, "value")
		CollectTableKeyRefs(node.trueExpr, "value")
		CollectTableKeyRefs(node.falseExpr, "value")
	elseif node.kind == "ExprInterpString" then
		for _, expr in node.expressions do
			CollectTableKeyRefs(expr, "value")
		end
	elseif node.kind == "ExprGroup" then
		CollectTableKeyRefs(node.expr, context)
	elseif node.kind == "ExprInstantiate" then
		CollectTableKeyRefs(node.expr, "value")
	elseif node.kind == "StatBlock" then
		for _, stat in node.body do
			CollectTableKeyRefs(stat, "value")
		end
	elseif node.kind == "StatIf" then
		CollectTableKeyRefs(node.condition, "value")
		CollectTableKeyRefs(node.thenbody, "value")
		if node.elsebody then
			CollectTableKeyRefs(node.elsebody, "value")
		end
	elseif node.kind == "StatWhile" then
		CollectTableKeyRefs(node.condition, "value")
		CollectTableKeyRefs(node.body, "value")
	elseif node.kind == "StatRepeat" then
		CollectTableKeyRefs(node.body, "value")
		CollectTableKeyRefs(node.condition, "value")
	elseif node.kind == "StatFor" then
		CollectTableKeyRefs(node.from, "value")
		CollectTableKeyRefs(node.to, "value")
		if node.step then
			CollectTableKeyRefs(node.step, "value")
		end
		CollectTableKeyRefs(node.body, "value")
	elseif node.kind == "StatForIn" then
		for _, value in node.values do
			CollectTableKeyRefs(value, "value")
		end
		CollectTableKeyRefs(node.body, "value")
	elseif node.kind == "StatLocal" then
		for i, var in node.vars do
			local value = node.values[i]
			if value and value.kind == "ExprTable" and not TableKeyCandidates[var] then
				TableKeyCandidates[var] = value
				TableKeyMaps[var] = BuildTableKeyMap(value)
			end
		end
		for _, value in node.values do
			CollectTableKeyRefs(value, "value")
		end
		for _, value in node.values do
			MarkTableKeyAliased(value)
		end
	elseif node.kind == "StatAssign" then
		local allLocal = true
		for _, target in node.vars do
			if target.kind ~= "ExprLocal" then
				allLocal = false
				break
			end
		end
		for _, target in node.vars do
			if target.kind == "ExprLocal" then
				CollectTableKeyRefs(target, "target")
			else
				CollectTableKeyRefs(target, "value")
			end
		end
		local valueContext = allLocal and "value" or "escape"
		for _, value in node.values do
			CollectTableKeyRefs(value, valueContext)
		end
		if allLocal then
			for _, value in node.values do
				MarkTableKeyAliased(value)
			end
		end
	elseif node.kind == "StatCompoundAssign" then
		CollectTableKeyRefs(node.var, "value")
		CollectTableKeyRefs(node.value, "value")
	elseif node.kind == "StatReturn" then
		for _, value in node.list do
			CollectTableKeyRefs(value, "escape")
		end
	elseif node.kind == "StatExpr" then
		CollectTableKeyRefs(node.expr, "value")
	elseif node.kind == "StatFunction" then
		CollectTableKeyRefs(node.name, "value")
		CollectTableKeyRefs(node.func, "value")
	elseif node.kind == "StatLocalFunction" then
		CollectTableKeyRefs(node.func, "value")
	end
end

CollectTableKeyRefs = CollectTableKeyRefsImpl

local function RewriteTableLiteralKeys(tableNode, map)
	for _, item in tableNode.items do
		if item.kind == "Record" then
			local entry = map[item.key.value]
			if entry then
				item.key.value = entry.name
				if entry.sub and item.value and item.value.kind == "ExprTable" then
					RewriteTableLiteralKeys(item.value, entry.sub)
				end
			end
		elseif item.kind == "General" and item.key then
			local k = ConstExprKey(item.key)
			if k ~= nil then
				local entry = map[k]
				if entry then
					item.key = {
						kind = "ExprConstantString",
						location = item.key.location,
						value = entry.name,
					}
					if entry.sub and item.value and item.value.kind == "ExprTable" then
						RewriteTableLiteralKeys(item.value, entry.sub)
					end
				end
			end
		end
	end
end

local function RewriteChain(node, var, map)
	if node.kind == "ExprLocal" then
		if node["local"] == var then
			return map
		end
		return nil
	end
	if node.kind == "ExprGroup" then
		return RewriteChain(node.expr, var, map)
	end
	if node.kind == "ExprIndexName" or node.kind == "ExprIndexExpr" then
		local sub = RewriteChain(node.expr, var, map)
		if sub == nil then
			return nil
		end
		local k
		if node.kind == "ExprIndexName" then
			k = node.index
		else
			k = ConstExprKey(node.index)
			if k == nil then
				return nil
			end
		end
		local entry = sub[k]
		if entry == nil then
			return nil
		end
		if node.kind == "ExprIndexName" then
			node.index = entry.name
		else
			node.index = {
				kind = "ExprConstantString",
				location = node.index.location,
				value = entry.name,
			}
		end
		return entry.sub
	end
	return nil
end

local function RewriteTableKeyPass(node)
	if type(node) ~= "table" or node.kind == nil then
		return
	end
	if node.kind == "ExprLocal" then
		return
	elseif node.kind == "ExprIndexName" then
		local base = ChainBaseExpr(node)
		if base and TableKeyMaps[base["local"]] then
			RewriteChain(node, base["local"], TableKeyMaps[base["local"]])
		end
		RewriteTableKeyPass(node.expr)
	elseif node.kind == "ExprIndexExpr" then
		local base = ChainBaseExpr(node)
		if base and TableKeyMaps[base["local"]] then
			RewriteChain(node, base["local"], TableKeyMaps[base["local"]])
		end
		RewriteTableKeyPass(node.expr)
		RewriteTableKeyPass(node.index)
	elseif node.kind == "ExprCall" then
		RewriteTableKeyPass(node.func)
		for _, arg in node.args do
			RewriteTableKeyPass(arg)
		end
	elseif node.kind == "ExprFunction" then
		if node.body then
			RewriteTableKeyPass(node.body)
		end
	elseif node.kind == "ExprTable" then
		for _, item in node.items do
			if item.kind == "List" then
				RewriteTableKeyPass(item.value)
			elseif item.kind == "Record" then
				RewriteTableKeyPass(item.value)
			elseif item.kind == "General" then
				if item.key then
					RewriteTableKeyPass(item.key)
				end
				RewriteTableKeyPass(item.value)
			end
		end
	elseif node.kind == "ExprUnary" then
		RewriteTableKeyPass(node.expr)
	elseif node.kind == "ExprBinary" then
		RewriteTableKeyPass(node.left)
		RewriteTableKeyPass(node.right)
	elseif node.kind == "ExprTypeAssertion" then
		RewriteTableKeyPass(node.expr)
	elseif node.kind == "ExprIfElse" then
		RewriteTableKeyPass(node.condition)
		RewriteTableKeyPass(node.trueExpr)
		RewriteTableKeyPass(node.falseExpr)
	elseif node.kind == "ExprInterpString" then
		for _, expr in node.expressions do
			RewriteTableKeyPass(expr)
		end
	elseif node.kind == "ExprGroup" then
		RewriteTableKeyPass(node.expr)
	elseif node.kind == "ExprInstantiate" then
		RewriteTableKeyPass(node.expr)
	elseif node.kind == "StatBlock" then
		for _, stat in node.body do
			RewriteTableKeyPass(stat)
		end
	elseif node.kind == "StatIf" then
		RewriteTableKeyPass(node.condition)
		RewriteTableKeyPass(node.thenbody)
		if node.elsebody then
			RewriteTableKeyPass(node.elsebody)
		end
	elseif node.kind == "StatWhile" then
		RewriteTableKeyPass(node.condition)
		RewriteTableKeyPass(node.body)
	elseif node.kind == "StatRepeat" then
		RewriteTableKeyPass(node.body)
		RewriteTableKeyPass(node.condition)
	elseif node.kind == "StatFor" then
		RewriteTableKeyPass(node.from)
		RewriteTableKeyPass(node.to)
		if node.step then
			RewriteTableKeyPass(node.step)
		end
		RewriteTableKeyPass(node.body)
	elseif node.kind == "StatForIn" then
		for _, value in node.values do
			RewriteTableKeyPass(value)
		end
		RewriteTableKeyPass(node.body)
	elseif node.kind == "StatLocal" then
		for i, var in node.vars do
			local map = TableKeyMaps[var]
			if map and node.values[i] and node.values[i].kind == "ExprTable" then
				RewriteTableLiteralKeys(node.values[i], map)
			end
		end
		for _, value in node.values do
			RewriteTableKeyPass(value)
		end
	elseif node.kind == "StatAssign" then
		for _, target in node.vars do
			RewriteTableKeyPass(target)
		end
		for _, value in node.values do
			RewriteTableKeyPass(value)
		end
	elseif node.kind == "StatCompoundAssign" then
		RewriteTableKeyPass(node.var)
		RewriteTableKeyPass(node.value)
	elseif node.kind == "StatReturn" then
		for _, value in node.list do
			RewriteTableKeyPass(value)
		end
	elseif node.kind == "StatExpr" then
		RewriteTableKeyPass(node.expr)
	elseif node.kind == "StatFunction" then
		RewriteTableKeyPass(node.name)
		RewriteTableKeyPass(node.func)
	elseif node.kind == "StatLocalFunction" then
		RewriteTableKeyPass(node.func)
	end
end

local function TransformTableKeys(ast)
	TableKeyCandidates = {}
	TableKeyMutated = {}
	TableKeyEscaped = {}
	TableKeyMaps = {}

	CollectTableKeyRefs(ast, "value")

	for var in pairs(TableKeyCandidates) do
		if TableKeyMutated[var] or TableKeyEscaped[var] then
			TableKeyMaps[var] = nil
		end
	end

	RewriteTableKeyPass(ast)
end

function Transformer.Transform(ast)
	VariableMap = {}
	NameGenerator:Reset()

	if Transformer.Options.Rules.DeadCodeElimination then
		DCEFoldBlock(ast, {})
		ast = DCERemoveDeadBlock(ast)
		local referenced = {}
		DCECollectReferences(ast, referenced)
		ast = DCERemoveUnused(ast, referenced)
	end

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
			NameGenerator:Reserve(name)
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
				VariableMap[trueName] = NameGenerator:Generate()
			end
			if falseCount > 0 then
				VariableMap[falseName] = NameGenerator:Generate()
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

	if Transformer.Options.Rules.RenameTableKeys then
		TransformTableKeys(ast)
	end

	ast = TransformStatementBlock(ast)

	return ast
end

return Transformer
