local Utils = require("./utils")

local Transformer = {}

Transformer.Options = {
	MinifyVariables = true,
	ConstantFold = true,
	RemoveRedundantParens = true,
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
}

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
			operand = transformExpression(node.operand),
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
			name = node.name,
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

	ast = transformStatementBlock(ast)

	return ast
end

return Transformer
