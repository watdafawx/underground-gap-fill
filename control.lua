-- Underground Gap Fill: puts a pipe or belt into the one-tile gap after an underground.
-- Builds are only queued; the gap is filled once the player has built nothing for DELAY ticks,
-- so the game's drag-build never meets one of our entities in its path (full underground range).

local DELAY = 30

-- 2.0 directions: north 0, east 4, south 8, west 12
local VEC = { [0] = { 0, -1 }, [4] = { 1, 0 }, [8] = { 0, 1 }, [12] = { -1, 0 } }
local CARDINAL = { 0, 4, 8, 12 }
local function opposite(d) return (d + 8) % 16 end

-- things that may stand on the gap without blocking it
local PASSABLE = { character = true, ["tile-ghost"] = true, corpse = true, ["character-corpse"] = true }

local function tile(x, y) return { x = math.floor(x) + 0.5, y = math.floor(y) + 0.5 } end
local function step(p, d, sign)
  local v = VEC[d]
  sign = sign or 1
  return tile(p.x + v[1] * sign, p.y + v[2] * sign)
end
local function same_tile(a, b) return math.floor(a.x) == math.floor(b.x) and math.floor(a.y) == math.floor(b.y) end

local function kind(e)
  if e.type == "entity-ghost" then return e.ghost_type, e.ghost_name, true end
  return e.type, e.name, false
end

---------------------------------------------------------------------------------------------------
-- which pipe / belt goes with an underground (cached per session: derived from prototypes only)

local fill_cache = {}
local blocked -- set of entity names from the "ugf-blocked" setting (read lazily, reset with fill_cache)

local function is_blocked(name)
  if not blocked then
    blocked = {}
    for n in string.gmatch(settings.global["ugf-blocked"].value, "[^%s,;]+") do blocked[n] = true end
  end
  return blocked[name]
end

local function is_type(name, t)
  local p = name and not is_blocked(name) and prototypes.entity[name]
  return p and p.type == t and p.items_to_place_this and p.items_to_place_this[1] and true or false
end

local function pipe_for(ug)
  -- 1. the pipe its recipe is made from
  local proto = prototypes.entity[ug]
  for _, item in pairs(proto.items_to_place_this or {}) do
    local recipes = prototypes.get_recipe_filtered({
      { filter = "has-product-item", elem_filters = { { filter = "name", name = item.name } } } })
    for _, r in pairs(recipes) do
      for _, ing in pairs(r.ingredients) do
        local it = ing.type == "item" and prototypes.item[ing.name]
        local res = it and it.place_result
        if res and is_type(res.name, "pipe") then return res.name end
      end
    end
  end
  -- 2. its name without "-to-ground" (steel-pipe-to-ground -> steel-pipe, kr-steel-pipe-to-ground -> kr-steel-pipe)
  local base = ug:gsub("%-to%-ground$", "")
  if base ~= ug and is_type(base, "pipe") then return base end
  -- 3. the plain pipe
  if is_type("pipe", "pipe") then return "pipe" end
end

local function belt_for(ug)
  local proto = prototypes.entity[ug]
  local ok, rel = pcall(function() return proto.related_transport_belt end)
  if ok and rel and is_type(rel.name, "transport-belt") then return rel.name end
  -- same speed, first by name (blocked names skipped by is_type)
  local best
  for name, p in pairs(prototypes.get_entity_filtered({ { filter = "type", type = "transport-belt" } })) do
    if p.belt_speed == proto.belt_speed and is_type(name, "transport-belt") and (not best or name < best) then
      best = name
    end
  end
  return best
end

local function fill_name(t, ug)
  local key = t .. "/" .. ug
  local v = fill_cache[key]
  if v == nil then
    v = (t == "pipe-to-ground" and pipe_for(ug) or belt_for(ug)) or false
    fill_cache[key] = v
  end
  return v or nil
end

---------------------------------------------------------------------------------------------------
-- finding the gap and what is on its far side

-- the tile a pipe-to-ground's above-ground side opens onto
local function pipe_gap(e, ghost)
  if not ghost then
    for i = 1, #e.fluidbox do
      for _, c in pairs(e.fluidbox.get_pipe_connections(i)) do
        if c.connection_type == "normal" then return tile(c.target_position.x, c.target_position.y) end
      end
    end
    return nil
  end
  return VEC[e.direction] and step(e.position, e.direction) or nil
end

-- does anything other than `self` (and other than plain pipes) connect into the gap tile `t`?
local function pipe_partner(e, t)
  local s = e.surface
  local found = s.find_entities_filtered({ area = { { t.x - 1.5, t.y - 1.5 }, { t.x + 1.5, t.y + 1.5 } }, force = e.force })
  for _, o in pairs(found) do
    if o ~= e and not same_tile(o.position, t) then
      local ot, _, oghost = kind(o)
      if oghost then
        if ot == "pipe-to-ground" and VEC[o.direction] and same_tile(step(o.position, o.direction), t) then return true end
      elseif ot ~= "pipe" and ot ~= "infinity-pipe" and ot ~= "fluid-wagon" then
        local ok, hit = pcall(function()
          local fb = o.fluidbox
          for i = 1, #fb do
            for _, c in pairs(fb.get_pipe_connections(i)) do
              if c.connection_type == "normal" and same_tile(c.target_position, t) then return true end
            end
          end
          return false
        end)
        if ok and hit then return true end
      end
    end
  end
  return false
end

local function underground_at(s, force, p, want_type, want_dir)
  for _, o in pairs(s.find_entities_filtered({ position = p, force = force })) do
    local ot, _, oghost = kind(o)
    if ot == "underground-belt" and o.direction == want_dir then
      local ok, bt = pcall(function() return o.belt_to_ground_type end)
      if ok and bt == want_type then return o end
      if not ok and oghost then return nil end
    end
  end
end

-- gap tile and the direction the filling belt faces
local function belt_gap(e)
  local d = e.direction
  if not VEC[d] then return end
  local ok, bt = pcall(function() return e.belt_to_ground_type end)
  if not ok then return end
  local s, f = e.surface, e.force
  if bt == "output" then
    local t = step(e.position, d)
    for _, v in pairs(CARDINAL) do
      if v ~= opposite(d) and underground_at(s, f, step(t, v), "input", v) then return t, v end
    end
  else
    local t = step(e.position, d, -1)
    for _, v in pairs(CARDINAL) do
      if v ~= opposite(d) and underground_at(s, f, step(t, v, -1), "output", v) then return t, d end
    end
  end
end

---------------------------------------------------------------------------------------------------
-- placing

local function occupied(s, t)
  for _, o in pairs(s.find_entities_filtered({ position = t })) do
    if not PASSABLE[o.type] then return true end
  end
  return false
end

-- returns the entity placed (real or ghost), or nil
local function fill(e, player)
  if not (e and e.valid) then return end
  local t_, ug, ghost = kind(e)
  local name = fill_name(t_, ug)
  if not name then return end
  local gap, dir
  if t_ == "pipe-to-ground" then
    gap = pipe_gap(e, ghost)
    if not gap or not pipe_partner(e, gap) then return end
  elseif t_ == "underground-belt" then
    gap, dir = belt_gap(e)
    if not gap then return end
  else
    return
  end
  local s, force, quality = e.surface, e.force, e.quality.name
  if occupied(s, gap) then return end

  local item = prototypes.entity[name].items_to_place_this[1].name
  local free = not player or player.controller_type == defines.controllers.editor
  local inv = player and not free and player.get_main_inventory()
  local real = not ghost and (free or (inv and inv.get_item_count({ name = item, quality = quality }) > 0))
  local spec = { name = name, position = gap, direction = dir, force = force, quality = quality }

  if real then
    spec.build_check_type = defines.build_check_type.manual
    real = s.can_place_entity(spec)
  end
  if not real then
    spec.inner_name, spec.name = name, "entity-ghost"
    spec.build_check_type = defines.build_check_type.script_ghost
    -- a ghost skips the fluid-mixing check: run the manual one for it, ignoring only the missing item
    local check = { name = name, position = gap, direction = dir, force = force, build_check_type = defines.build_check_type.manual }
    if not s.can_place_entity(spec) or not s.can_place_entity(check) then return end
  end
  spec.build_check_type = nil
  spec.player = player
  spec.raise_built = true
  local placed = s.create_entity(spec)
  if placed and real and inv then inv.remove({ name = item, quality = quality, count = 1 }) end
  return placed
end

---------------------------------------------------------------------------------------------------
-- queue: wait for the drag to end

local function on_tick(ev)
  for pi, q in pairs(storage.queue) do
    if ev.tick - q.last >= DELAY then
      storage.queue[pi] = nil
      local player = game.get_player(pi)
      if player and player.valid then
        for _, e in pairs(q.list) do fill(e, player) end
      end
    end
  end
  if not next(storage.queue) then script.on_event(defines.events.on_tick, nil) end
end

local function on_built(ev)
  local e = ev.entity
  if not (e and e.valid) then return end
  local player = game.get_player(ev.player_index)
  if not player then return end
  local t = kind(e)
  local key = t == "pipe-to-ground" and "ugf-pipes" or "ugf-belts"
  if not player.mod_settings[key].value then return end
  local q = storage.queue[ev.player_index]
  if not q then
    q = { list = {} }
    storage.queue[ev.player_index] = q
  end
  q.list[#q.list + 1] = e
  q.last = ev.tick
  script.on_event(defines.events.on_tick, on_tick)
end

-- any build by the player pushes the fill back: a drag of pipes can place undergrounds itself
local function on_pre_build(ev)
  local q = storage.queue[ev.player_index]
  if q then q.last = ev.tick end
end

script.on_init(function() storage.queue = {} end)
script.on_configuration_changed(function()
  storage.queue = storage.queue or {}
  fill_cache, blocked = {}, nil
end)
script.on_event(defines.events.on_runtime_mod_setting_changed, function(ev)
  if ev.setting == "ugf-blocked" then fill_cache, blocked = {}, nil end
end)
script.on_load(function()
  if storage.queue and next(storage.queue) then script.on_event(defines.events.on_tick, on_tick) end
end)

script.on_event(defines.events.on_built_entity, on_built, {
  { filter = "type", type = "pipe-to-ground" }, { filter = "ghost_type", type = "pipe-to-ground" },
  { filter = "type", type = "underground-belt" }, { filter = "ghost_type", type = "underground-belt" },
})
script.on_event(defines.events.on_pre_build, on_pre_build)

remote.add_interface("underground-gap-fill", {
  -- fill the gap after `entity` now (tests: headless games have no players); returns the entity placed
  fill = function(entity, player_index)
    return fill(entity, player_index and game.get_player(player_index) or nil)
  end,
  -- set the "Never fill with" setting (names separated by commas or spaces)
  set_blocked = function(names)
    settings.global["ugf-blocked"] = { value = names or "" }
    fill_cache, blocked = {}, nil
  end,
  fill_name = function(ug)
    local p = prototypes.entity[ug]
    return p and fill_name(p.type, ug)
  end,
})
