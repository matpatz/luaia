-- lune run bin/cli.lua test/input.lua -o test/output.lua -r

local x = 1 + 2
local function add(a, b)
    return a + b
end
print(add(x, 3))