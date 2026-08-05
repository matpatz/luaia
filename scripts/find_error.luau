local Parser = require("@luaia/Parser")

local source = [[
function VexUI:CreateInstance(ClassName, Properties) return 1 end
]]

local ast = Parser.Parse(source)
local funcDef = ast.body[1]
local selfParam = funcDef.func.self
print("self param kind: " .. typeof(selfParam))
print("self param name: " .. selfParam.name)
-- Check keys
for k, v in selfParam do
    print("  " .. k .. " = " .. tostring(v))
end
