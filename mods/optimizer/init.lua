local turbo_opt = {}

local presets = {
	balanced = {
		active_block_range = "3",
		max_block_send_distance = "10",
		max_simultaneous_block_sends_per_client = "8",
		abm_time_budget = "0.2",
	},
	potato = {
		active_block_range = "2",
		max_block_send_distance = "6",
		max_simultaneous_block_sends_per_client = "4",
		abm_time_budget = "0.1",
	},
}

local function apply_preset(preset_name)
	local cfg = presets[preset_name]
	if not cfg then
		return false, "Unknown preset. Use 'balanced' or 'potato'."
	end

	for key, val in pairs(cfg) do
		core.settings:set(key, val)
	end

	return true, "Applied '" .. preset_name .. "' performance preset."
end

-- Apply 'balanced' preset on startup without overwriting custom user values if already set
core.register_on_mods_loaded(function()
	if not core.settings:get("active_block_range") then
		core.settings:set("active_block_range", presets.balanced.active_block_range)
	end
end)

core.register_chatcommand("fps_boost", {
	params = "<balanced|potato>",
	description = "Switch server/world performance settings preset",
	privs = { server = true },
	func = function(_name, param)
		local choice = (param and param ~= "") and param:lower() or "potato"
		local ok, msg = apply_preset(choice)
		return ok, msg
	end,
})

return turbo_opt