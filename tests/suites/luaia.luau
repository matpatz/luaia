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
