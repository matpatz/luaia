local fs = require("@lune/fs")
local Parser = require("@luaia/Parser")

local source = fs.readFile("test/output.lua")
local ast, errors = Parser.Parse(source)
if errors then
    for i, e in errors do
        print(i .. ": " .. e)
    end
    print("Total: " .. #errors)
else
    print("Parse OK - " .. #source .. " bytes")
end
