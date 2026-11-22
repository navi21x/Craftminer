-- Hooks into the mob APIs. Each one keeps everything the API does at death
-- (drops, xp, sounds, callbacks, kill credit) and replaces only the visual
-- part: the death animation, tipping over, fading, smoke - with a ragdoll.
local R = ragdoll

local function mod(name) return core.get_modpath(name) ~= nil end

-- The frame to freeze the body at: the mob's standing pose.
local function stand_frame(le)
	local a = le.animation or le.animations
	if type(a) ~= "table" then return nil end
	if a.stand_start then return a.stand_start end                         -- mobs redo / mcl_mobs
	local s = a.stand or a.idle
	if type(s) == "table" then
		if s.range then return s.range.x end                                 -- mobkit / creatura
		if s.x then return s.x end                                           -- all_mobs_api
	end
	return nil
end
R.stand_frame = stand_frame

local function is_api_mob(def) return def and rawget(def, "_ragdoll_api") end

-- The game's own knockback for the hit that killed `self` (see knockback.lua):
-- fn(self, hit) for a hit no older than `age` seconds.
local K = R.knockback
local function knockback(self, fn, age)
	local rec = R.recent_hit(self.object)
	if not rec or core.get_us_time() - rec.t > (age or 1.5) * 1e6 then return nil end
	local ok, kb = pcall(fn, self, rec)
	if ok then return kb end
	core.log("warning", "[ragdoll] knockback: " .. tostring(kb))
	return nil
end

core.register_on_mods_loaded(function()
	----------------------------------------------------------------------------
	-- Every entity: remember the punch that might kill it (direction, strength)
	----------------------------------------------------------------------------
	for name, def in pairs(core.registered_entities) do
		if not name:find("^ragdoll:") and not name:find("^__builtin") then
			local own = rawget(def, "on_punch")
			local mt = getmetatable(def)
			def.on_punch = function(self, puncher, tflp, caps, dir, damage, ...)
				if dir and self.object then R.note_hit(self.object, dir, damage, caps, puncher, tflp) end
				local f = own
				if not f then
					local idx = mt and mt.__index
					f = type(idx) == "table" and idx.on_punch or nil
				end
				if f then return f(self, puncher, tflp, caps, dir, damage, ...) end
			end
		end
	end

	----------------------------------------------------------------------------
	-- Mobs Redo
	----------------------------------------------------------------------------
	local mobs = rawget(_G, "mobs")
	if mobs and type(mobs.mob_class) == "table" and mobs.mob_class.check_for_death then
		local mc = mobs.mob_class
		local orig_check, orig_anim = mc.check_for_death, mc.death_anim
		-- (beside the mob, not on it: Mobs Redo saves every field of a mob)
		local pending = setmetatable({}, {__mode = "k"})
		mc.check_for_death = function(self, cause, ...)
			local snap
			if self.state ~= "die" and (self.health or 1) <= 0 and not self._ragdolled and R.enabled_for(self) then
				local kb = type(cause) == "table" and cause.type == "punch" and knockback(self, K.mobs_redo, 0.3) or nil
				snap = R.snapshot(self.object, {frame = stand_frame(self), texture_mod = self.texture_mods, kb = kb})
			end
			pending[self] = snap
			local r = orig_check(self, cause, ...)
			-- gone already (its on_die / on_death removed it): the body falls now
			if snap and not self._ragdolled and not self.object:get_pos() then
				self._ragdolled = true
				R.spawn(snap)
			end
			pending[self] = nil
			return r
		end
		mc.death_anim = function(self, ...)
			local snap = pending[self]
			if snap and not self._ragdolled then
				self._ragdolled = true
				R.spawn(snap, self.object)
				if mobs.remove then mobs:remove(self, true) else self.object:remove() end
				return true    -- (no smoke, no death animation)
			end
			return orig_anim(self, ...)
		end
		for _, def in pairs(core.registered_entities) do
			local mt = getmetatable(def)
			if mt and mt.__index == mc then def._ragdoll_api = true end
		end
		core.log("action", "[ragdoll] hooked Mobs Redo")
	end

	----------------------------------------------------------------------------
	-- mcl_mobs (VoxeLibre, MineClone2, Mineclonia)
	----------------------------------------------------------------------------
	local mcl_mobs = rawget(_G, "mcl_mobs")
	if mcl_mobs and type(mcl_mobs.mob_class) == "table" and mcl_mobs.mob_class.check_for_death then
		local mc = mcl_mobs.mob_class
		local orig = mc.check_for_death
		local quiet = false
		local mcl_util = rawget(_G, "mcl_util")
		local mineclonia = mc.apply_knockback ~= nil and mcl_util and mcl_util.calculate_knockback ~= nil
		mc.check_for_death = function(self, ...)
			local dying = (self.health or 1) <= 0 and self.state ~= "die" and not self.dead and not self._ragdolled
				and R.enabled_for(self)
			if not dying then return orig(self, ...) end
			-- (Mineclonia knocks back the Minecraft way, VoxeLibre its own)
			local kb = knockback(self, mineclonia and K.mcl_mineclonia or K.mcl_voxelibre, 0.3)
			local snap = R.snapshot(self.object, {frame = stand_frame(self), strip = "^[colorize:#d42222:175", kb = kb})
			-- an instant death: drops, xp, sounds and callbacks now, no tipping over
			local had = rawget(self, "instant_death")
			self.instant_death = true
			quiet = true
			local ok, r = pcall(orig, self, ...)
			quiet = false
			self.instant_death = had
			if not ok then error(r, 0) end
			if (self.dead or self.state == "die" or not self.object:get_pos()) and not self._ragdolled then
				self._ragdolled = true
				R.spawn(snap, self.object)
				-- (Mineclonia removes it on its next step)
				if self.object:get_pos() then R.hide_object(self.object) end
			end
			return r
		end
		local effect = mcl_mobs.death_effect
		if effect then
			mcl_mobs.death_effect = function(...)
				if quiet then return end    -- (the smoke puff of a vanishing body)
				return effect(...)
			end
		end
		for _, def in pairs(core.registered_entities) do
			local mt = getmetatable(def)
			if mt and mt.__index == mc then def._ragdoll_api = true end
		end
		core.log("action", "[ragdoll] hooked mcl_mobs")
	end

	----------------------------------------------------------------------------
	-- mob_core (on mobkit): its own death sequence
	----------------------------------------------------------------------------
	local mob_core = rawget(_G, "mob_core")
	local mobkit = rawget(_G, "mobkit")
	if mob_core and mobkit and mob_core.on_die then
		local orig = mob_core.on_die
		mob_core.on_die = function(self, ...)
			if self._ragdolled or not R.enabled_for(self) then return orig(self, ...) end
			self._ragdolled = true
			local snap = R.snapshot(self.object, {frame = stand_frame(self), kb = knockback(self, K.mob_core)})
			if self.driver and mob_core.force_detach then mob_core.force_detach(self.driver) end
			self.owner = nil
			if self.sounds and self.sounds.death and mob_core.make_sound then mob_core.make_sound(self, "death") end
			self.logic = function() end
			mobkit.queue_high(self, function(s)
				if not mobkit.exists(s) then return true end
				if s.driver and mob_core.force_detach then mob_core.force_detach(s.driver) end
				if mob_core.item_drop then mob_core.item_drop(s) end
				R.spawn(snap, s.object)
				s.object:remove()
				return true
			end, 100)
		end
		core.log("action", "[ragdoll] hooked mob_core")
	end

	----------------------------------------------------------------------------
	-- mobkit: hq_die (fall over, wait, vanish)
	----------------------------------------------------------------------------
	if mobkit and mobkit.hq_die then
		local orig = mobkit.hq_die
		mobkit.hq_die = function(self, ...)
			if self._ragdolled or not R.enabled_for(self) then return orig(self, ...) end
			self._ragdolled = true
			local snap = R.snapshot(self.object, {frame = stand_frame(self)})
			self.logic = function() end
			mobkit.queue_high(self, function(s)
				if not mobkit.exists(s) then return true end
				R.spawn(snap, s.object)
				s.object:remove()
				return true
			end, 100)
		end
		for _, def in pairs(core.registered_entities) do
			if def.on_step == mobkit.stepfunc then def._ragdoll_api = true end
		end
		core.log("action", "[ragdoll] hooked mobkit")
	end

	----------------------------------------------------------------------------
	-- Creatura (Animalia and others)
	----------------------------------------------------------------------------
	local creatura = rawget(_G, "creatura")
	if creatura then
		-- Animalia's death: sound, fall over, wait, smoke, drops, vanish
		if creatura.registered_utilities and creatura.registered_utilities["animalia:die"] then
			creatura.register_utility("animalia:die", function(self)
				local snap = not self._ragdolled and R.enabled_for(self)
					and R.snapshot(self.object, {frame = stand_frame(self), kb = knockback(self, K.creatura)}) or nil
				self:set_utility(function(m)
					local pos = m.object:get_pos()
					if not pos then return end
					local s = m.sounds and m.sounds.death
					if s and s.name then
						core.sound_play(s.name, {pos = pos, gain = s.gain or 1, max_hear_distance = s.distance or 16}, true)
					elseif m.play_sound then
						m:play_sound("death")
					end
					if creatura.drop_items then creatura.drop_items(m) end
					if snap and not m._ragdolled then
						m._ragdolled = true
						R.spawn(snap, m.object)
					end
					m.object:remove()
				end)
			end)
		end
		-- anything else falling over the Creatura way: ragdoll now, the real
		-- body is hidden and the mob's own code removes it later
		if creatura.action_fallover then
			local orig = creatura.action_fallover
			creatura.action_fallover = function(self, ...)
				if not self._ragdolled and R.enabled_for(self) then
					self._ragdolled = true
					R.spawn_from(self.object, {frame = stand_frame(self), kb = knockback(self, K.creatura)})
					R.hide_object(self.object)
				end
				return orig(self, ...)
			end
		end
		for _, def in pairs(core.registered_entities) do
			local mt = getmetatable(def)
			local idx = mt and mt.__index
			if type(idx) == "table" and rawget(idx, "_execute_utilities") then def._ragdoll_api = true end
		end
		core.log("action", "[ragdoll] hooked Creatura")
	end

	----------------------------------------------------------------------------
	-- all_mobs_api: die() rolls the body over or plays "die", then vanishes
	----------------------------------------------------------------------------
	local amapi = rawget(_G, "all_mobs_api")
	if amapi and type(amapi.registered_mobs) == "table" then
		for name in pairs(amapi.registered_mobs) do
			local proto = core.registered_entities[name]
			if proto and proto.die then
				local orig_die = proto.die
				proto.die = function(self, cause, source, ...)
					if self._dead or self._ragdolled or not R.enabled_for(self) then
						return orig_die(self, cause, source, ...)
					end
					local o = self.object
					local snap = R.snapshot(o, {frame = stand_frame(self.def or self), kb = knockback(self, K.all_mobs_api)})
					local r = orig_die(self, cause, source, ...)    -- goals, sound, on_death, drops
					if o:get_pos() and not self._ragdolled then
						self._ragdolled = true
						R.spawn(snap, o)
						-- (die() can run in the middle of the mob's own step, which
						-- carries on using the object: hidden now, gone next step)
						R.hide_object(o)
						core.after(0, function() if o:is_valid() then o:remove() end end)
					end
					return r
				end
				proto._ragdoll_api = true
			end
		end
		core.log("action", "[ragdoll] hooked all_mobs_api")
	end

	----------------------------------------------------------------------------
	-- Explosions: recorded as they go off (before they hurt anyone), with the
	-- game's own knockback for them
	----------------------------------------------------------------------------
	-- Minetest Game (and games using its tnt mod): tnt.boom. Entities get
	-- 10 * r / distance m/s, players 2 * r / distance (r: the damage radius).
	local tnt = rawget(_G, "tnt")
	if tnt and tnt.boom then
		local orig = tnt.boom
		tnt.boom = function(pos, def, ...)
			if pos then
				local d = type(def) == "table" and def or {}
				local r = tonumber(d.damage_radius) or (tonumber(d.radius) or 1) * 2
				R.blast({pos = pos, radius = r, speed = function(dist, is_player)
					return is_player and 2 / dist * r or r * 10 / dist
				end})
			end
			return orig(pos, def, ...)
		end
		core.log("action", "[ragdoll] hooked tnt.boom")
	end
	-- VoxeLibre, MineClone2, Mineclonia: mcl_explosions.explode. Impact * 20
	-- m/s, impact = 1 - distance / (2 * strength); creatures then slide or
	-- drag the way that game moves them.
	local mcl_explosions = rawget(_G, "mcl_explosions")
	if mcl_explosions and mcl_explosions.explode then
		local orig = mcl_explosions.explode
		local mineclonia = mcl_mobs and mcl_mobs.mob_class and mcl_mobs.mob_class.apply_knockback ~= nil
		mcl_explosions.explode = function(pos, strength, ...)
			if pos then
				local r = 2 * (tonumber(strength) or 3)
				R.blast({pos = pos, radius = r, speed = function(dist, is_player)
					local impact = math.max(0, 1 - dist / r)
					return impact * 20, (not is_player) and (mineclonia and "mc" or "voxelibre") or nil
				end})
			end
			return orig(pos, strength, ...)
		end
		core.log("action", "[ragdoll] hooked mcl_explosions")
	end
	-- Mobs Redo's own explosion (no tnt mod): it only punches, within twice
	-- the radius; thrown the TNT way.
	if mobs and mobs.safe_boom then
		local orig = mobs.safe_boom
		mobs.safe_boom = function(m, self, pos, radius, ...)
			if pos and tonumber(radius) then
				local r = radius * 2
				R.blast({pos = pos, radius = r, speed = function(dist, is_player)
					return is_player and 2 / dist * r or r * 10 / dist
				end})
			end
			return orig(m, self, pos, radius, ...)
		end
	end

	----------------------------------------------------------------------------
	-- Anything else the engine kills (hp reaches 0): plain mesh mobs
	----------------------------------------------------------------------------
	for name, def in pairs(core.registered_entities) do
		local ip = def.initial_properties or def
		if not name:find("^ragdoll:") and not name:find("^__builtin") and not is_api_mob(def)
				and (ip.visual == "mesh" or ip.visual == "cube") and (ip.hp_max or 1) > 1 then
			local own = rawget(def, "on_death")
			def.on_death = function(self, killer, ...)
				if not self._ragdolled and R.enabled_for(self) then
					self._ragdolled = true
					R.spawn_from(self.object)
				end
				if own then return own(self, killer, ...) end
			end
		end
	end
end)
