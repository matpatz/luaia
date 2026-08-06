local Utils = require("./utils")

local Transformer = {}

Transformer.Options = {
	MinifyVariables = true,
	ConstantFold = true,
	RemoveRedundantParens = true,
	Rules = {
		LocalizeGlobals = true,
	},
}

local variableMap: { [string]: string } = {}
local variableCounter = 0
local usedNames: { [string]: boolean } = {}

local reservedNames = {
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

local function generateName(): string
	variableCounter += 1
	local count = variableCounter
	local name = ""
	local base = count

	while base > 0 do
		base -= 1
		local char = base % 52
		if char < 26 then
			name = string.char(97 + char) .. name
		else
			name = string.char(65 + char - 26) .. name
		end
		base = math.floor(base / 52)
	end

	if #name == 0 then
		name = "a"
	end

	if reservedNames[name] or usedNames[name] then
		return generateName()
	end

	usedNames[name] = true
	return name
end

local function foldConstantBinary(left: number, op: string, right: number): number?
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
			return math.floor(left / right)
		end
	elseif op == ".." then
		return nil
	end
	return nil
end

local opToString = {
	[0] = "+", [1] = "-", [2] = "*", [3] = "/", [4] = "//",
	[5] = "%", [6] = "^", [7] = "..", [8] = "~=", [9] = "==",
	[10] = "<", [11] = "<=", [12] = ">", [13] = ">=",
	[14] = "and", [15] = "or",
}

local minimumGlobalUses = 1

local function isLocalizableRef(node): boolean
	if node.kind == "ExprGlobal" then
		return true
	elseif node.kind == "ExprIndexName" then
		return node.expr ~= nil and node.expr.kind == "ExprGlobal"
	end
	return false
end

local function refKey(node): string
	if node.kind == "ExprGlobal" then
		return node.name
	end
	return node.expr.name .. "." .. node.index
end

local function baseOfKey(key: string): string
	local dot = string.find(key, ".", 1, true)
	if dot then
		return key:sub(1, dot - 1)
	end
	return key
end

local function buildHoistStat(key: string)
	local dot = string.find(key, ".", 1, true)
	local loc = { begin = { x = 0, y = 0 }, end_ = { x = 0, y = 0 } }
	local value
	if dot then
		value = {
			kind = "ExprIndexName",
			location = loc,
			expr = {
				kind = "ExprGlobal",
				location = loc,
				name = key:sub(1, dot - 1),
			},
			index = key:sub(dot + 1),
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

local function walkGlobalUses(node, context, counts, chosen, globals, mutated, mutatedBases, rewrite)
	if type(node) ~= "table" or node.kind == nil then
		return node
	end

	if rewrite then
		if context == "value" and isLocalizableRef(node) and chosen[refKey(node)] then
			local key = refKey(node)
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
	elseif context == "value" and counts and isLocalizableRef(node) then
		local key = refKey(node)
		counts[key] = (counts[key] or 0) + 1
	elseif context == "target" and mutated and isLocalizableRef(node) then
		if node.kind == "ExprGlobal" then
			mutated[node.name] = true
			if mutatedBases then
				mutatedBases[node.name] = true
			end
		else
			mutated[refKey(node)] = true
		end
	end

	if node.kind == "ExprGlobal" then
		if globals then
			globals[node.name] = true
		end
	elseif node.kind == "ExprIndexName" then
		node.expr = walkGlobalUses(node.expr, "skip", counts, chosen, globals, mutated, mutatedBases, rewrite)
	elseif node.kind == "ExprIndexExpr" then
		node.expr = walkGlobalUses(node.expr, "skip", counts, chosen, globals, mutated, mutatedBases, rewrite)
		node.index = walkGlobalUses(node.index, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
	elseif node.kind == "ExprCall" then
		if node.self then
			node.func = walkGlobalUses(node.func, "skip", counts, chosen, globals, mutated, mutatedBases, rewrite)
		else
			node.func = walkGlobalUses(node.func, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
		end
		for i, arg in node.args do
			node.args[i] = walkGlobalUses(arg, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
		end
	elseif node.kind == "ExprFunction" then
		if node.body then
			node.body = walkGlobalUses(node.body, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
		end
	elseif node.kind == "ExprTable" then
		for i, item in node.items do
			if item.kind == "List" then
				item.value = walkGlobalUses(item.value, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
			elseif item.kind == "Record" then
				item.value = walkGlobalUses(item.value, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
			elseif item.kind == "General" then
				if item.key then
					item.key = walkGlobalUses(item.key, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
				end
				item.value = walkGlobalUses(item.value, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
			end
		end
	elseif node.kind == "ExprUnary" then
		node.expr = walkGlobalUses(node.expr, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
	elseif node.kind == "ExprBinary" then
		node.left = walkGlobalUses(node.left, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
		node.right = walkGlobalUses(node.right, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
	elseif node.kind == "ExprTypeAssertion" then
		node.expr = walkGlobalUses(node.expr, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
	elseif node.kind == "ExprIfElse" then
		node.condition = walkGlobalUses(node.condition, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
		node.thenExpr = walkGlobalUses(node.thenExpr, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
		node.elseExpr = walkGlobalUses(node.elseExpr, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
	elseif node.kind == "ExprInterpString" then
		for i, expr in node.expressions do
			node.expressions[i] = walkGlobalUses(expr, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
		end
	elseif node.kind == "ExprGroup" then
		node.expr = walkGlobalUses(node.expr, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
	elseif node.kind == "ExprInstantiate" then
		node.expr = walkGlobalUses(node.expr, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
	elseif node.kind == "StatBlock" then
		for i, stat in node.body do
			node.body[i] = walkGlobalUses(stat, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
		end
	elseif node.kind == "StatIf" then
		node.condition = walkGlobalUses(node.condition, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
		node.thenbody = walkGlobalUses(node.thenbody, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
		if node.elsebody then
			node.elsebody = walkGlobalUses(node.elsebody, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
		end
	elseif node.kind == "StatWhile" then
		node.condition = walkGlobalUses(node.condition, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
		node.body = walkGlobalUses(node.body, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
	elseif node.kind == "StatRepeat" then
		node.body = walkGlobalUses(node.body, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
		node.condition = walkGlobalUses(node.condition, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
	elseif node.kind == "StatFor" then
		node.from = walkGlobalUses(node.from, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
		node.to = walkGlobalUses(node.to, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
		if node.step then
			node.step = walkGlobalUses(node.step, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
		end
		node.body = walkGlobalUses(node.body, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
	elseif node.kind == "StatForIn" then
		for i, value in node.values do
			node.values[i] = walkGlobalUses(value, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
		end
		node.body = walkGlobalUses(node.body, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
	elseif node.kind == "StatLocal" then
		for i, value in node.values do
			node.values[i] = walkGlobalUses(value, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
		end
	elseif node.kind == "StatAssign" then
		for i, target in node.vars do
			node.vars[i] = walkGlobalUses(target, "target", counts, chosen, globals, mutated, mutatedBases, rewrite)
		end
		for i, value in node.values do
			node.values[i] = walkGlobalUses(value, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
		end
	elseif node.kind == "StatCompoundAssign" then
		node.var = walkGlobalUses(node.var, "target", counts, chosen, globals, mutated, mutatedBases, rewrite)
		node.value = walkGlobalUses(node.value, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
	elseif node.kind == "StatReturn" then
		for i, value in node.list do
			node.list[i] = walkGlobalUses(value, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
		end
	elseif node.kind == "StatExpr" then
		node.expr = walkGlobalUses(node.expr, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
	elseif node.kind == "StatFunction" then
		node.name = walkGlobalUses(node.name, "target", counts, chosen, globals, mutated, mutatedBases, rewrite)
		node.func = walkGlobalUses(node.func, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
	elseif node.kind == "StatLocalFunction" then
		node.func = walkGlobalUses(node.func, "value", counts, chosen, globals, mutated, mutatedBases, rewrite)
	end

	return node
end

local transformStatement: (typeof(node)) -> typeof(node)
local transformStatementBlock: (typeof(node)) -> typeof(node)

local function transformExpression(node): typeof(node)
	if node == nil then
		return nil
	end

	if node.kind == "ExprConstantNil" or node.kind == "ExprConstantBool"
		or node.kind == "ExprConstantNumber" or node.kind == "ExprConstantInteger"
		or node.kind == "ExprConstantString" or node.kind == "ExprVarargs" then
		return node

	elseif node.kind == "ExprLocal" then
		local newName = variableMap[node["local"].name] or node["local"].name
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
		return {
			kind = "ExprCall",
			location = node.location,
			func = transformExpression(node.func),
			args = (function()
				local newArgs = {}
				for _, arg in node.args do
					table.insert(newArgs, transformExpression(arg))
				end
				return newArgs
			end)(),
			self = node.self,
		}

	elseif node.kind == "ExprIndexName" then
		return {
			kind = "ExprIndexName",
			location = node.location,
			expr = transformExpression(node.expr),
			index = node.index,
			indexLocation = node.indexLocation,
			opPosition = node.opPosition,
			op = node.op,
		}

	elseif node.kind == "ExprIndexExpr" then
		return {
			kind = "ExprIndexExpr",
			location = node.location,
			expr = transformExpression(node.expr),
			index = transformExpression(node.index),
		}

	elseif node.kind == "ExprFunction" then
		local savedMap = table.clone(variableMap)
		local savedCounter = variableCounter
		local savedNames = table.clone(usedNames)

		local selfParam = nil
		if node.self then
			if not variableMap[node.self.name] then
				variableMap[node.self.name] = generateName()
			end
			selfParam = {
				name = variableMap[node.self.name],
				location = node.self.location,
				functionDepth = node.self.functionDepth,
				loopDepth = node.self.loopDepth,
				isConst = node.self.isConst,
				isExported = node.self.isExported,
			}
		end

		local newParams = {}
		for _, param in node.args do
			if not variableMap[param.name] then
				variableMap[param.name] = generateName()
			end
			table.insert(newParams, {
				name = variableMap[param.name],
				location = param.location,
				functionDepth = param.functionDepth,
				loopDepth = param.loopDepth,
				isConst = param.isConst,
				isExported = param.isExported,
			})
		end

		local newBody = transformStatementBlock(node.body)

		variableMap = savedMap
		variableCounter = savedCounter
		usedNames = savedNames

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
		for _, item in node.items do
			if item.kind == "List" then
				table.insert(newItems, {
					kind = "List",
					value = transformExpression(item.value),
				})
			elseif item.kind == "Record" then
				table.insert(newItems, {
					kind = "Record",
					key = item.key,
					value = transformExpression(item.value),
				})
			elseif item.kind == "General" then
				table.insert(newItems, {
					kind = "General",
					key = item.key and transformExpression(item.key) or nil,
					value = transformExpression(item.value),
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
			expr = transformExpression(node.expr),
		}

	elseif node.kind == "ExprBinary" then
		local left = transformExpression(node.left)
		local right = transformExpression(node.right)

		if Transformer.Options.ConstantFold then
			if left.kind == "ExprConstantNumber" and right.kind == "ExprConstantNumber" then
				local opName = opToString[node.op]
				if opName then
					local result = foldConstantBinary(left.value, opName, right.value)
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

	elseif node.kind == "ExprTypeAssertion" then
		return {
			kind = "ExprTypeAssertion",
			location = node.location,
			expr = transformExpression(node.expr),
			type = node.type,
		}

	elseif node.kind == "ExprIfElse" then
		return {
			kind = "ExprIfElse",
			location = node.location,
			condition = transformExpression(node.condition),
			thenExpr = transformExpression(node.thenExpr),
			elseExpr = transformExpression(node.elseExpr),
		}

	elseif node.kind == "ExprInterpString" then
		local newExprs = {}
		for _, expr in node.expressions do
			table.insert(newExprs, transformExpression(expr))
		end
		return {
			kind = "ExprInterpString",
			location = node.location,
			strings = node.strings,
			expressions = newExprs,
		}

	elseif node.kind == "ExprGroup" then
		return {
			kind = "ExprGroup",
			location = node.location,
			expr = transformExpression(node.expr),
		}

	elseif node.kind == "ExprInstantiate" then
		return {
			kind = "ExprInstantiate",
			location = node.location,
			expr = transformExpression(node.expr),
		}
	end

	return node
end

transformStatementBlock = function(node): typeof(node)
	local newStats = {}
	for _, stat in node.body do
		table.insert(newStats, transformStatement(stat))
	end
	return {
		kind = "StatBlock",
		location = node.location,
		body = newStats,
		hasEnd = node.hasEnd,
	}
end

transformStatement = function(node): typeof(node)
	if node.kind == "StatBlock" then
		return transformStatementBlock(node)

	elseif node.kind == "StatLocal" then
		local newValues = {}
		for _, value in node.values do
			table.insert(newValues, transformExpression(value))
		end

		local newNames = {}
		for _, name in node.vars do
			if not variableMap[name.name] then
				variableMap[name.name] = generateName()
			end
			table.insert(newNames, {
				name = variableMap[name.name],
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
		local newThenBody = transformStatementBlock(node.thenbody)
		local newElseBody = nil
		if node.elsebody then
			if node.elsebody.kind == "StatIf" then
				newElseBody = transformStatement(node.elsebody)
			else
				newElseBody = transformStatementBlock(node.elsebody)
			end
		end
		return {
			kind = "StatIf",
			location = node.location,
			condition = transformExpression(node.condition),
			thenbody = newThenBody,
			elsebody = newElseBody,
		}

	elseif node.kind == "StatWhile" then
		return {
			kind = "StatWhile",
			location = node.location,
			condition = transformExpression(node.condition),
			body = transformStatementBlock(node.body),
		}

	elseif node.kind == "StatRepeat" then
		return {
			kind = "StatRepeat",
			location = node.location,
			body = transformStatementBlock(node.body),
			condition = transformExpression(node.condition),
		}

	elseif node.kind == "StatFor" then
		if not variableMap[node.var.name] then
			variableMap[node.var.name] = generateName()
		end
		return {
			kind = "StatFor",
			location = node.location,
			var = {
				name = variableMap[node.var.name],
				location = node.var.location,
				functionDepth = node.var.functionDepth,
				loopDepth = node.var.loopDepth,
				isConst = node.var.isConst,
				isExported = node.var.isExported,
			},
			from = transformExpression(node.from),
			to = transformExpression(node.to),
			step = node.step and transformExpression(node.step) or nil,
			body = transformStatementBlock(node.body),
		}

	elseif node.kind == "StatForIn" then
		local newNames = {}
		for _, name in node.vars do
			if not variableMap[name.name] then
				variableMap[name.name] = generateName()
			end
			table.insert(newNames, {
				name = variableMap[name.name],
				location = name.location,
				functionDepth = name.functionDepth,
				loopDepth = name.loopDepth,
				isConst = name.isConst,
				isExported = name.isExported,
			})
		end

		local newValues = {}
		for _, value in node.values do
			table.insert(newValues, transformExpression(value))
		end

		return {
			kind = "StatForIn",
			location = node.location,
			vars = newNames,
			values = newValues,
			body = transformStatementBlock(node.body),
		}

	elseif node.kind == "StatAssign" then
		local newTargets = {}
		for _, target in node.vars do
			table.insert(newTargets, transformExpression(target))
		end
		local newValues = {}
		for _, value in node.values do
			table.insert(newValues, transformExpression(value))
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
			var = transformExpression(node.var),
			value = transformExpression(node.value),
		}

	elseif node.kind == "StatReturn" then
		local newValues = {}
		for _, value in node.list do
			table.insert(newValues, transformExpression(value))
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
			expr = transformExpression(node.expr),
		}

	elseif node.kind == "StatFunction" then
		return {
			kind = "StatFunction",
			location = node.location,
			name = transformExpression(node.name),
			func = transformExpression(node.func),
			attributes = node.attributes,
		}

	elseif node.kind == "StatLocalFunction" then
		if not variableMap[node.name.name] then
			variableMap[node.name.name] = generateName()
		end
		return {
			kind = "StatLocalFunction",
			location = node.location,
			name = {
				name = variableMap[node.name.name],
				location = node.name.location,
				functionDepth = node.name.functionDepth,
				loopDepth = node.name.loopDepth,
				isConst = node.name.isConst,
				isExported = node.name.isExported,
			},
			func = transformExpression(node.func),
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
	variableMap = {}
	variableCounter = 0
	usedNames = {}

	if Transformer.Options.Rules.LocalizeGlobals then
		local counts = {}
		local globals = {}
		local mutated = {}
		local mutatedBases = {}

		walkGlobalUses(ast, "value", counts, nil, globals, mutated, mutatedBases, false)

		local chosen = {}
		for key, count in pairs(counts) do
			if count >= minimumGlobalUses
				and not mutated[key]
				and not mutatedBases[baseOfKey(key)] then
				chosen[key] = true
			end
		end

		if next(chosen) ~= nil then
			walkGlobalUses(ast, "value", counts, chosen, globals, mutated, mutatedBases, true)

			local hoists = {}
			for key in pairs(chosen) do
				table.insert(hoists, buildHoistStat(key))
			end
			table.sort(hoists, function(a, b)
				return a.vars[1].name < b.vars[1].name
			end)

			for i, stat in hoists do
				table.insert(ast.body, i, stat)
			end
		end

		for name in pairs(globals) do
			usedNames[name] = true
		end
	end

	ast = transformStatementBlock(ast)

	return ast
end

return Transformer
