local VariablePacker = {}

local table_insert = table.insert

local UsedNames: { [string]: boolean } = {}
local Bindings: { [any]: any } = {}
local NextKey = 0
local NextGeneratedName = 0
local TableName = ""

local function CollectNames(value, seen)
	if type(value) ~= "table" or seen[value] then
		return
	end
	seen[value] = true

	if type(value.name) == "string" then
		UsedNames[value.name] = true
	end
	if value.kind == "ExprGlobal" and type(value.name) == "string" then
		UsedNames[value.name] = true
	end

	for key, child in pairs(value) do
		if key ~= "location" and key ~= "cstNode" and key ~= "shadow" then
			CollectNames(child, seen)
		end
	end
end

local function FreshName(prefix: string): string
	local name = prefix
	while UsedNames[name] do
		NextGeneratedName += 1
		name = prefix .. tostring(NextGeneratedName)
	end
	UsedNames[name] = true
	return name
end

local function NewLocal(name: string, location, source)
	return {
		name = name,
		location = location,
		functionDepth = source and source.functionDepth or 0,
		loopDepth = source and source.loopDepth or 0,
		isConst = false,
		isExported = false,
	}
end

local function LocalExpression(local_, location, upvalue)
	return {
		kind = "ExprLocal",
		location = location,
		["local"] = local_,
		upvalue = upvalue == true,
	}
end

local function StringExpression(value, location)
	return {
		kind = "ExprConstantString",
		location = location,
		value = value,
	}
end

local function VariableExpression(binding, location, upvalue)
	if binding.kind == "direct" then
		return LocalExpression(binding["local"], location, upvalue)
	end

	local base = LocalExpression(binding.table, location, upvalue or binding.upvalue)
	return {
		kind = "ExprIndexExpr",
		location = location,
		expr = base,
		index = StringExpression(binding.key, location),
	}
end

local function BindTableVariable(local_, scope)
	NextKey += 1
	Bindings[local_] = {
		kind = "table",
		table = scope.table,
		key = "v_" .. tostring(NextKey),
		upvalue = scope.table ~= nil and scope.tableDepth < local_.functionDepth,
	}
end

local function BindLoopVariable(local_, generated)
	Bindings[local_] = {
		kind = "direct",
		["local"] = generated,
	}
end

local TransformExpression
local TransformStatement

local function TransformBlock(block, scope)
	local body = {}
	for _, stat in block.body do
		local transformed = TransformStatement(stat, scope)
		if transformed then
			table_insert(body, transformed)
		end
	end
	return {
		kind = "StatBlock",
		location = block.location,
		body = body,
		hasEnd = block.hasEnd,
	}
end

local function TableDeclaration(tableLocal, location)
	return {
		kind = "StatLocal",
		location = location,
		vars = { tableLocal },
		values = {
			{
				kind = "ExprTable",
				location = location,
				items = {},
			},
		},
		isConst = false,
		isExported = false,
		equalsSignLocation = {},
	}
end

local function ParameterAssignment(parameters, location)
	if #parameters == 0 then
		return nil
	end

	local vars = {}
	for _, parameter in parameters do
		table_insert(vars, VariableExpression(Bindings[parameter], location, false))
	end

	return {
		kind = "StatAssign",
		location = location,
		vars = vars,
		values = {
			{
				kind = "ExprVarargs",
				location = location,
			},
		},
	}
end

local function TransformFunction(node)
	local tableLocal = NewLocal(FreshName("__luaia_vars"), node.location)
	local scope = {
		table = tableLocal,
		tableDepth = node.functionDepth or 0,
	}

	local parameters = {}
	if node.self then
		BindTableVariable(node.self, scope)
		table_insert(parameters, node.self)
	end
	for _, parameter in node.args do
		BindTableVariable(parameter, scope)
		table_insert(parameters, parameter)
	end

	local body = TransformBlock(node.body, scope)
	local prefix = { TableDeclaration(tableLocal, node.location) }
	local parameterAssignment = ParameterAssignment(parameters, node.location)
	if parameterAssignment then
		table_insert(prefix, parameterAssignment)
	end
	for _, stat in body.body do
		table_insert(prefix, stat)
	end
	body.body = prefix

	return {
		kind = "ExprFunction",
		location = node.location,
		generics = node.generics,
		genericPacks = node.genericPacks,
		args = {},
		self = nil,
		body = body,
		vararg = true,
		attributes = node.attributes,
		argLocation = node.argLocation,
		functionDepth = node.functionDepth,
		debugname = node.debugname,
	}
end

TransformExpression = function(node, scope)
	if node == nil then
		return nil
	end

	if node.kind == "ExprLocal" then
		local binding = Bindings[node["local"]]
		if binding then
			return VariableExpression(binding, node.location, node.upvalue)
		end
		return node
	elseif node.kind == "ExprFunction" then
		return TransformFunction(node)
	elseif node.kind == "ExprIndexName" then
		return {
			kind = "ExprIndexName",
			location = node.location,
			expr = TransformExpression(node.expr, scope),
			index = node.index,
			indexLocation = node.indexLocation,
			opPosition = node.opPosition,
			op = node.op,
		}
	elseif node.kind == "ExprIndexExpr" then
		return {
			kind = "ExprIndexExpr",
			location = node.location,
			expr = TransformExpression(node.expr, scope),
			index = TransformExpression(node.index, scope),
		}
	elseif node.kind == "ExprCall" then
		local args = {}
		for _, arg in node.args do
			table_insert(args, TransformExpression(arg, scope))
		end
		return {
			kind = "ExprCall",
			location = node.location,
			func = TransformExpression(node.func, scope),
			args = args,
			self = node.self,
		}
	elseif node.kind == "ExprTable" then
		local items = {}
		for _, item in node.items do
			table_insert(items, {
				kind = item.kind,
				key = item.key and TransformExpression(item.key, scope) or nil,
				value = TransformExpression(item.value, scope),
			})
		end
		return {
			kind = "ExprTable",
			location = node.location,
			items = items,
		}
	elseif node.kind == "ExprUnary" then
		return {
			kind = "ExprUnary",
			location = node.location,
			op = node.op,
			expr = TransformExpression(node.expr, scope),
		}
	elseif node.kind == "ExprBinary" then
		return {
			kind = "ExprBinary",
			location = node.location,
			op = node.op,
			left = TransformExpression(node.left, scope),
			right = TransformExpression(node.right, scope),
		}
	elseif node.kind == "ExprTypeAssertion" then
		return {
			kind = "ExprTypeAssertion",
			location = node.location,
			expr = TransformExpression(node.expr, scope),
			annotation = node.annotation,
		}
	elseif node.kind == "ExprIfElse" then
		return {
			kind = "ExprIfElse",
			location = node.location,
			condition = TransformExpression(node.condition, scope),
			trueExpr = TransformExpression(node.trueExpr, scope),
			falseExpr = TransformExpression(node.falseExpr, scope),
			hasThen = node.hasThen,
			hasElse = node.hasElse,
		}
	elseif node.kind == "ExprInterpString" then
		local expressions = {}
		for _, expression in node.expressions do
			table_insert(expressions, TransformExpression(expression, scope))
		end
		return {
			kind = "ExprInterpString",
			location = node.location,
			strings = node.strings,
			expressions = expressions,
		}
	elseif node.kind == "ExprGroup" then
		return {
			kind = "ExprGroup",
			location = node.location,
			expr = TransformExpression(node.expr, scope),
		}
	elseif node.kind == "ExprInstantiate" then
		return {
			kind = "ExprInstantiate",
			location = node.location,
			expr = TransformExpression(node.expr, scope),
		}
	end

	return node
end

local function TransformValues(values, scope)
	local result = {}
	for _, value in values do
		table_insert(result, TransformExpression(value, scope))
	end
	return result
end

local function TransformLoopBody(block, parentScope)
	local loopTable = NewLocal(FreshName("__luaia_scope"), block.location)
	local loopScope = {
		table = loopTable,
		tableDepth = parentScope.tableDepth,
	}
	local body = TransformBlock(block, loopScope)
	table_insert(body.body, 1, TableDeclaration(loopTable, block.location))
	return body, loopScope
end

TransformStatement = function(node, scope)
	if node.kind == "StatBlock" then
		return TransformBlock(node, scope)
	elseif node.kind == "StatLocal" then
		local values = TransformValues(node.values, scope)
		local vars = {}
		for _, local_ in node.vars do
			BindTableVariable(local_, scope)
			table_insert(vars, VariableExpression(Bindings[local_], node.location, false))
		end
		if #values == 0 then
			return nil
		end
		return {
			kind = "StatAssign",
			location = node.location,
			vars = vars,
			values = values,
		}
	elseif node.kind == "StatLocalFunction" then
		if node.name == nil then
			return node
		end
		BindTableVariable(node.name, scope)
		return {
			kind = "StatAssign",
			location = node.location,
			vars = { VariableExpression(Bindings[node.name], node.location, false) },
			values = { TransformFunction(node.func) },
		}
	elseif node.kind == "StatIf" then
		local elsebody = nil
		if node.elsebody then
			if node.elsebody.kind == "StatIf" then
				elsebody = TransformStatement(node.elsebody, scope)
			else
				elsebody = TransformBlock(node.elsebody, scope)
			end
		end
		return {
			kind = "StatIf",
			location = node.location,
			condition = TransformExpression(node.condition, scope),
			thenbody = TransformBlock(node.thenbody, scope),
			elsebody = elsebody,
		}
	elseif node.kind == "StatWhile" then
		local body = TransformLoopBody(node.body, scope)
		return {
			kind = "StatWhile",
			location = node.location,
			condition = TransformExpression(node.condition, scope),
			body = body,
		}
	elseif node.kind == "StatRepeat" then
		local body, bodyScope = TransformLoopBody(node.body, scope)
		return {
			kind = "StatRepeat",
			location = node.location,
			body = body,
			condition = TransformExpression(node.condition, bodyScope),
		}
	elseif node.kind == "StatFor" then
		local from = TransformExpression(node.from, scope)
		local to = TransformExpression(node.to, scope)
		local step = node.step and TransformExpression(node.step, scope) or nil
		local generated = NewLocal(FreshName("__luaia_loop"), node.var.location, node.var)
		BindLoopVariable(node.var, generated)
		local body = TransformLoopBody(node.body, scope)
		return {
			kind = "StatFor",
			location = node.location,
			var = generated,
			from = from,
			to = to,
			step = step,
			body = body,
		}
	elseif node.kind == "StatForIn" then
		local values = TransformValues(node.values, scope)
		local vars = {}
		for _, local_ in node.vars do
			local generated = NewLocal(FreshName("__luaia_loop"), local_.location, local_)
			BindLoopVariable(local_, generated)
			table_insert(vars, generated)
		end
		local body = TransformLoopBody(node.body, scope)
		return {
			kind = "StatForIn",
			location = node.location,
			vars = vars,
			values = values,
			body = body,
		}
	elseif node.kind == "StatAssign" then
		local vars = {}
		for _, variable in node.vars do
			table_insert(vars, TransformExpression(variable, scope))
		end
		return {
			kind = "StatAssign",
			location = node.location,
			vars = vars,
			values = TransformValues(node.values, scope),
		}
	elseif node.kind == "StatCompoundAssign" then
		return {
			kind = "StatCompoundAssign",
			location = node.location,
			op = node.op,
			var = TransformExpression(node.var, scope),
			value = TransformExpression(node.value, scope),
		}
	elseif node.kind == "StatReturn" then
		return {
			kind = "StatReturn",
			location = node.location,
			list = TransformValues(node.list, scope),
		}
	elseif node.kind == "StatExpr" then
		return {
			kind = "StatExpr",
			location = node.location,
			expr = TransformExpression(node.expr, scope),
		}
	elseif node.kind == "StatFunction" then
		return {
			kind = "StatFunction",
			location = node.location,
			name = TransformExpression(node.name, scope),
			func = TransformFunction(node.func),
		}
	end

	return node
end

function VariablePacker.Transform(ast)
	UsedNames = {}
	Bindings = {}
	NextKey = 0
	NextGeneratedName = 0
	CollectNames(ast, {})
	TableName = FreshName("__luaia_vars")

	local rootTable = NewLocal(TableName, ast.location)
	local rootScope = {
		table = rootTable,
		tableDepth = 0,
	}
	local body = TransformBlock(ast, rootScope)
	table_insert(body.body, 1, TableDeclaration(rootTable, ast.location))
	return body
end

return VariablePacker
