local Utils = require("./utils")

local Generator = {}

local indent = 0
local output = {}

local function Emit(str: string)
	table.insert(output, str)
end

local function GenerateExpression(node): string
	if node == nil then
		return "nil"
	end
	if node.kind == "ExprConstantNil" then
		return "nil"
	elseif node.kind == "ExprConstantBool" then
		return if node.value then "true" else "false"
	elseif node.kind == "ExprConstantNumber" then
		return Utils.NumberToString(node.value)
	elseif node.kind == "ExprConstantInteger" then
		return tostring(node.low)
	elseif node.kind == "ExprConstantString" then
		local escaped = node.value
		escaped = string.gsub(escaped, "\\", "\\\\")
		escaped = string.gsub(escaped, '"', '\\"')
		escaped = string.gsub(escaped, "\n", "\\n")
		escaped = string.gsub(escaped, "\r", "\\r")
		escaped = string.gsub(escaped, "\t", "\\t")
		escaped = string.gsub(escaped, "\0", "\\0")
		return '"' .. escaped .. '"'
	elseif node.kind == "ExprLocal" then
		return node["local"].name
	elseif node.kind == "ExprGlobal" then
		return node.name
	elseif node.kind == "ExprVarargs" then
		return "..."
	elseif node.kind == "ExprCall" then
		local func
		local args = {}
		for _, arg in node.args do
			table.insert(args, GenerateExpression(arg))
		end
		if node.self and node.func.kind == "ExprIndexName" then
			func = GenerateExpression(node.func.expr) .. ":" .. node.func.index
		else
			func = GenerateExpression(node.func)
		end
		return func .. "(" .. table.concat(args, ",") .. ")"
	elseif node.kind == "ExprIndexName" then
		return GenerateExpression(node.expr) .. "." .. node.index
	elseif node.kind == "ExprIndexExpr" then
		return GenerateExpression(node.expr) .. "[" .. GenerateExpression(node.index) .. "]"
	elseif node.kind == "ExprFunction" then
		local params = {}
		if node.self then
			table.insert(params, node.self.name)
		end
		for _, param in node.args do
			table.insert(params, param.name)
		end
		if node.vararg then
			table.insert(params, "...")
		end
		return "function(" .. table.concat(params, ",") .. ") " .. GenerateBlock(node.body) .. "end"
	elseif node.kind == "ExprTable" then
		local items = {}
		for _, item in node.items do
			if item.kind == "List" then
				table.insert(items, GenerateExpression(item.value))
			elseif item.kind == "Record" then
				table.insert(items, item.key.value .. "=" .. GenerateExpression(item.value))
			elseif item.kind == "General" then
				if item.key then
					table.insert(items, "[" .. GenerateExpression(item.key) .. "]=" .. GenerateExpression(item.value))
				else
					table.insert(items, GenerateExpression(item.value))
				end
			end
		end
		return "{" .. table.concat(items, ",") .. "}"
	elseif node.kind == "ExprUnary" then
		local op = ""
		if node.op == 0 then
			op = "not "
		elseif node.op == 1 then
			op = "-"
		elseif node.op == 2 then
			op = "#"
		end
		return op .. GenerateExpression(node.operand)
	elseif node.kind == "ExprBinary" then
		local opMap = {
			[0] = "+", [1] = "-", [2] = "*", [3] = "/", [4] = "//",
			[5] = "%", [6] = "^", [7] = "..", [8] = "~=", [9] = "==",
			[10] = "<", [11] = "<=", [12] = ">", [13] = ">=",
			[14] = " and ", [15] = " or ",
		}
		local op = opMap[node.op] or " "
		return GenerateExpression(node.left) .. op .. GenerateExpression(node.right)
	elseif node.kind == "ExprTypeAssertion" then
		return GenerateExpression(node.expr) .. "::" .. GenerateType(node.type)
	elseif node.kind == "ExprIfElse" then
		local cond = GenerateExpression(node.condition)
		local thenExpr = GenerateExpression(node.thenExpr)
		local elseExpr = GenerateExpression(node.elseExpr)
		return "if " .. cond .. " then " .. thenExpr .. " else " .. elseExpr
	elseif node.kind == "ExprInterpString" then
		local parts = {}
		for i, str in node.strings do
			local escaped = str
			escaped = string.gsub(escaped, "\\", "\\\\")
			escaped = string.gsub(escaped, "`", "\\`")
			escaped = string.gsub(escaped, "{", "\\{")
			escaped = string.gsub(escaped, "}", "\\}")
			escaped = string.gsub(escaped, "\n", "\\n")
			escaped = string.gsub(escaped, "\r", "\\r")
			escaped = string.gsub(escaped, "\t", "\\t")
			escaped = string.gsub(escaped, "\0", "\\0")
			table.insert(parts, escaped)
			if i <= #node.expressions then
				table.insert(parts, "{" .. GenerateExpression(node.expressions[i]) .. "}")
			end
		end
		return "`" .. table.concat(parts) .. "`"
	elseif node.kind == "ExprGroup" then
		return "(" .. GenerateExpression(node.expr) .. ")"
	elseif node.kind == "ExprInstantiate" then
		return GenerateExpression(node.expr) .. "<" .. ">"
	elseif node.kind == "ExprError" then
		return "<error>"
	end

	return "<unknown>"
end

local function GenerateType(node): string
	if node.kind == "TypeReference" then
		if node.package then
			return node.package .. "." .. node.name
		end
		return node.name
	elseif node.kind == "TypeTable" then
		return "{}"
	elseif node.kind == "TypeFunction" then
		return "function"
	elseif node.kind == "TypeTypeof" then
		return "typeof(" .. GenerateExpression(node.expr) .. ")"
	elseif node.kind == "TypeUnion" then
		return GenerateType(node.left) .. "|" .. GenerateType(node.right)
	elseif node.kind == "TypeIntersection" then
		return GenerateType(node.left) .. "&" .. GenerateType(node.right)
	elseif node.kind == "TypeSingletonBool" then
		return if node.value then "true" else "false"
	elseif node.kind == "TypeSingletonString" then
		return '"' .. node.value .. '"'
	elseif node.kind == "TypeOptional" then
		return "?"
	elseif node.kind == "TypeGroup" then
		return "(" .. GenerateType(node.type) .. ")"
	elseif node.kind == "TypeError" then
		return "<error>"
	end

	return "<unknown>"
end

local function GenerateStat(node): string
	if node.kind == "StatBlock" then
		if node.hasEnd then
			return "do " .. GenerateBlock(node) .. "end"
		else
			return GenerateBlock(node)
		end
	elseif node.kind == "StatIf" then
		local parts = {}
		table.insert(parts, "if " .. GenerateExpression(node.condition) .. " then ")
		table.insert(parts, GenerateBlock(node.thenbody))
		local elseNode = node.elsebody
		while elseNode do
			if elseNode.kind == "StatIf" then
				table.insert(parts, "elseif " .. GenerateExpression(elseNode.condition) .. " then ")
				table.insert(parts, GenerateBlock(elseNode.thenbody))
				elseNode = elseNode.elsebody
			elseif elseNode.kind == "StatBlock" then
				table.insert(parts, "else ")
				table.insert(parts, GenerateBlock(elseNode))
				elseNode = nil
			else
				elseNode = nil
			end
		end
		table.insert(parts, "end")
		return table.concat(parts, "")
	elseif node.kind == "StatWhile" then
		return "while " .. GenerateExpression(node.condition) .. " do " .. GenerateBlock(node.body) .. "end"
	elseif node.kind == "StatRepeat" then
		return "repeat " .. GenerateBlock(node.body) .. "until " .. GenerateExpression(node.condition)
	elseif node.kind == "StatBreak" then
		return "break"
	elseif node.kind == "StatContinue" then
		return "continue"
	elseif node.kind == "StatReturn" then
		local values = {}
		for _, value in node.list do
			table.insert(values, GenerateExpression(value))
		end
		if #values > 0 then
			return "return " .. table.concat(values, ",")
		else
			return "return"
		end
	elseif node.kind == "StatExpr" then
		return GenerateExpression(node.expr)
	elseif node.kind == "StatLocal" then
		local names = {}
		for _, name in node.vars do
			table.insert(names, name.name)
		end
		local values = {}
		for _, value in node.values do
			table.insert(values, GenerateExpression(value))
		end
		if #values > 0 then
			return "local " .. table.concat(names, ",") .. "=" .. table.concat(values, ",")
		else
			return "local " .. table.concat(names, ",")
		end
	elseif node.kind == "StatFor" then
		return "for " .. node.var.name .. "=" .. GenerateExpression(node.from) .. "," .. GenerateExpression(node.to) .. "," .. (node.step and GenerateExpression(node.step) or "1") .. " do " .. GenerateBlock(node.body) .. "end"
	elseif node.kind == "StatForIn" then
		local names = {}
		for _, name in node.vars do
			table.insert(names, name.name)
		end
		local values = {}
		for _, value in node.values do
			table.insert(values, GenerateExpression(value))
		end
		return "for " .. table.concat(names, ",") .. " in " .. table.concat(values, ",") .. " do " .. GenerateBlock(node.body) .. "end"
	elseif node.kind == "StatAssign" then
		local targets = {}
		for _, target in node.vars do
			table.insert(targets, GenerateExpression(target))
		end
		local values = {}
		for _, value in node.values do
			table.insert(values, GenerateExpression(value))
		end
		return table.concat(targets, ",") .. "=" .. table.concat(values, ",")
	elseif node.kind == "StatCompoundAssign" then
		local op = ""
		if node.op == 0 then
			op = "+="
		elseif node.op == 1 then
			op = "-="
		elseif node.op == 2 then
			op = "*="
		elseif node.op == 3 then
			op = "/="
		elseif node.op == 4 then
			op = "//="
		elseif node.op == 5 then
			op = "%="
		elseif node.op == 6 then
			op = "^="
		elseif node.op == 7 then
			op = "..="
		end
		return GenerateExpression(node.var) .. op .. GenerateExpression(node.value)
	elseif node.kind == "StatFunction" then
		local func = GenerateExpression(node.func)
		return GenerateExpression(node.name) .. "=" .. func
	elseif node.kind == "StatLocalFunction" then
		local func = GenerateExpression(node.func)
		return "local " .. node.name.name .. "=" .. func
	elseif node.kind == "StatTypeAlias" then
		return "type " .. node.name.value .. "=" .. GenerateType(node.type)
	elseif node.kind == "StatTypeFunction" then
		return "type " .. node.name.value .. "=" .. GenerateType(node.type)
	elseif node.kind == "StatDeclareGlobal" then
		return "declare " .. node.name.value .. ":" .. GenerateType(node.type)
	elseif node.kind == "StatDeclareFunction" then
		return "declare function " .. node.name.value .. "()"
	elseif node.kind == "StatDeclareExternType" then
		return "declare " .. node.name.value
	elseif node.kind == "StatClass" then
		return "type " .. node.name.value .. "=" .. "{}"
	elseif node.kind == "StatError" then
		return "<error>"
	end

	return "<unknown>"
end

function GenerateBlock(node): string
	local savedOutput = output
	output = {}

	for _, stat in node.body do
		Emit(GenerateStat(stat))
		local last = output[#output]
		if not string.match(last, ";$") then
			Emit(";")
		end
	end

	local result = table.concat(output, "")
	output = savedOutput
	return result
end

function Generator.Generate(ast): string
	output = {}
	indent = 0

	local result = GenerateBlock(ast)
	return result
end

return Generator
