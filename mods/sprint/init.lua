local players = {}

-- Config
local SPRINT_SPEED      = 1.45   -- ~30-45% faster than base walk speed
local NORMAL_SPEED      = 1.0
local SPRINT_FOV_MULT   = 1.12   -- Subtle FOV zoom-out like Minecraft
local DOUBLE_TAP_WINDOW = 0.30   -- Max seconds between two W presses
local PARTICLE_INTERVAL = 0.08   -- Seconds between footstep dust particles

local function set_sprinting(player, state)
	local name = player:get_player_name()
	local data = players[name]
	if not data or data.sprinting == state then return end

	data.sprinting = state

	if state then
		player:set_physics_override({ speed = SPRINT_SPEED })
		-- Smooth 0.15s FOV transition (multiplier = true)
		if player.set_fov then
			player:set_fov(SPRINT_FOV_MULT, true, 0.15)
		end
	else
		player:set_physics_override({ speed = NORMAL_SPEED })
		if player.set_fov then
			player:set_fov(0, false, 0.15) -- 0 resets to client default FOV
		end
	end
end

-- Check if the player is walking straight into a solid wall
local function hitting_wall(player)
	local pos = player:get_pos()
	local dir = player:get_look_dir()
	-- Flatten look direction horizontally and sample 0.45 nodes ahead at waist height
	local flat = vector.normalize({ x = dir.x, y = 0, z = dir.z })
	local check_pos = {
		x = pos.x + flat.x * 0.45,
		y = pos.y + 0.8,
		z = pos.z + flat.z * 0.45,
	}
	local node = core.get_node_or_nil(check_pos)
	if not node then return false end
	local def = core.registered_nodes[node.name]
	return def and def.walkable == true
end

-- Spawn block particles under the player's feet
local function spawn_sprint_particles(player)
	local pos = player:get_pos()
	local under_pos = { x = pos.x, y = pos.y - 0.1, z = pos.z }
	local node = core.get_node_or_nil(under_pos)
	if not node or node.name == "air" then return end

	local def = core.registered_nodes[node.name]
	if not def or not def.walkable then return end

	local vel = player:get_velocity()
	core.add_particlespawner({
		amount = 3,
		time = 0.05,
		minpos = { x = pos.x - 0.2, y = pos.y + 0.05, z = pos.z - 0.2 },
		maxpos = { x = pos.x + 0.2, y = pos.y + 0.15, z = pos.z + 0.2 },
		minvel = { x = -vel.x * 0.2 - 0.5, y = 1.5, z = -vel.z * 0.2 - 0.5 },
		maxvel = { x = -vel.x * 0.2 + 0.5, y = 2.8, z = -vel.z * 0.2 + 0.5 },
		minacc = { x = 0, y = -9.8, z = 0 },
		maxacc = { x = 0, y = -9.8, z = 0 },
		minexptime = 0.25,
		maxexptime = 0.45,
		minsize = 0.8,
		maxsize = 1.4,
		node = { name = node.name }, -- Automatically uses the ground block's texture
	})
end

core.register_on_joinplayer(function(player)
	players[player:get_player_name()] = {
		sprinting = false,
		prev_up = false,
		last_tap_time = 0,
		particle_timer = 0,
	}
end)

core.register_on_leaveplayer(function(player)
	players[player:get_player_name()] = nil
end)

core.register_globalstep(function(dtime)
	local now = core.get_us_time() / 1e6

	for _, player in ipairs(core.get_connected_players()) do
		local name = player:get_player_name()
		local data = players[name]
		if data then
			local ctrl = player:get_player_control()
			local up = ctrl.up == true
			local down = ctrl.down == true
			local aux1 = ctrl.aux1 == true
			local sneak = ctrl.sneak == true

			-- 1. Detect double-tap Forward (rising edge of `up`)
			if up and not data.prev_up then
				if (now - data.last_tap_time) <= DOUBLE_TAP_WINDOW and not sneak then
					set_sprinting(player, true)
					data.last_tap_time = 0 -- Reset so triple-tap doesn't re-trigger
				else
					data.last_tap_time = now
				end
			end

			-- 2. Dedicated sprint key (`aux1` / E by default) while moving forward
			if aux1 and up and not down and not sneak then
				set_sprinting(player, true)
			end

			-- 3. Stop sprinting when releasing forward, pressing back, sneaking, or hitting a wall
			if data.sprinting then
				if not up or down or sneak or hitting_wall(player) then
					set_sprinting(player, false)
				else
					-- Spawn sprint dust particles on timer
					data.particle_timer = data.particle_timer + dtime
					if data.particle_timer >= PARTICLE_INTERVAL then
						data.particle_timer = 0
						spawn_sprint_particles(player)
					end
				end
			end

			data.prev_up = up
		end
	end
end)