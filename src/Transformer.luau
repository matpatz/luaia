local Utils = require("./utils")
local AstWalker = require("./AstWalker")

local Transformer = {}

local math_floor = math.floor
local string_find = string.find
local string_sub = string.sub
local table_clone = table.clone
local table_insert = table.insert
local table_remove = table.remove
local table_sort = table.sort

Transformer.Options = {
	Rules = {
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

-- Evaluates a constant expression node into a Lua value.
-- Returns (value, isConst). `isConst` is false when the node is not a
-- statically-known constant, so callers can distinguish `nil` (a constant)
-- from "we don't know this value".
local function EvalConstNode(node): (any, boolean)
	if node == nil or node.kind == "ExprConstantNil" then
		return nil, true
	elseif node.kind == "ExprConstantBool" then
		return node.value, true
	elseif node.kind == "ExprConstantNumber" then
		return node.value, true
	elseif node.kind == "ExprConstantInteger" then
		return node.low, true
	elseif node.kind == "ExprConstantString" then
		return node.value, true
	end
	return nil, false
end

-- Builds a constant expression node back from an evaluated Lua value.
local function BuildConstNode(location, value)
	if value == nil then
		return { kind = "ExprConstantNil", location = location }
	elseif type(value) == "boolean" then
		return { kind = "ExprConstantBool", location = location, value = value }
	elseif type(value) == "number" then
		return { kind = "ExprConstantNumber", location = location, value = value, parseResult = "Ok" }
	elseif type(value) == "string" then
		return { kind = "ExprConstantString", location = location, value = value }
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

local MinimumGlobalUses = 2

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

local function GlobalChildContext(node, field)
	if node.kind == "StatAssign" and field == "vars"
		or node.kind == "StatCompoundAssign" and field == "var"
		or node.kind == "StatFunction" and field == "name" then
		return "target"
	elseif node.kind == "ExprIndexName" and field == "expr"
		or node.kind == "ExprIndexExpr" and field == "expr"
		or node.kind == "ExprCall" and field == "func" and node.self then
		return "skip"
	end
	return "value"
end

local function WalkGlobalUses(node, _, counts, chosen, globals, mutated, mutatedBases, rewrite)
	return AstWalker.Walk(node, function(current, context)
		if rewrite then
			if context == "value" and IsLocalizableRef(current) and chosen[RefKey(current)] then
				local key = RefKey(current)
				return {
					kind = "ExprLocal",
					location = current.location,
					["local"] = {
						name = key,
						location = current.location,
						functionDepth = 0,
						loopDepth = 0,
						isConst = false,
						isExported = false,
					},
					upvalue = false,
				}
			end
		elseif context == "value" and counts and IsLocalizableRef(current) then
			local key = RefKey(current)
			counts[key] = (counts[key] or 0) + 1
		elseif context == "target" and mutated and IsLocalizableRef(current) then
			if current.kind == "ExprGlobal" then
				mutated[current.name] = true
				if mutatedBases then
					mutatedBases[current.name] = true
				end
			else
				mutated[RefKey(current)] = true
			end
		end

		if current.kind == "ExprGlobal" and globals then
			globals[current.name] = true
		end
		return current
	end, "value", GlobalChildContext)
end

local function WalkBooleanUses(node, counts, rewrite, trueName, falseName, returnsOnly, collect)
	if collect == nil then
		collect = not returnsOnly
	end
	return AstWalker.Walk(node, function(current, shouldCollect)
		if current.kind == "ExprConstantBool" then
			if shouldCollect and rewrite then
				local name = current.value and trueName or falseName
				return {
					kind = "ExprLocal",
					location = current.location,
					["local"] = {
						name = name,
						location = current.location,
						functionDepth = 0,
						loopDepth = 0,
						isConst = false,
						isExported = false,
					},
					upvalue = false,
				}
			elseif shouldCollect then
				local key = current.value and "true" or "false"
				counts[key] += 1
			end
		end
		return current
	end, collect, function(parent, field, shouldCollect)
		if parent.kind == "StatReturn" and field == "list" then
			return returnsOnly and true or shouldCollect
		end
		return shouldCollect
	end)
end

local function WalkStringUses(node, counts, rewrite, names)
	return AstWalker.Walk(node, function(current)
		if current.kind == "ExprConstantString" then
			if rewrite and names[current.value] then
				local entry = names[current.value]
				return {
					kind = "ExprIndexExpr",
					location = current.location,
					expr = {
						kind = "ExprLocal",
						location = current.location,
						["local"] = {
							name = entry.name,
							location = current.location,
							functionDepth = 0,
							loopDepth = 0,
							isConst = false,
							isExported = false,
						},
						upvalue = false,
					},
					index = {
						kind = "ExprConstantInteger",
						location = current.location,
						low = entry.index,
						high = 0,
					},
				}
			elseif not rewrite then
				counts[current.value] = (counts[current.value] or 0) + 1
			end
		end
		return current
	end)
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
		local inner = StripUnaryOperand(TransformExpression(node.expr))
		if Transformer.Options.Rules.ConstantFold then
			local v, isConst = EvalConstNode(inner)
			if isConst then
				if node.op == 0 then -- not
					return BuildConstNode(node.location, not v)
				elseif node.op == 1 and type(v) == "number" then -- unary minus
					return BuildConstNode(node.location, -v)
				elseif node.op == 2 and type(v) == "string" then -- len
					return BuildConstNode(node.location, #v)
				end
			end
		end
		return {
			kind = "ExprUnary",
			location = node.location,
			op = node.op,
			expr = inner,
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

			-- ".." on constant strings
			if node.op == 7 then
				local l, lc = EvalConstNode(left)
				local r, rc = EvalConstNode(right)
				if lc and rc and type(l) == "string" and type(r) == "string" then
					return BuildConstNode(node.location, l .. r)
				end
			end

			-- comparisons (==, ~=, <, <=, >, >=)
			if node.op >= 8 and node.op <= 13 then
				local l, lc = EvalConstNode(left)
				local r, rc = EvalConstNode(right)
				local comparable = lc and rc and type(l) == type(r)
					and (node.op <= 9 or type(l) == "number" or type(l) == "string")
				if comparable then
					local result
					if node.op == 8 then
						result = l ~= r
					elseif node.op == 9 then
						result = l == r
					elseif node.op == 10 then
						result = l < r
					elseif node.op == 11 then
						result = l <= r
					elseif node.op == 12 then
						result = l > r
					elseif node.op == 13 then
						result = l >= r
					end
					return BuildConstNode(node.location, result)
				end
			end

			-- and / or: fold when the controlling operand is a constant
			if node.op == 14 or node.op == 15 then
				local l, lc = EvalConstNode(left)
				if lc then
					local lFalsy = (l == false or l == nil)
					if (node.op == 14 and lFalsy) or (node.op == 15 and not lFalsy) then
						return left
					end
					local r, rc = EvalConstNode(right)
					if rc then
						return right
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

-- // Table Constant Folding
-- Off by default (TableConstantFolding). Treats table literals bound to locals
-- as constants when the table can never be mutated or observed from code we
-- can't rewrite. Reads like b["a"] then fold like scalar constants, so
-- `if a and b["a"] == true then` is proven always-true and unwrapped.

local DCE_UnknownField = {}

local ConstTableCandidates: { any } = {}
local ConstTableUnsafe: { any } = {}
local ConstTableSafe: { any } = {}

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

-- Like ConstExprKey but keeps the exact key semantics Lua uses at runtime:
-- string keys stay strings, so `{ ["1"] = x }` only matches `b["1"]`, not `b[1]`.
local function RawConstKey(expr)
	if expr == nil then
		return nil
	elseif expr.kind == "ExprConstantString" then
		return expr.value
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

local function ConstTableUnsafeBase(value)
	local base = ChainBaseExpr(value)
	if base and ConstTableCandidates[base["local"]] then
		ConstTableUnsafe[base["local"]] = true
	end
end

local CollectConstTableRefs

local function CollectConstTableRefsImpl(node, context)
	if type(node) ~= "table" or node.kind == nil then
		return
	end

	if node.kind == "ExprLocal" then
		if context == "escape" and ConstTableCandidates[node["local"]] then
			ConstTableUnsafe[node["local"]] = true
		end
		return
	elseif node.kind == "ExprIndexName" then
		CollectConstTableRefs(node.expr, "value")
	elseif node.kind == "ExprIndexExpr" then
		CollectConstTableRefs(node.expr, "value")
		CollectConstTableRefs(node.index, "value")
	elseif node.kind == "ExprCall" then
		if node.self then
			local base = ChainBaseExpr(node.func)
			if base and ConstTableCandidates[base["local"]] then
				ConstTableUnsafe[base["local"]] = true
			end
			CollectConstTableRefs(node.func, "value")
		else
			CollectConstTableRefs(node.func, "escape")
		end
		for _, arg in node.args do
			CollectConstTableRefs(arg, "escape")
		end
	elseif node.kind == "ExprFunction" then
		if node.body then
			CollectConstTableRefs(node.body, "value")
		end
	elseif node.kind == "ExprTable" then
		for _, item in node.items do
			if item.kind == "List" then
				CollectConstTableRefs(item.value, "value")
				ConstTableUnsafeBase(item.value)
			elseif item.kind == "Record" then
				CollectConstTableRefs(item.value, "value")
				ConstTableUnsafeBase(item.value)
			elseif item.kind == "General" then
				if item.key then
					CollectConstTableRefs(item.key, "escape")
				end
				CollectConstTableRefs(item.value, "value")
				ConstTableUnsafeBase(item.value)
			end
		end
	elseif node.kind == "ExprUnary" then
		CollectConstTableRefs(node.expr, "value")
	elseif node.kind == "ExprBinary" then
		CollectConstTableRefs(node.left, "value")
		CollectConstTableRefs(node.right, "value")
	elseif node.kind == "ExprTypeAssertion" then
		CollectConstTableRefs(node.expr, "value")
	elseif node.kind == "ExprIfElse" then
		CollectConstTableRefs(node.condition, "value")
		CollectConstTableRefs(node.trueExpr, "value")
		CollectConstTableRefs(node.falseExpr, "value")
	elseif node.kind == "ExprInterpString" then
		for _, expr in node.expressions do
			CollectConstTableRefs(expr, "value")
		end
	elseif node.kind == "ExprGroup" then
		CollectConstTableRefs(node.expr, context)
	elseif node.kind == "ExprInstantiate" then
		CollectConstTableRefs(node.expr, "value")
	elseif node.kind == "StatBlock" then
		for _, stat in node.body do
			CollectConstTableRefs(stat, "value")
		end
	elseif node.kind == "StatIf" then
		CollectConstTableRefs(node.condition, "value")
		CollectConstTableRefs(node.thenbody, "value")
		if node.elsebody then
			CollectConstTableRefs(node.elsebody, "value")
		end
	elseif node.kind == "StatWhile" then
		CollectConstTableRefs(node.condition, "value")
		CollectConstTableRefs(node.body, "value")
	elseif node.kind == "StatRepeat" then
		CollectConstTableRefs(node.body, "value")
		CollectConstTableRefs(node.condition, "value")
	elseif node.kind == "StatFor" then
		CollectConstTableRefs(node.from, "value")
		CollectConstTableRefs(node.to, "value")
		if node.step then
			CollectConstTableRefs(node.step, "value")
		end
		CollectConstTableRefs(node.body, "value")
	elseif node.kind == "StatForIn" then
		for _, value in node.values do
			CollectConstTableRefs(value, "value")
		end
		CollectConstTableRefs(node.body, "value")
	elseif node.kind == "StatLocal" then
		for i, var in node.vars do
			local value = node.values[i]
			if value ~= nil then
				local v = value
				while v.kind == "ExprGroup" do
					v = v.expr
				end
				if v.kind == "ExprTable" and not ConstTableCandidates[var] then
					ConstTableCandidates[var] = true
				end
			end
		end
		for _, value in node.values do
			CollectConstTableRefs(value, "value")
		end
		for _, value in node.values do
			ConstTableUnsafeBase(value)
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
				if ConstTableCandidates[target["local"]] then
					ConstTableUnsafe[target["local"]] = true
				end
			else
				ConstTableUnsafeBase(target)
			end
		end
		local valueContext = allLocal and "value" or "escape"
		for _, value in node.values do
			CollectConstTableRefs(value, valueContext)
		end
		if allLocal then
			for _, value in node.values do
				ConstTableUnsafeBase(value)
			end
		end
	elseif node.kind == "StatCompoundAssign" then
		ConstTableUnsafeBase(node.var)
		CollectConstTableRefs(node.var, "value")
		CollectConstTableRefs(node.value, "value")
	elseif node.kind == "StatReturn" then
		for _, value in node.list do
			CollectConstTableRefs(value, "escape")
		end
	elseif node.kind == "StatExpr" then
		CollectConstTableRefs(node.expr, "value")
	elseif node.kind == "StatFunction" then
		CollectConstTableRefs(node.name, "value")
		CollectConstTableRefs(node.func, "value")
	elseif node.kind == "StatLocalFunction" then
		CollectConstTableRefs(node.func, "value")
	end
end

CollectConstTableRefs = CollectConstTableRefsImpl

local function CollectConstTableSafety(ast)
	ConstTableCandidates = {}
	ConstTableUnsafe = {}
	CollectConstTableRefs(ast, "value")
	local safe = {}
	for var in pairs(ConstTableCandidates) do
		if not ConstTableUnsafe[var] then
			safe[var] = true
		end
	end
	return safe
end

local DCEEvalConst

local function DCEMakeConstTable(entries)
	return {
		isConstTable = true,
		entries = entries,
	}
end

local function DCETableConstFromExpr(node, env, allowTable)
	if not allowTable or node.kind ~= "ExprTable" then
		return nil
	end
	local entries = {}
	local index = 1
	for _, item in node.items do
		local key
		if item.kind == "List" then
			key = index
			index += 1
		elseif item.kind == "Record" then
			key = item.key.value
		elseif item.kind == "General" then
			if item.key == nil then
				key = index
				index += 1
			else
				local k = RawConstKey(item.key)
				if k == nil then
					return nil
				end
				key = k
			end
		end
		local v = DCEEvalConst(item.value, env, allowTable)
		if v == nil then
			entries[key] = DCE_UnknownField
		else
			entries[key] = v
		end
	end
	return DCEMakeConstTable(entries)
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
-- allowTable additionally permits constant evaluation of immutable table
-- literals and reads of their fields (see TableConstantFolding).
DCEEvalConst = function(node, env, allowTable): any
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
		return DCEEvalConst(node.expr, env, allowTable)
	elseif node.kind == "ExprUnary" then
		if node.op == 0 then -- not
			local v = DCEEvalConst(node.expr, env, allowTable)
			if v == nil then
				return nil
			end
			if v == false or v == DCE_NilConst then
				return true
			end
			return false
		end
	elseif node.kind == "ExprIndexName" then
		if allowTable then
			local base = DCEEvalConst(node.expr, env, allowTable)
			if type(base) == "table" and base.isConstTable then
				local v = base.entries[node.index]
				if v == DCE_UnknownField then
					return nil
				end
				if v == nil then
					return DCE_NilConst
				end
				return v
			end
		end
		return nil
	elseif node.kind == "ExprIndexExpr" then
		if allowTable then
			local base = DCEEvalConst(node.expr, env, allowTable)
			if type(base) == "table" and base.isConstTable then
				local key = RawConstKey(node.index)
				if key ~= nil then
					local v = base.entries[key]
					if v == DCE_UnknownField then
						return nil
					end
					if v == nil then
						return DCE_NilConst
					end
					return v
				end
			end
		end
		return nil
	elseif node.kind == "ExprBinary" then
		if node.op == 8 or node.op == 9 then -- ~=, ==
			local l = DCEEvalConst(node.left, env, allowTable)
			local r = DCEEvalConst(node.right, env, allowTable)
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
			local l = DCEEvalConst(node.left, env, allowTable)
			if l == nil then
				return nil
			end
			local lFalsy = (l == false or l == DCE_NilConst)
			if node.op == 14 then
				if lFalsy then
					return l
				end
				return DCEEvalConst(node.right, env, allowTable)
			else
				if lFalsy then
					return DCEEvalConst(node.right, env, allowTable)
				end
				return l
			end
		elseif node.op == 7 then -- ..
			local l = DCEEvalConst(node.left, env, allowTable)
			local r = DCEEvalConst(node.right, env, allowTable)
			if type(l) == "string" and type(r) == "string" then
				return l .. r
			end
			return nil
		elseif node.op >= 10 and node.op <= 13 then -- comparisons
			local l = DCEEvalConst(node.left, env, allowTable)
			local r = DCEEvalConst(node.right, env, allowTable)
			if type(l) == "number" and type(r) == "number" then
				if node.op == 10 then return l < r
				elseif node.op == 11 then return l <= r
				elseif node.op == 12 then return l > r
				elseif node.op == 13 then return l >= r end
			end
			return nil
		else
			local l = DCEEvalConst(node.left, env, allowTable)
			local r = DCEEvalConst(node.right, env, allowTable)
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
	elseif node.kind == "ExprTable" then
		return DCETableConstFromExpr(node, env, allowTable)
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

local DCECollectAssigned
-- Branch folding asks for assignment sets after processing the same blocks.
-- Cache the structure-only result for the lifetime of one transform.
local DCEAssignedCache: { [any]: { [any]: boolean } } = {}

local function DCECollectAssignedImpl(node, assigned)
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

DCECollectAssigned = function(node, assigned)
	local cached = DCEAssignedCache[node]
	if cached then
		for localName in cached do
			assigned[localName] = true
		end
		return
	end

	local collected = {}
	DCECollectAssignedImpl(node, collected)
	DCEAssignedCache[node] = collected
	for localName in collected do
		assigned[localName] = true
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
	local c = DCEEvalConst(stat.condition, env, true)
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
		local c = DCEEvalConst(stat.condition, env, true)
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
		local c = DCEEvalConst(stat.condition, bodyEnv, true)
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
				if ConstTableSafe[var] then
					env[var] = DCEEvalConst(stat.values[i], env, true)
				else
					env[var] = DCEEvalConst(stat.values[i], env, false)
				end
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
					newBindings[target["local"]] = DCEEvalConst(stat.values[i], env, false)
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
local TableKeyFamily: { any } = {}

-- Resolves a chain expression (the base of an index) down to the map of the
-- table that a dynamic key would read. Returns the root local and the map; the
-- map is the root map when the dynamic key indexes the root table directly.
local function ResolveChainMap(chainExpr)
	local base = ChainBaseExpr(chainExpr)
	if base == nil then
		return nil, nil
	end
	local var = base["local"]
	local map = TableKeyMaps[var]
	if map == nil then
		return nil, nil
	end
	local m = map
	local e = chainExpr
	while e ~= nil and e ~= base do
		if e.kind == "ExprGroup" then
			e = e.expr
		elseif e.kind == "ExprIndexName" then
			local entry = m and m[e.index]
			if entry == nil then
				return var, nil
			end
			m = entry.sub
			e = e.expr
		elseif e.kind == "ExprIndexExpr" then
			local k = ConstExprKey(e.index)
			if k == nil then
				return var, m
			end
			local entry = m and m[k]
			if entry == nil then
				return var, nil
			end
			m = entry.sub
			e = e.expr
		else
			break
		end
	end
	return var, m
end

-- When a table is reached through a dynamic index (b[k], b.sub[k]), its own
-- keys can't be rewritten so they keep their names. But the tables stored in
-- it are still renameable if every one of them renames a field the same way:
-- a "family map" merges the sub-maps of every entry so shared fields map to a
-- single generated name. All the family's literals and every access through
-- the dynamic dispatch are rewritten with that one map.
local function BuildFamilyMap(m)
	if TableKeyFamily[m] then
		return TableKeyFamily[m]
	end
	local subs = {}
	for _, entry in pairs(m) do
		if entry.sub then
			subs[#subs + 1] = entry.sub
		end
	end
	local family = {}
	for _, sub in subs do
		for field in pairs(sub) do
			if not family[field] then
				family[field] = { name = NameGenerator:Generate() }
			end
		end
	end
	for _, entry in pairs(m) do
		if entry.sub then
			entry.sub = family
		end
	end
	TableKeyFamily[m] = family
	return family
end

local function MarkFamilyIndexed(chainExpr)
	local var, m = ResolveChainMap(chainExpr)
	if var == nil then
		return
	end
	if m == nil then
		-- Unresolvable chain: be conservative and skip the root table entirely.
		TableKeyEscaped[var] = true
	elseif m == TableKeyMaps[var] then
		-- Root table indexed dynamically: keys stay, stored tables family-rename.
		BuildFamilyMap(m)
	else
		BuildFamilyMap(m)
	end
end

-- If `value` is a dynamic read out of a family-indexed table (like `bq.v[id]`),
-- returns the family map its result uses, so aliases (`local x = {v = bq.v[id]}`)
-- can keep rewriting field accesses on the aliased table.
local function ResolveFamily(value)
	while value ~= nil and value.kind == "ExprGroup" do
		value = value.expr
	end
	if value ~= nil and value.kind == "ExprIndexExpr" and ConstExprKey(value.index) == nil then
		local _, m = ResolveChainMap(value.expr)
		if m and TableKeyFamily[m] then
			return TableKeyFamily[m]
		end
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
		if ConstExprKey(node.index) == nil then
			MarkFamilyIndexed(node.expr)
		end
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
		for i, var in node.vars do
			local value = node.values[i]
			if value == nil then
				continue
			end
			if value.kind == "ExprTable" and TableKeyMaps[var] then
				for _, item in value.items do
					local key
					if item.kind == "Record" then
						key = item.key.value
					elseif item.kind == "General" and item.key then
						key = ConstExprKey(item.key)
					else
						continue
					end
					if key ~= nil then
						local entry = TableKeyMaps[var][key]
						local family = entry and ResolveFamily(item.value)
						if family then
							entry.sub = family
						end
					end
				end
			else
				local family = ResolveFamily(value)
				if family and not TableKeyCandidates[var] then
					-- a local directly holding a table from the family
					TableKeyCandidates[var] = value
					TableKeyMaps[var] = family
				end
			end
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
	local family = TableKeyFamily[map]
	for _, item in tableNode.items do
		if item.kind == "List" then
			if family and item.value and item.value.kind == "ExprTable" then
				RewriteTableLiteralKeys(item.value, family)
			end
		elseif item.kind == "Record" then
			local entry = map[item.key.value]
			if entry then
				if not family then
					item.key.value = entry.name
				end
				if entry.sub and item.value and item.value.kind == "ExprTable" then
					RewriteTableLiteralKeys(item.value, entry.sub)
				end
			end
		elseif item.kind == "General" and item.key then
			local k = ConstExprKey(item.key)
			local entry = k ~= nil and map[k]
			if entry then
				if not family then
					item.key = {
						kind = "ExprConstantString",
						location = item.key.location,
						value = entry.name,
					}
				end
				if entry.sub and item.value and item.value.kind == "ExprTable" then
					RewriteTableLiteralKeys(item.value, entry.sub)
				end
			elseif family and item.value and item.value.kind == "ExprTable" then
				-- a family member under a key we can't map (e.g. a dynamic key):
				-- its fields are still renamed with the shared family map
				RewriteTableLiteralKeys(item.value, family)
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
				-- dynamic key: fields of the table it resolves to are family-renamed
				return TableKeyFamily[sub]
			end
		end
		local entry = sub[k]
		if entry == nil then
			return nil
		end
		if not TableKeyFamily[sub] then
			if node.kind == "ExprIndexName" then
				node.index = entry.name
			else
				node.index = {
					kind = "ExprConstantString",
					location = node.index.location,
					value = entry.name,
				}
			end
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
	TableKeyFamily = {}

	CollectTableKeyRefs(ast, "value")

	for var in pairs(TableKeyCandidates) do
		if TableKeyMutated[var] or TableKeyEscaped[var] then
			TableKeyMaps[var] = nil
		end
	end

	RewriteTableKeyPass(ast)
end

-- // Inline constant locals
--
-- Locals bound to a constant expression (side-effect free and deterministic)
-- are inlined into every use site and their declaration is dropped, so they
-- "fold into non-existence". This is safe because a constant value can be
-- duplicated and moved freely — the later constant-fold pass collapses each
-- copy back into a literal.

local InlineChildFields = {
	List = { "value" },
	Record = { "value" },
	General = { "key", "value" },
	ExprIndexName = { "expr" },
	ExprIndexExpr = { "expr", "index" },
	ExprCall = { "func", "args" },
	ExprFunction = { "body" },
	ExprTable = { "items" },
	ExprUnary = { "expr" },
	ExprBinary = { "left", "right" },
	ExprTypeAssertion = { "expr" },
	ExprIfElse = { "condition", "trueExpr", "falseExpr" },
	ExprInterpString = { "expressions" },
	ExprGroup = { "expr" },
	ExprInstantiate = { "expr" },
	StatBlock = { "body" },
	StatIf = { "condition", "thenbody", "elsebody" },
	StatWhile = { "condition", "body" },
	StatRepeat = { "body", "condition" },
	StatFor = { "from", "to", "step", "body" },
	StatForIn = { "values", "body" },
	StatLocal = { "values" },
	StatAssign = { "vars", "values" },
	StatCompoundAssign = { "var", "value" },
	StatReturn = { "list" },
	StatExpr = { "expr" },
	StatFunction = { "name", "func" },
	StatLocalFunction = { "func" },
}

-- True when `node` is a constant expression: side-effect free, deterministic,
-- and safe to duplicate and move anywhere.
local function IsInlineableConst(node, constSet): boolean
	if type(node) ~= "table" or node.kind == nil then
		return false
	end
	if node.kind == "ExprConstantNil" or node.kind == "ExprConstantBool"
		or node.kind == "ExprConstantNumber" or node.kind == "ExprConstantInteger"
		or node.kind == "ExprConstantString" then
		return true
	elseif node.kind == "ExprLocal" then
		return constSet[node["local"]] == true
	elseif node.kind == "ExprGroup" then
		return IsInlineableConst(node.expr, constSet)
	elseif node.kind == "ExprUnary" then
		return IsInlineableConst(node.expr, constSet)
	elseif node.kind == "ExprBinary" then
		return IsInlineableConst(node.left, constSet)
			and IsInlineableConst(node.right, constSet)
	elseif node.kind == "ExprTypeAssertion" then
		return IsInlineableConst(node.expr, constSet)
	elseif node.kind == "ExprIfElse" then
		return IsInlineableConst(node.condition, constSet)
			and IsInlineableConst(node.trueExpr, constSet)
			and IsInlineableConst(node.falseExpr, constSet)
	elseif node.kind == "ExprInterpString" then
		for _, part in node.expressions do
			if not IsInlineableConst(part, constSet) then
				return false
			end
		end
		return true
	end
	return false
end

-- True when `block` (or any nested block / function) assigns to `target`.
local function LocalIsAssigned(block, target): boolean
	local found = false
	AstWalker.Walk(block, function(current)
		if found then
			return current
		end
		if current.kind == "StatAssign" then
			for _, v in current.vars do
				if v.kind == "ExprLocal" and v["local"] == target then
					found = true
					break
				end
			end
		elseif current.kind == "StatCompoundAssign" then
			local v = current.var
			if v.kind == "ExprLocal" and v["local"] == target then
				found = true
			end
		end
		return current
	end)
	return found
end

local function CloneNode(node)
	if type(node) ~= "table" then
		return node
	end
	local clone = {}
	for k, v in node do
		if k == "local" and node.kind == "ExprLocal" then
			clone[k] = v
		else
			clone[k] = CloneNode(v)
		end
	end
	return clone
end

-- Replaces every reference to `target` inside `node` (in place) with a fresh
-- clone of `replacement`.
local function ReplaceLocalUses(node, target, replacement)
	return AstWalker.Walk(node, function(current)
		if current.kind == "ExprLocal" and current["local"] == target then
			return CloneNode(replacement)
		end
		return current
	end)
end

local ProcessNode: (any) -> ()

-- Inlines constant locals declared directly in `block`, then recurses into
-- nested blocks and function bodies.
local function InlineBlock(block)
	-- Compute the set of constant locals. The "never reassigned" check is
	-- folded into constness so a reassigned local is never inlined, even if
	-- its initial value was a constant (a later use could observe the new
	-- value).
	local constSet = {}
	local candidates = {}
	for _, stat in block.body do
		if stat.kind == "StatLocal" and #stat.vars == 1 and #stat.values == 1
			and not stat.vars[1].isExported then
			table_insert(candidates, stat)
		end
	end

	local changed = true
	while changed do
		changed = false
		for _, stat in candidates do
			local var = stat.vars[1]
			if not constSet[var]
				and not LocalIsAssigned(block, var)
				and IsInlineableConst(stat.values[1], constSet) then
				constSet[var] = true
				changed = true
			end
		end
	end

	-- Inline in source order: any referenced constant is declared earlier and
	-- has already been substituted, so the value we splice in is literal.
	local body = block.body
	local i = 1
	while i <= #body do
		local stat = body[i]
		if stat.kind == "StatLocal" and #stat.vars == 1 and #stat.values == 1 then
			local var = stat.vars[1]
			if constSet[var] then
				ReplaceLocalUses(block, var, stat.values[1])
				table_remove(body, i)
			else
				i += 1
			end
		else
			i += 1
		end
	end

	-- Recurse into nested blocks / function bodies.
	for _, stat in block.body do
		ProcessNode(stat)
	end
end

ProcessNode = function(node)
	if type(node) ~= "table" or node.kind == nil then
		return
	end
	if node.kind == "StatBlock" then
		InlineBlock(node)
		return
	elseif node.kind == "ExprFunction" then
		InlineBlock(node.body)
		return
	elseif node.kind == "StatFunction" or node.kind == "StatLocalFunction" then
		InlineBlock(node.func.body)
		return
	end
	for _, field in InlineChildFields[node.kind] or {} do
		local child = node[field]
		if type(child) == "table" then
			if child.kind ~= nil then
				ProcessNode(child)
			else
				for _, item in child do
					ProcessNode(item)
				end
			end
		end
	end
end

local function RunInlineSingleUse(ast)
	InlineBlock(ast)
end

function Transformer.Transform(ast)
	VariableMap = {}
	NameGenerator:Reset()
	DCEAssignedCache = {}

	if Transformer.Options.Rules.DeadCodeElimination then
		if Transformer.Options.Rules.TableConstantFolding then
			ConstTableSafe = CollectConstTableSafety(ast)
		else
			ConstTableSafe = {}
		end
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

	if Transformer.Options.Rules.InlineSingleUse then
		RunInlineSingleUse(ast)
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

	local function LocalizeStrings(ast)
		local counts = {}
		WalkStringUses(ast, counts, false, nil)

		local values = {}
		for value, count in pairs(counts) do
			if count > 3 then
				table_insert(values, value)
			end
		end
		if #values == 0 then
			return
		end
		table_sort(values)

		local names = {}
		local tableName = "Strings"
		local tableItems = {}
		local loc = { begin = { x = 0, y = 0 }, end_ = { x = 0, y = 0 } }
		for i, value in values do
			names[value] = { name = tableName, index = i }
			table_insert(tableItems, {
				kind = "List",
				value = {
					kind = "ExprConstantString",
					location = loc,
					value = value,
					quoteStyle = 0,
				},
			})
		end

		VariableMap[tableName] = NameGenerator:Generate()
		WalkStringUses(ast, counts, true, names)
		table_insert(ast.body, 1, {
			kind = "StatLocal",
			location = loc,
			vars = {
				{
					name = tableName,
					location = loc,
					functionDepth = 0,
					loopDepth = 0,
					isConst = false,
					isExported = false,
				},
			},
			values = {
				{
					kind = "ExprTable",
					location = loc,
					items = tableItems,
				},
			},
			isConst = false,
			isExported = false,
			equalsSignLocation = {},
		})
	end

	if Transformer.Options.Rules.LocalizeBooleans then
		LocalizeBools(ast, false)
	else
		LocalizeBools(ast, true)
	end

	if Transformer.Options.Rules.LocalizeStrings then
		LocalizeStrings(ast)
	end

	if Transformer.Options.Rules.RenameTableKeys then
		TransformTableKeys(ast)
	end

	ast = TransformStatementBlock(ast)

	return ast
end

return Transformer
