# Ragdoll

  When a player or a mob dies, its body falls as a physics ragdoll. This replaces
the death animation, the tipping over, the fading or the vanishing it would
otherwise do.
  It works in any game and needs no setup per mob. The mod reads each mob's model
file (`.b3d`, `.gltf` or `.glb`) and works out a rig from its bones: the torso,
plus the limbs hanging off it (legs, arms, wings, tails, heads, two-segment
legs, armor overlays). Models without bones, and cube or sprite mobs, fall as
rigid bodies.

## Supported

| Players in any game (Minetest Game, VoxeLibre, MineClone2, Mineclonia, Exile, CTF...) | Skins, armor and held items come along. The real body is hidden until respawn. |
| Mobs Redo (`mobs`), with mobs_animal, mobs_monster and other packs | `death_anim` is replaced. Drops, sounds, `on_die` and `on_death` still run. |
| mcl_mobs (VoxeLibre, MineClone2, Mineclonia) | The death is made instant (drops, xp, sounds and awards all run). The tip-over and smoke are skipped. |
| mobkit | `mobkit.hq_die` is replaced. |
| mob_core | `mob_core.on_die` is replaced. Drops and the death sound still run. |
| Creatura (Animalia and others) | Animalia's die utility is replaced. Any other Creatura mob that falls over gets a ragdoll, and its real body is hidden. |

The killing hit throws the body the way the game's own knockback would have
thrown the creature, and about as far: each mob API's formula is worked out
for that hit (weapon, enchantments, a running attacker, how charged the swing
was), along with how far that API's movement would have carried it. Players
get the game's `core.calculate_knockback`, overrides included. Mobs with no
knockback of their own get a push from the damage. By default bodies go a
quarter as far and as high as that (`ragdoll_impulse` = 0.25; at 1 they get
the game's full knockback - VoxeLibre throws killed mobs about 18 nodes, and
much further with Knockback enchantments, up to a 60 m/s cap).

Explosions throw bodies too, both the ones they kill and the ones already
lying around, with the game's own blast knockback: Minetest Game's
`tnt.boom`, `mcl_explosions` (VoxeLibre, MineClone2, Mineclonia) and Mobs
Redo's explosions. By default half again as hard as the game's own blast
(`ragdoll_blast` = 1.5; at 1, the game's full blast). Before scaling, a body
stops at 25 m/s.


`/ragdoll` shows how many bodies there are and what they cost.
`/ragdoll clear` removes them all (needs the `server` privilege).

## For modders

```lua
-- Opt a mob out, in its entity definition:
_ragdoll = false

-- Or from another mod, by entity name or mesh file:
ragdoll.exclude("mymod:boss")
ragdoll.register_profile("mymod:golem", {
	rigid_only = true,                 -- fall as one stiff body
	skip_bones = {Antenna = true},     -- don't flop these
	max_angle = {Head = 0.4},          -- how far a limb may swing (radians)
	frame = 0,                         -- animation frame to freeze the body at
})

-- Make a ragdoll yourself (the object must still exist). Do it before your
-- death code changes the object, then remove the object:
ragdoll.spawn_from(obj, {hit = {dir = dir, power = 4}})
-- or in two steps:
local snap = ragdoll.snapshot(obj, {frame = 0, texture_mod = "", strip = "^[colorize:#ff0000:100"})
obj:remove()
ragdoll.spawn(snap)

-- A game with its own player deaths can turn the player hook off:
ragdoll.players_disabled = true

-- Your own explosion: throws the bodies around it, and the bodies of whatever
-- it kills in the next moment (power: m/s one node away, less further out).
-- Call it just before the explosion hurts anything:
ragdoll.blast({pos = pos, radius = 5, power = 20})

ragdoll.register_on_spawn(function(body, snapshot, source) end)
ragdoll.body_pos(body)                    -- where the body is (e.g. for death cams)
ragdoll.hide_player(player); ragdoll.show_player(player)
```
## Limits

- Needs Luanti 5.9 or newer (bone overrides).
- Limbs are found for `.b3d`, `.gltf` and `.glb` models. `.x` and `.obj` mobs
  fall as rigid bodies.
- Bodies don't collide with players or other bodies, and they aren't saved when
  their area unloads.
- A mob whose death code does something special (it explodes, splits, or turns
  into something else) may need `_ragdoll = false` or a profile.
