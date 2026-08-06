local LuauParser = require("./LuauParser")

local Parser = {}

function Parser.Parse(source: string)
	local Success, Result = LuauParser.parse(source, { storeCstData = false })

	if not Success then
		local Errors = {}
		for _, Error in Result.errors do
			table.insert(Errors, Error.message)
		end
		return nil, Errors
	end

	return Result.root, nil
end

return Parser
