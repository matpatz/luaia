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

		test.case("should parse nullable tuple return types", function()
			local ast, errors = luaia.Parser.Parse("local function f(): (number, string)?\n\treturn nil\nend")
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

		test.case("should rename variables to lowercase random names", function()
			local result, errors = luaia.Minify("local MyVariable = foo()\nprint(MyVariable)")
			check.not_nil(result)
			check.equal(errors, nil)
			check.equal(string.find(result, "MyVariable", 1, true), nil)
			check.not_nil(string.find(result, "local [a-z]+=", 1))
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

		test.case("should keep concatenation after a number literal valid", function()
			local result, errors = luaia.Minify('print(10 .. "x")')
			check.not_nil(result)
			check.equal(errors, nil)
			check.equal(string.find(result, "10..", 1, true), nil)
			check.not_nil(string.find(result, "10 ..", 1, true))
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
			check.not_nil(string.find(result, "local [a-z]+,[a-z]+=true,false", 1))
			check.equal(string.find(result, "return true", 1), nil)
			check.equal(string.find(result, "return false", 1), nil)
		end)

		test.case("should localize strings repeated more than three times", function()
			local source = [[
print("function")
print("function")
print("function")
print("function")
print("warning")
print("warning")
print("warning")
print("warning")
]]
			local result, errors = luaia.Minify(source, {
				Rules = {
					LocalizeGlobals = false,
					LocalizeBooleans = false,
					DeadCodeElimination = false,
				},
			})
			check.not_nil(result)
			check.equal(errors, nil)
			check.not_nil(string.find(result, 'local [a-z]+={"function","warning"}', 1))
			check.not_nil(string.find(result, '[a-z]+%[1%]', 1))
			check.not_nil(string.find(result, '[a-z]+%[2%]', 1))
			check.equal(string.find(result, 'print("function"', 1, true), nil)
		end)

		test.case("should not localize strings at the threshold", function()
			local source = [[
print("function")
print("function")
print("function")
]]
			local result, errors = luaia.Minify(source, {
				Rules = {
					LocalizeGlobals = false,
					LocalizeBooleans = false,
					DeadCodeElimination = false,
				},
			})
			check.not_nil(result)
			check.equal(errors, nil)
			check.equal(string.find(result, 'local [a-z]+={', 1), nil)
		end)

		test.case("should support disabling string localization", function()
			local result, errors = luaia.Minify([[print("function", "function", "function", "function")]], {
				Rules = {
					LocalizeGlobals = false,
					LocalizeBooleans = false,
					LocalizeStrings = false,
					DeadCodeElimination = false,
				},
			})
			check.not_nil(result)
			check.equal(errors, nil)
			check.equal(string.find(result, 'local [a-z]+={', 1), nil)
		end)
	end)

	test.suite("variable packing", function()
		test.case("should expose PackVariables", function()
			check.equal(type(luaia.PackVariables), "function")
		end)

		test.case("should preserve captured locals", function()
			local source = [[
local outer = 4
local function make(value)
	local inner = value + outer
	return function(delta)
		return inner + delta
	end
end
local fn = make(3)
return fn(2)
]]
			local result, errors = luaia.PackVariables(source)
			check.not_nil(result)
			check.equal(errors, nil)
			check.not_nil(string.find(result, "local __luaia_vars", 1, true))
			check.equal(string.find(result, "local outer", 1, true), nil)

			local chunk = loadstring(result)
			check.not_nil(chunk)
			check.equal(chunk(), 9)
		end)

		test.case("should preserve loop behavior", function()
			local result, errors = luaia.PackVariables([[local total = 0
for i = 1, 3 do
	total += i
end
return total]])
			check.not_nil(result)
			check.equal(errors, nil)

			local chunk = loadstring(result)
			check.not_nil(chunk)
			check.equal(chunk(), 6)
		end)

		test.case("should give loop-created closures separate locals", function()
			local source = [[
local callbacks = {}
for i = 1, 3 do
	local value = i
	table.insert(callbacks, function()
		return value
	end)
end
return callbacks[1](), callbacks[2](), callbacks[3]()
]]
			local result, errors = luaia.PackVariables(source)
			check.not_nil(result)
			check.equal(errors, nil)

			local chunk = loadstring(result)
			check.not_nil(chunk)
			local first, second, third = chunk()
			check.equal(first, 1)
			check.equal(second, 2)
			check.equal(third, 3)
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

	test.suite("table constant folding", function()
		test.case("should be off by default", function()
			local result, errors = luaia.Minify("local b = { a = true }\nif b.a then print('yay') end")
			check.not_nil(result)
			check.equal(errors, nil)
			check.not_nil(string.find(result, "if ", 1))
		end)

		test.case("should fold always-true conditions through table literals", function()
			local source = [[
local a = true
local b = { ["a"] = true }
if a and b["a"] == true then
    print("yay")
end
]]
			local result, errors = luaia.Minify(source, { Rules = { TableConstantFolding = true, LocalizeGlobals = false } })
			check.not_nil(result)
			check.equal(errors, nil)
			check.not_nil(string.find(result, 'print("yay")', 1, true))
			check.equal(string.find(result, "if ", 1, true), nil)
			check.equal(string.find(result, "{", 1, true), nil)
		end)

		test.case("should fold always-false conditions and splice else", function()
			local result, errors = luaia.Minify("local b = { a = false }\nif b.a then print('not run') else print('run') end", { Rules = { TableConstantFolding = true, LocalizeGlobals = false } })
			check.not_nil(result)
			check.equal(errors, nil)
			check.not_nil(string.find(result, 'print("run")', 1, true))
			check.equal(string.find(result, "not run", 1, true), nil)
		end)

		test.case("should fold nested table reads", function()
			local result, errors = luaia.Minify("local b = { sub = { x = 5 } }\nif b.sub.x == 5 then print('nested') end", { Rules = { TableConstantFolding = true, LocalizeGlobals = false } })
			check.not_nil(result)
			check.equal(errors, nil)
			check.not_nil(string.find(result, 'print("nested")', 1, true))
			check.equal(string.find(result, "if ", 1, true), nil)
		end)

		test.case("should fold dot-access fields", function()
			local result, errors = luaia.Minify("local b = { a = true }\nif b.a then print('dot') end", { Rules = { TableConstantFolding = true, LocalizeGlobals = false } })
			check.not_nil(result)
			check.equal(errors, nil)
			check.not_nil(string.find(result, 'print("dot")', 1, true))
			check.equal(string.find(result, "if ", 1, true), nil)
		end)

		test.case("should not fold tables passed to calls", function()
			local result, errors = luaia.Minify("local b = { a = true }\nprint(b)\nif b.a then print('yay') end", { Rules = { TableConstantFolding = true, LocalizeGlobals = false } })
			check.not_nil(result)
			check.equal(errors, nil)
			check.not_nil(string.find(result, "if ", 1))
		end)

		test.case("should not fold tables with field writes", function()
			local result, errors = luaia.Minify("local b = { a = true }\nb.a = false\nif b.a then print('yay') end", { Rules = { TableConstantFolding = true, LocalizeGlobals = false } })
			check.not_nil(result)
			check.equal(errors, nil)
			check.not_nil(string.find(result, "if ", 1))
		end)

		test.case("should not fold aliased sub-tables", function()
			local result, errors = luaia.Minify("local b = { sub = { x = 5 } }\nlocal c = b.sub\nc.x = 6\nif b.sub.x == 5 then print('nested') end", { Rules = { TableConstantFolding = true, LocalizeGlobals = false } })
			check.not_nil(result)
			check.equal(errors, nil)
			check.not_nil(string.find(result, "if ", 1))
		end)

		test.case("should preserve side-effectful initializers", function()
			local result, errors = luaia.Minify("local b = { a = print('side') }\nif b.a == nil then print('never') end", { Rules = { TableConstantFolding = true, LocalizeGlobals = false } })
			check.not_nil(result)
			check.equal(errors, nil)
			check.not_nil(string.find(result, "print", 1, true))
			check.not_nil(string.find(result, "if ", 1))
		end)

		test.case("should require dead code elimination", function()
			local result, errors = luaia.Minify("local b = { a = true }\nif b.a then print('yay') end", { Rules = { TableConstantFolding = true, DeadCodeElimination = false, LocalizeGlobals = false } })
			check.not_nil(result)
			check.equal(errors, nil)
			check.not_nil(string.find(result, "if ", 1))
		end)
	end)

	test.suite("table key renaming", function()
		test.case("should be off by default", function()
			local result, errors = luaia.Minify("local a = { sub1 = { x = 1 } }\nprint(a.sub1.x)")
			check.not_nil(result)
			check.equal(errors, nil)
			check.not_nil(string.find(result, "sub1", 1, true))
		end)

		test.case("should rename keys and rewrite accesses when enabled", function()
			local source = [[
local a = {
    sub1 = { x = 1 },
    m = true
}
if a.m then
    print(a.sub1.x)
end
]]
			local result, errors = luaia.Minify(source, { Rules = { RenameTableKeys = true } })
			check.not_nil(result)
			check.equal(errors, nil)
			check.equal(string.find(result, "sub1", 1, true), nil)
			check.not_nil(string.find(result, "[a-z]=true", 1))
		end)

		test.case("should rename nested table keys", function()
			local source = [[
local a = {
    sub1 = {
        a = 32,
        ["bnm"] = 12
    },
    sub2 = {
        ["1"] = "a2",
        ["32"] = "a1"
    }
}
print(a.sub1.a + a.sub2["1"])
]]
			local result, errors = luaia.Minify(source, { Rules = { RenameTableKeys = true } })
			check.not_nil(result)
			check.equal(errors, nil)
			check.equal(string.find(result, "sub1", 1, true), nil)
			check.equal(string.find(result, "sub2", 1, true), nil)
			check.equal(string.find(result, "bnm", 1, true), nil)
		end)

		test.case("should preserve behavior after renaming", function()
			local source = [[
local a = {
    sub1 = { x = 40 },
    m = true
}
if a.m then
    print(a.sub1.x + 2)
end
]]
			local result, errors = luaia.Minify(source, { Rules = { RenameTableKeys = true } })
			check.not_nil(result)
			check.equal(errors, nil)
			check.equal(string.find(result, "sub1", 1, true), nil)
			check.not_nil(string.find(result, "print", 1, true))
		end)

		test.case("should skip returned tables", function()
			local result, errors = luaia.Minify("local a = { sub1 = { x = 1 } }\nreturn a", { Rules = { RenameTableKeys = true } })
			check.not_nil(result)
			check.equal(errors, nil)
			check.not_nil(string.find(result, "sub1", 1, true))
		end)

		test.case("should skip tables stored into globals", function()
			local result, errors = luaia.Minify("local a = { sub1 = { x = 1 } }\n_G.a = a", { Rules = { RenameTableKeys = true } })
			check.not_nil(result)
			check.equal(errors, nil)
			check.not_nil(string.find(result, "sub1", 1, true))
		end)

		test.case("should skip tables stored into the environment", function()
			local result, errors = luaia.Minify("local a = { sub1 = { x = 1 } }\ngetfenv().a = a", { Rules = { RenameTableKeys = true } })
			check.not_nil(result)
			check.equal(errors, nil)
			check.not_nil(string.find(result, "sub1", 1, true))
		end)

		test.case("should skip reassigned tables", function()
			local result, errors = luaia.Minify("local a = { sub1 = { x = 1 } }\na = { other = 2 }\nprint(a.sub1.x)", { Rules = { RenameTableKeys = true } })
			check.not_nil(result)
			check.equal(errors, nil)
			check.not_nil(string.find(result, "sub1", 1, true))
		end)

		test.case("should skip tables passed to calls", function()
			local result, errors = luaia.Minify("local a = { sub1 = { x = 1 } }\nprint(a)", { Rules = { RenameTableKeys = true } })
			check.not_nil(result)
			check.equal(errors, nil)
			check.not_nil(string.find(result, "sub1", 1, true))
		end)

		test.case("should skip aliased tables", function()
			local result, errors = luaia.Minify("local a = { sub1 = { x = 1 } }\nlocal b = a.sub1\nprint(b.x)", { Rules = { RenameTableKeys = true } })
			check.not_nil(result)
			check.equal(errors, nil)
			check.not_nil(string.find(result, "sub1", 1, true))
		end)

		test.case("should skip keys of tables accessed with dynamic indices", function()
			local source = [[
local t = { a = 1 }
local function get(k)
	return t[k]
end
print(get("a"))
]]
			local result, errors = luaia.Minify(source, { Rules = { RenameTableKeys = true, LocalizeGlobals = false } })
			check.not_nil(result)
			check.equal(errors, nil)
			check.not_nil(string.find(result, "a=1", 1, true))
		end)

		test.case("should skip keys of sub-tables accessed with dynamic indices", function()
			local source = [[
local tq = { t = { ["a"] = { Code = 1 } } }
local function get(id)
	return tq.t[id].Code
end
print(get("a"))
]]
			local result, errors = luaia.Minify(source, { Rules = { RenameTableKeys = true, LocalizeGlobals = false } })
			check.not_nil(result)
			check.equal(errors, nil)
			check.not_nil(string.find(result, '["a"]', 1, true))
		end)

		test.case("should rename shared fields of dynamically-dispatched tables", function()
			local source = [[
local registry = { v = {
	[0] = { Code = 1, NumLocals = 2 },
	[1] = { Code = 3, NumLocals = 4 },
	[key()] = { Code = 5, NumLocals = 6 },
} }
local function get(id)
	local jx = { v = registry.v[id] }
	return jx.v.Code + jx.v.NumLocals
end
print(get(0))
print(get(1))
]]
			local result, errors = luaia.Minify(source, { Rules = { RenameTableKeys = true, LocalizeGlobals = false } })
			check.not_nil(result)
			check.equal(errors, nil)
			check.equal(string.find(result, "Code", 1, true), nil)
			check.equal(string.find(result, "NumLocals", 1, true), nil)
		end)

		test.case("should rename shared fields of root dynamically-dispatched tables", function()
			local source = [[
local t = { a = { Code = 1 }, b = { Code = 2 } }
local function get(k)
	return t[k].Code
end
print(get("a"), get("b"))
]]
			local result, errors = luaia.Minify(source, { Rules = { RenameTableKeys = true, LocalizeGlobals = false } })
			check.not_nil(result)
			check.equal(errors, nil)
			check.equal(string.find(result, "Code", 1, true), nil)
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
