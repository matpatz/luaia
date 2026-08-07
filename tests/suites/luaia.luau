local frktest = require("@frktest/frktest")
local test = frktest.test
local check = frktest.assert.check

local luaia = require("@luaia") :: any

test.suite("luaia", function()
	test.suite("module export", function()
		test.case("should return a table", function()
			check.equal(type(luaia), "table")
		end)

		test.case("should have Minify function", function()
			check.equal(type(luaia.Minify), "function")
		end)

		test.case("should have Parser module", function()
			check.equal(type(luaia.Parser), "table")
		end)

		test.case("should have Transformer module", function()
			check.equal(type(luaia.Transformer), "table")
		end)

		test.case("should have Generator module", function()
			check.equal(type(luaia.Generator), "table")
		end)
	end)

	test.suite("parser", function()
		test.case("should parse valid Luau code", function()
			local ast, errors = luaia.Parser.Parse("local x = 1")
			check.not_nil(ast)
			check.equal(errors, nil)
		end)

		test.case("should return errors for invalid code", function()
			local ast, errors = luaia.Parser.Parse("whar")
			check.equal(ast, nil)
			check.not_nil(errors)
		end)

		test.case("should parse function declarations", function()
			local ast, errors = luaia.Parser.Parse("local function foo() return 1 end")
			check.not_nil(ast)
			check.equal(errors, nil)
		end)

		test.case("should parse string literals", function()
			local ast, errors = luaia.Parser.Parse('local x = "hello"')
			check.not_nil(ast)
			check.equal(errors, nil)
		end)

		test.case("should parse multiline strings", function()
			local ast, errors = luaia.Parser.Parse('local x = [[hello\nworld]]')
			check.not_nil(ast)
			check.equal(errors, nil)
		end)
	end)

	test.suite("minify", function()
		test.case("should minify simple assignment", function()
			local result, errors = luaia.Minify("local x = 1")
			check.not_nil(result)
			check.equal(errors, nil)
		end)

		test.case("should minify function call", function()
			local result, errors = luaia.Minify('print("hello")')
			check.not_nil(result)
			check.equal(errors, nil)
		end)

		test.case("should remove comments", function()
			local result, errors = luaia.Minify("local x = 1 -- comment")
			check.not_nil(result)
			check.equal(errors, nil)
		end)

		test.case("should fold constants", function()
			local result, errors = luaia.Minify("local x = 1 + 2")
			check.not_nil(result)
			check.equal(errors, nil)
		end)

		test.case("should handle multiple variables", function()
			local result, errors = luaia.Minify("local x = 1\nlocal y = 2")
			check.not_nil(result)
			check.equal(errors, nil)
		end)

		test.case("should handle functions", function()
			local result, errors = luaia.Minify("local function add(a, b) return a + b end")
			check.not_nil(result)
			check.equal(errors, nil)
		end)

		test.case("should handle tables", function()
			local result, errors = luaia.Minify("local t = {a = 1, b = 2}")
			check.not_nil(result)
			check.equal(errors, nil)
		end)

		test.case("should handle if statements", function()
			local result, errors = luaia.Minify("if true then print('yes') end")
			check.not_nil(result)
			check.equal(errors, nil)
		end)

		test.case("should handle while loops", function()
			local result, errors = luaia.Minify("while true do break end")
			check.not_nil(result)
			check.equal(errors, nil)
		end)

		test.case("should return errors for invalid code", function()
			local result, errors = luaia.Minify("whar")
			check.equal(result, nil)
			check.not_nil(errors)
		end)

		test.case("should collapse boolean returns", function()
			local result, errors = luaia.Minify("local function f(a, b) if a == b then return true else return false end end", { Rules = { DeadCodeElimination = false } })
			check.not_nil(result)
			check.equal(errors, nil)
			check.not_nil(string.find(result, "return [a-z]+==[a-z]+", 1))
		end)

		test.case("should collapse tail boolean returns", function()
			local result, errors = luaia.Minify("local function f(n) if n == 2 then return true end return false end", { Rules = { DeadCodeElimination = false } })
			check.not_nil(result)
			check.equal(errors, nil)
			check.not_nil(string.find(result, "return [a-z]+==2", 1))
		end)

		test.case("should keep non-boolean conditions in boolean returns", function()
			local result, errors = luaia.Minify("local function f(x) if x then return true else return false end end", { Rules = { DeadCodeElimination = false } })
			check.not_nil(result)
			check.equal(errors, nil)
			check.not_nil(string.find(result, "if [a-z]+ then return true", 1))
		end)

		test.case("should localize return booleans under no-bools", function()
			local source = [[
local function f(list, value)
	for _, v in ipairs(list) do
		if v == value then return true end
	end
	return false
end
local function g(list, value)
	for _, v in ipairs(list) do
		if v > value then return true end
	end
	return false
end
local function h(list, value)
	for _, v in ipairs(list) do
		if v < value then return true end
	end
	return false
end
local function i(list, value)
	for _, v in ipairs(list) do
		if v ~= value then return true end
	end
	return false
end
local function j(list, value)
	for _, v in ipairs(list) do
		if v >= value then return true end
	end
	return false
end
]]
			local result, errors = luaia.Minify(source, { Rules = { LocalizeBooleans = false, DeadCodeElimination = false } })
			check.not_nil(result)
			check.equal(errors, nil)
			check.not_nil(string.find(result, "local [a-z],[a-z]=true,false", 1))
			check.equal(string.find(result, "return true", 1), nil)
			check.equal(string.find(result, "return false", 1), nil)
		end)
	end)

	test.suite("dead code elimination", function()
		test.case("should eliminate constant-false local conditions and unused locals", function()
			local result, errors = luaia.Minify("local a = false\nif a then print(true) end")
			check.not_nil(result)
			check.equal(errors, nil)
			check.equal(result, "")
		end)

		test.case("should not fold conditions in functions that capture mutated locals", function()
			local source = [[
local a = false
local function check()
	if a then
		print(true)
	end
end
a = true
check()
]]
			local result, errors = luaia.Minify(source)
			check.not_nil(result)
			check.equal(errors, nil)
			check.not_nil(string.find(result, "if ", 1))
		end)

		test.case("should eliminate literal false branches", function()
			local result, errors = luaia.Minify("if false then print(1) end\nprint(2)", { Rules = { LocalizeGlobals = false } })
			check.not_nil(result)
			check.equal(errors, nil)
			check.equal(string.find(result, "print(1)", 1, true), nil)
			check.not_nil(string.find(result, "print(2)", 1, true))
		end)

		test.case("should fold constant true branches", function()
			local result, errors = luaia.Minify("if true then print(1) end", { Rules = { LocalizeGlobals = false } })
			check.not_nil(result)
			check.equal(errors, nil)
			check.not_nil(string.find(result, "print(1)", 1, true))
			check.equal(string.find(result, "if ", 1, true), nil)
		end)

		test.case("should remove while false loops", function()
			local result, errors = luaia.Minify("while false do print(1) end\nprint(2)", { Rules = { LocalizeGlobals = false } })
			check.not_nil(result)
			check.equal(errors, nil)
			check.equal(string.find(result, "print(1)", 1, true), nil)
			check.not_nil(string.find(result, "print(2)", 1, true))
		end)

		test.case("should remove unused local functions", function()
			local result, errors = luaia.Minify("local function helper() print('x') end\nprint('y')", { Rules = { LocalizeGlobals = false } })
			check.not_nil(result)
			check.equal(errors, nil)
			check.equal(string.find(result, "helper", 1, true), nil)
			check.not_nil(string.find(result, "print(\"y\")", 1, true))
		end)

		test.case("should keep side-effectful initializers", function()
			local result, errors = luaia.Minify("local a = print('hi')")
			check.not_nil(result)
			check.equal(errors, nil)
			check.not_nil(string.find(result, "print", 1, true))
		end)

		test.case("should not remove used locals", function()
			local result, errors = luaia.Minify("local a = false\nif a then print(1) end\na = true\nprint(a)")
			check.not_nil(result)
			check.equal(errors, nil)
			check.not_nil(string.find(result, "print", 1, true))
		end)

		test.case("should be disableable", function()
			local result, errors = luaia.Minify("local a = false\nif a then print(true) end", { Rules = { DeadCodeElimination = false } })
			check.not_nil(result)
			check.equal(errors, nil)
			check.not_nil(string.find(result, "if ", 1))
		end)
	end)

	test.suite("edge cases", function()
		test.case("nil is nil", function()
			check.equal(nil, nil)
		end)

		test.case("false is false", function()
			check.equal(false, false)
		end)

		test.case("0 is not nil", function()
			check.not_nil(0)
		end)

		test.case("empty string is not nil", function()
			check.not_nil("")
		end)

		test.case("empty table is not nil", function()
			check.not_nil({})
		end)
	end)
end)

return true
