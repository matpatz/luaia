local AstWalker = {}

local Children = {
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

function AstWalker.Walk(node, visit, context, childContext)
	if type(node) ~= "table" or node.kind == nil then
		return node
	end

	local replacement = visit(node, context)
	if replacement ~= node then
		return replacement
	end

	for _, field in Children[node.kind] or {} do
		local child = node[field]
		if type(child) == "table" then
			local nextContext = context
			if childContext then
				nextContext = childContext(node, field, context)
			end
			if child.kind ~= nil then
				node[field] = AstWalker.Walk(child, visit, nextContext, childContext)
			else
				for i, value in child do
					child[i] = AstWalker.Walk(value, visit, nextContext, childContext)
				end
			end
		end
	end

	return node
end

return AstWalker
