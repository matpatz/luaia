local fs = require("@lune/fs")
local Parser = require("@luaia/Parser")

local source = fs.readFile("test/output.lua")

-- Find all interp strings and check them
local i = 1
local errors = {}
while i <= #source do
    local ch = string.sub(source, i, i)
    if ch == "`" then
        local start = i
        i += 1
        while i <= #source do
            local c = string.sub(source, i, i)
            if c == "\\" then
                local next_c = string.sub(source, i+1, i+1)
                if next_c == "n" or next_c == "r" or next_c == "t" or next_c == "0" or next_c == "\\" or next_c == "`" then
                    i += 2
                else
                    table.insert(errors, "Bad escape \\" .. next_c .. " at pos " .. i .. " in interp string starting at " .. start)
                    i += 2
                end
            elseif c == "{" then
                i += 1
                -- skip to matching }
                local depth = 1
                while i <= #source and depth > 0 do
                    local ec = string.sub(source, i, i)
                    if ec == "{" then depth += 1
                    elseif ec == "}" then depth -= 1 end
                    i += 1
                end
            elseif c == "`" then
                break
            else
                i += 1
            end
        end
    else
        i += 1
    end
end

for _, e in errors do
    print(e)
end
if #errors == 0 then
    print("No interp string issues found")
end
