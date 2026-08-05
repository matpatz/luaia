local luaia = require(game.ReplicatedStorage.luaia)

local function test(name, fn)
	local ok, err = pcall(fn)
	if ok then
		print("[PASS] " .. name)
	else
		print("[FAIL] " .. name .. ": " .. tostring(err))
	end
end

test("should create new instance", function()
	local instance = luaia.new()
	assert(instance ~= nil, "instance should not be nil")
end)
