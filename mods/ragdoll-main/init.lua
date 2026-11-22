-- Ragdoll: when a player or a mob dies, its body falls as a physics ragdoll
-- instead of playing a death animation, tipping over or vanishing.
--
-- Works with any skinned model: the bones are read from the model file
-- (.b3d, .gltf, .glb) and a rig is worked out from them - the torso and the
-- limbs hanging off it - so no per-mob setup is needed. Models without bones
-- fall as rigid bodies. Hooks for Mobs Redo, mcl_mobs (VoxeLibre, Mineclonia,
-- MineClone2), mobkit, mob_core, Creatura (Animalia), all_mobs_api, players in
-- any game, and any other entity the engine kills.
ragdoll = {}
local R = ragdoll
local modpath = core.get_modpath(core.get_current_modname())

--------------------------------------------------------------------------------
-- Settings (re-read every few seconds)
--------------------------------------------------------------------------------
local DEFAULTS = {players = true, mobs = true, lifetime = 15, max = 30, despawn = "fade", impulse = 0.25, spin = 1,
	flash = true, blast = 1.5, joint_range = 1, joint_stiffness = 1}
local cache, cache_t = {}, -1
function R.setting(key, default)
	if cache[key] == nil then
		local d = DEFAULTS[key]
		if d == nil then d = default end
		local raw = core.settings:get("ragdoll_" .. key)
		local val = d
		if raw ~= nil and raw ~= "" then
			if type(d) == "boolean" then val = core.is_yes(raw)
			elseif type(d) == "number" then val = tonumber(raw) or d
			else val = raw end
		end
		cache[key] = val
	end
	return cache[key]
end
core.register_globalstep(function(dtime)
	cache_t = cache_t + dtime
	if cache_t > 5 then cache, cache_t = {}, 0 end
end)

R.models = dofile(modpath .. "/models.lua")

--------------------------------------------------------------------------------
-- Profiles: per entity name (or mesh file) tweaks; other mods can add their own
--   disable = true            no ragdoll for it
--   rigid_only = true         fall as one stiff body (no limbs)
--   skip_bones = {name = true}, max_angle = {bone = radians}, frame = number
--------------------------------------------------------------------------------
R.profiles = {}
function R.register_profile(name, profile) R.profiles[name] = profile end
function R.exclude(name) R.profiles[name] = {disable = true} end

local spawn_callbacks = {}
-- func(ragdoll_object, snapshot, source_object_or_nil)
function R.register_on_spawn(func) spawn_callbacks[#spawn_callbacks + 1] = func end

--------------------------------------------------------------------------------
-- Model files: where each one is, and its rig (worked out once per mesh)
--------------------------------------------------------------------------------
local paths
local EXT = {b3d = true, gltf = true, glb = true}
local function index_models()
	paths = {}
	for _, mod in ipairs(core.get_modnames()) do
		local mp = core.get_modpath(mod)
		for _, sub in ipairs({"models", "media", "textures"}) do
			local function walk(dir, depth)
				for _, f in ipairs(core.get_dir_list(dir, false) or {}) do
					local ext = f:match("%.(%w+)$")
					if ext and EXT[ext:lower()] and not paths[f] then paths[f] = dir .. "/" .. f end
				end
				if depth < 4 then
					for _, d in ipairs(core.get_dir_list(dir, true) or {}) do walk(dir .. "/" .. d, depth + 1) end
				end
			end
			if mp then walk(mp .. "/" .. sub, 0) end
		end
	end
end

-- Models with the skeleton once per mesh (a horse's body, saddle and armor;
-- an overlay layer) get a copy whose extra bones have names of their own, so
-- the ragdoll can move them all (see models.b3d_aliases). Made at startup and
-- sent to clients with the rest of the media.
R.mesh_aliases = {}   -- [mesh] = {mesh = renamed copy, bones = {[bone] = {other names}}}
local function make_aliases()
	if not core.dynamic_add_media then return end
	local meshes = {}
	for _, def in pairs(core.registered_entities) do
		local ip = def.initial_properties or def
		if type(ip.mesh) == "string" then meshes[ip.mesh] = true end
	end
	for _, api in ipairs({"player_api", "mcl_player"}) do
		local t = rawget(_G, api)
		for name in pairs(type(t) == "table" and type(t.registered_models) == "table" and t.registered_models or {}) do
			meshes[name] = true
		end
	end
	for mesh in pairs(meshes) do
		local path = paths[mesh]
		if path and mesh:lower():match("%.b3d$") then
			local f = io.open(path, "rb")
			local data = f and f:read("*a")
			if f then f:close() end
			local ok, out, bones = pcall(function()
				local model = data and R.models.parse_b3d(data)
				if model then return R.models.b3d_aliases(data, model) end
			end)
			if ok and out then
				local name = "ragdoll_" .. mesh
				if core.dynamic_add_media({filename = name, filedata = out}) then
					R.mesh_aliases[mesh] = {mesh = name, bones = bones}
				end
			end
		end
	end
end

-- (indexed once everything has loaded, so the first death doesn't hitch)
core.register_on_mods_loaded(function()
	if not paths then index_models() end
	make_aliases()
end)

local rigs = {}
function R.get_rig(mesh)
	if rigs[mesh] ~= nil then return rigs[mesh] or nil end
	if not paths then index_models() end
	local path = paths[mesh]
	local rig = false
	if path then
		local f = io.open(path, "rb")
		local data = f and f:read("*a")
		if f then f:close() end
		if data then
			local ok, model = pcall(function()
				local ext = mesh:match("%.(%w+)$"):lower()
				if ext == "b3d" then return R.models.parse_b3d(data) end
				local dir = path:match("^(.*)/[^/]+$")
				return R.models.parse_gltf(data, core.parse_json, function(uri)
					local h = io.open(dir .. "/" .. uri, "rb")
					local d = h and h:read("*a")
					if h then h:close() end
					return d
				end)
			end)
			if ok and model then
				local ok2, r = pcall(R.models.analyze, model)
				if ok2 and r then rig = r
				elseif not ok2 then core.log("warning", "[ragdoll] can't rig " .. mesh .. ": " .. tostring(r)) end
			elseif not ok then
				core.log("warning", "[ragdoll] can't read " .. mesh .. ": " .. tostring(model))
			end
		end
	end
	rigs[mesh] = rig
	return rig or nil
end

dofile(modpath .. "/body.lua")

--------------------------------------------------------------------------------
-- The ragdoll entities
--------------------------------------------------------------------------------
local tracked = setmetatable({}, {__mode = "k"})
core.register_entity("ragdoll:body", {
	initial_properties = {
		visual = "mesh", physical = false, pointable = false, collide_with_objects = false,
		static_save = false, collisionbox = {0, 0, 0, 0, 0, 0}, selectionbox = {0, 0, 0, 0, 0, 0},
		makes_footstep_sound = false, shaded = true, backface_culling = false,
	},
	on_activate = function(self) self.object:set_armor_groups({immortal = 1}) end,
	on_step = function(self)
		if not tracked[self] and not self.keep then self.object:remove() end
	end,
	-- (explosions throw the simulated body, not this object - see R.blast)
	on_blast = function() return false, false, {} end,
})
core.register_entity("ragdoll:part", {
	initial_properties = {
		visual = "wielditem", physical = false, pointable = false, collide_with_objects = false,
		static_save = false, collisionbox = {0, 0, 0, 0, 0, 0}, selectionbox = {0, 0, 0, 0, 0, 0},
	},
	on_activate = function(self) self.object:set_armor_groups({immortal = 1}) end,
	on_step = function(self)
		local p = self.object:get_attach()
		if not p then self.object:remove() end
	end,
	on_blast = function() return false, false, {} end,
})

local COPY = {"visual", "mesh", "textures", "colors", "visual_size", "use_texture_alpha", "backface_culling", "glow",
	"shaded", "wield_item", "spritediv", "initial_sprite_basepos", "damage_texture_modifier"}
local function look_of(props)
	local out = {physical = false, pointable = false, collide_with_objects = false, static_save = false,
		nametag = "", infotext = "", show_on_minimap = false, makes_footstep_sound = false, automatic_rotate = 0,
		automatic_face_movement_dir = false, is_visible = true}
	for _, k in ipairs(COPY) do
		if props[k] ~= nil then out[k] = type(props[k]) == "table" and table.copy(props[k]) or props[k] end
	end
	return out
end

--------------------------------------------------------------------------------
-- Hits: the punch that killed someone pushes the body
--------------------------------------------------------------------------------
local player_hits = {}
-- (kept beside the mobs, not on them: mob APIs save every field of a mob, and
-- a hit holds the attacker's object)
local entity_hits = setmetatable({}, {__mode = "k"})
local function power_of(damage, caps)
	local d = tonumber(damage) or 0
	if d <= 0 and caps and caps.damage_groups then d = caps.damage_groups.fleshy or 0 end
	return math.min(6, 1.5 + math.max(0, d) * 0.2)
end
-- (puncher, tflp: optional; they let the game's own knockback be worked out)
function R.note_hit(target, dir, damage, caps, puncher, tflp)
	if not dir then return end
	local rec = {dir = vector.copy(dir), power = power_of(damage, caps), t = core.get_us_time(),
		damage = damage, caps = caps, puncher = puncher, tflp = tflp}
	if target:is_player() then
		player_hits[target:get_player_name()] = rec
	else
		local le = target:get_luaentity()
		if le then entity_hits[le] = rec end
	end
	return rec
end
local function recent_hit(obj)
	local rec
	if obj:is_player() then rec = player_hits[obj:get_player_name()]
	else
		local le = obj:get_luaentity()
		rec = le and entity_hits[le]
	end
	if rec and core.get_us_time() - rec.t < 1.5e6 then return rec end
	return nil
end
R.recent_hit = recent_hit
core.register_on_punchplayer(function(player, hitter, tflp, caps, dir, damage)
	local rec = R.note_hit(player, dir, damage, caps, hitter, tflp)
	-- the knockback the game gives players (worked out now: it depends on
	-- where both stand and what the hitter holds)
	if rec and R.knockback then rec.kb = R.knockback.player(player, hitter, tflp, caps, dir, damage) end
end)

--------------------------------------------------------------------------------
-- Snapshot and spawn
--------------------------------------------------------------------------------
-- Everything needed to rebuild `obj` as a ragdoll; take it before the death
-- code starts changing the object. opts: frame, textures, texture_mod,
-- strip (texture modifier to remove: a damage tint), hit = {dir, power, splash}
function R.snapshot(obj, opts)
	opts = opts or {}
	if not obj or not obj:get_pos() then return nil end
	local props = obj:get_properties()
	if not props then return nil end
	local snap = {props = props, pos = obj:get_pos()}
	if obj:is_player() then
		snap.rot = vector.new(0, obj:get_look_horizontal(), 0)
		snap.name = obj:get_player_name()
	else
		snap.rot = obj:get_rotation() or vector.new(0, obj:get_yaw() or 0, 0)
		local le = obj:get_luaentity()
		snap.name = le and le.name
	end
	snap.vel = obj:get_velocity() or vector.zero()
	local range = obj:get_animation()
	snap.frame = opts.frame or (type(range) == "table" and range.x) or 0
	snap.texture_mod = opts.texture_mod
	if snap.texture_mod == nil and obj.get_texture_mod then snap.texture_mod = obj:get_texture_mod() end
	if opts.textures then props.textures = table.copy(opts.textures) end
	if opts.strip then
		local function strip(s) return type(s) == "string" and (s:gsub(opts.strip:gsub("%p", "%%%0"), "")) or s end
		for i, t in ipairs(props.textures or {}) do props.textures[i] = strip(t) end
		snap.texture_mod = strip(snap.texture_mod)
	end
	snap.hit = opts.hit or recent_hit(obj)
	snap.is_player = obj:is_player()
	-- the game's own knockback for the killing hit (the mob API hooks work it
	-- out; players get it when they're hit)
	snap.kb = opts.kb
	if snap.kb == nil and snap.is_player and snap.hit then snap.kb = snap.hit.kb end
	snap.profile = (snap.name and R.profiles[snap.name]) or (props.mesh and R.profiles[props.mesh]) or nil
	-- things attached to it (held items, hats...) come along
	snap.children = {}
	if obj.get_children then
		for _, c in ipairs(obj:get_children()) do
			local cle = not c:is_player() and c:get_luaentity()
			local cname = cle and cle.name or ""
			-- (held items, armor, hats: yes; fire, nametags, health bars: no)
			if cle and #snap.children < 8 and not cname:find("fire") and not cname:find("flame")
					and not cname:find("burn") and not cname:find("nametag") and not cname:find("hp")
					and not cname:find("health") and not cname:find("particle") then
				local parent, bone, cpos, crot, fv = c:get_attach()
				local cp = c:get_properties()
				if parent and cp and cp.visual and cp.visual ~= "" and cp.visual ~= "sprite"
						and cp.visual ~= "upright_sprite" and (cp.is_visible ~= false) then
					snap.children[#snap.children + 1] = {props = cp, bone = bone or "", pos = cpos, rot = crot, fv = fv}
				end
			end
		end
	end
	return snap
end

local function visible(props)
	if not props.visual or props.visual == "" then return false end
	local vs = props.visual_size
	if vs and (vs.x or 1) == 0 and (vs.y or 1) == 0 then return false end
	return props.is_visible ~= false
end

-- Make the ragdoll; returns its object (or nil).
function R.spawn(snap, source)
	if not snap or not snap.pos or not snap.props or not visible(snap.props) then return nil end
	if snap.profile and snap.profile.disable then return nil end
	local obj = core.add_entity(snap.pos, "ragdoll:body")
	if not obj then return nil end
	local props = look_of(snap.props)
	local alias = props.mesh and R.mesh_aliases[props.mesh]
	if alias then props.mesh = alias.mesh end
	obj:set_properties(props)
	if props.visual == "mesh" then
		local f = (snap.profile and snap.profile.frame) or snap.frame or 0
		obj:set_animation({x = f, y = f}, 0, 0, false)
	end
	-- (a blast that has just gone off nearby threw it)
	if snap.blasts == nil and R.knockback then snap.blasts = R.knockback.blasts_at(snap.pos) end
	local ok, b = pcall(R.build, obj, snap)
	if not ok or not b then
		core.log("warning", "[ragdoll] couldn't build a ragdoll for " .. tostring(snap.name) .. ": " .. tostring(b))
		obj:remove()
		return nil
	end
	local tm = snap.texture_mod or ""
	b.texture_mod = tm
	if R.setting("flash") then
		-- (multiply keeps transparent layers - armor, overlays - transparent)
		obj:set_texture_mod(tm .. "^[multiply:#ff6a6a")
		core.after(0.35, function() if obj:is_valid() and not b.fade then obj:set_texture_mod(tm) end end)
	elseif tm ~= "" then
		obj:set_texture_mod(tm)
	end
	tracked[obj:get_luaentity()] = true
	b.name = snap.name
	R.add_body(b)
	for _, c in ipairs(snap.children or {}) do
		local part = core.add_entity(snap.pos, "ragdoll:part")
		if part then
			part:set_properties(look_of(c.props))
			part:set_attach(obj, c.bone, c.pos, c.rot, c.fv)
		end
	end
	for _, f in ipairs(spawn_callbacks) do pcall(f, obj, snap, source) end
	return obj
end

-- Both in one go (the object must still exist).
function R.spawn_from(obj, opts)
	return R.spawn(R.snapshot(obj, opts), obj)
end

-- Is this mob (a luaentity) one that should get a ragdoll?
function R.enabled_for(le)
	if not le or not R.setting("mobs") then return false end
	local p = R.profiles[le.name]
	if p and p.disable then return false end
	if le._ragdoll == false then return false end
	local def = core.registered_entities[le.name]
	if def and def._ragdoll == false then return false end
	return true
end

-- Hide an object that the game removes later on its own.
function R.hide_object(obj)
	if not obj or not obj:get_pos() then return end
	obj:set_properties({visual_size = {x = 0, y = 0, z = 0}, pointable = false, nametag = "", show_on_minimap = false})
	if obj.get_children then
		for _, c in ipairs(obj:get_children()) do
			if not c:is_player() then c:set_properties({visual_size = {x = 0, y = 0, z = 0}}) end
		end
	end
end

--------------------------------------------------------------------------------
-- Players: the body falls as a ragdoll, the real one is hidden until respawn
--------------------------------------------------------------------------------
local hidden = {}
function R.hide_player(player)
	local name = player:get_player_name()
	if hidden[name] then return end
	local p = player:get_properties()
	local nt = player:get_nametag_attributes()
	hidden[name] = {visual_size = p.visual_size, pointable = p.pointable, nametag = nt, children = {}}
	-- (the engine always draws players: shrink them to nothing instead)
	player:set_properties({visual_size = {x = 0, y = 0, z = 0}, pointable = false})
	player:set_nametag_attributes({color = {a = 0, r = 255, g = 255, b = 255}, bgcolor = {a = 0, r = 0, g = 0, b = 0}})
	for _, c in ipairs(player:get_children() or {}) do
		if not c:is_player() then
			local cp = c:get_properties()
			hidden[name].children[#hidden[name].children + 1] = {obj = c, visual_size = cp.visual_size}
			c:set_properties({visual_size = {x = 0, y = 0, z = 0}})
		end
	end
end

function R.show_player(player)
	local name = player:get_player_name()
	local h = hidden[name]
	if not h then return end
	hidden[name] = nil
	player:set_properties({visual_size = h.visual_size, pointable = h.pointable})
	if h.nametag then player:set_nametag_attributes(h.nametag) end
	for _, c in ipairs(h.children) do
		if c.obj:is_valid() then c.obj:set_properties({visual_size = c.visual_size}) end
	end
end

core.register_on_dieplayer(function(player)
	if not R.setting("players") or R.players_disabled then return end
	local snap = R.snapshot(player)
	if snap and R.spawn(snap, player) then R.hide_player(player) end
end)
core.register_on_respawnplayer(function(player)
	local name = player:get_player_name()
	core.after(0, function()
		local p = core.get_player_by_name(name)
		if p then R.show_player(p) end
	end)
end)
core.register_on_joinplayer(function(player) hidden[player:get_player_name()] = nil end)
core.register_on_leaveplayer(function(player)
	hidden[player:get_player_name()] = nil
	player_hits[player:get_player_name()] = nil
end)

-- /ragdoll: how many bodies and what they cost; /ragdoll clear removes them
local last_us, last_frames = 0, 0
core.register_chatcommand("ragdoll", {
	params = "[clear]",
	description = "Ragdoll count and cost (\"clear\" removes them all)",
	func = function(name, param)
		if param == "clear" then
			if not core.check_player_privs(name, {server = true}) then return false, "Needs the server privilege." end
			local n = 0
			for _, b in ipairs(R.bodies) do
				if b.obj:is_valid() then b.obj:remove() n = n + 1 end
			end
			return true, n .. " ragdolls removed."
		end
		local awake = 0
		for _, b in ipairs(R.bodies) do if not b.asleep and not b.dead then awake = awake + 1 end end
		local us, frames = R.stats.us - last_us, R.stats.frames - last_frames
		last_us, last_frames = R.stats.us, R.stats.frames
		return true, string.format("%d ragdolls (%d moving), %.2f ms of Lua per server step since last asked.",
			#R.bodies, awake, frames > 0 and us / frames / 1000 or 0)
	end,
})

dofile(modpath .. "/knockback.lua")
dofile(modpath .. "/hooks.lua")
