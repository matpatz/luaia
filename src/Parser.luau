local LuauParser = require("./LuauParser")

local Parser = {}

function Parser.Parse(source: string)
	local Success, Result = LuauParser.parse(source, { storeCstData = false })

	if not Success then
		local errors = {}
		for _, err in Result.errors do
			table.insert(errors, err.message)
		end
		return nil, errors
	end

	return Result.root, nil
end

return Parser
