local fs = require("@lune/fs")
local Parser = require("@luaia/Parser")

local source = [[local x = `\n{1}\n{2}`]]
local ast = Parser.Parse(source)
if not ast then return end

for _, stat in ast.body do
    if stat.kind == "StatLocal" then
        for _, val in stat.values do
            if val.kind == "ExprInterpString" then
                for i, s in val.strings do
                    local len = #s
                    local hex = {}
                    for j = 1, len do
                        table.insert(hex, string.format("%02x", string.byte(s, j)))
                    end
                    print("strings[" .. i .. "] len=" .. len .. " hex=" .. table.concat(hex, " ") .. " repr=" .. string.format("%q", s))
                end
                print("expressions count: " .. #val.expressions)
            end
        end
    end
end
