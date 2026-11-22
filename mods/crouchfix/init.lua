local crouch_state = {}      -- [player_name] = boolean
local prev_sneak = {}        -- [player_name] = boolean

local CROUCH_SPEED = 0.45    -- Movement speed multiplier while crouched
local NORMAL_SPEED = 1.0
local CROUCH_EYE_OFFSET = { x = 0, y = -4, z = 0 } -- In pixels (1 node = 10 px)
local NORMAL_EYE_OFFSET = { x = 0, y = 0, z = 0 }

local function apply_crouch(player, is_crouching)
	local name = player:get_player_name()
	crouch_state[name] = is_crouching

	if is_crouching then
		player:set_physics_override({ speed = CROUCH_SPEED })
		player:set_eye_offset(CROUCH_EYE_OFFSET, CROUCH_EYE_OFFSET)
	else
		player:set_physics_override({ speed = NORMAL_SPEED })
		player:set_eye_offset(NORMAL_EYE_OFFSET, NORMAL_EYE_OFFSET)
	end
end

core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	prev_sneak[name] = false
	apply_crouch(player, false)
end)

core.register_on_leaveplayer(function(player)
	local name = player:get_player_name()
	crouch_state[name] = nil
	prev_sneak[name] = nil
end)

core.register_globalstep(function(_dtime)
	for _, player in ipairs(core.get_connected_players()) do
		local name = player:get_player_name()
		local controls = player:get_player_control()
		local sneak_down = controls.sneak == true
		local was_down = prev_sneak[name] == true

		-- Toggle only on the moment the sneak key is pressed (rising edge)
		if sneak_down and not was_down then
			local next_state = not (crouch_state[name] == true)
			apply_crouch(player, next_state)
		end

		prev_sneak[name] = sneak_down
	end
end)