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

-- names of the real recipes making `item` (recycling and other hidden recipes left out: they're always enabled)
local function recipes_for(item)
  local list = {}
  for name, r in pairs(prototypes.get_recipe_filtered({
    { filter = "has-product-item", elem_filters = { { filter = "name", name = item } } } })) do
    if not r.hidden and r.category ~= "recycling" then list[#list + 1] = name end
  end
  return list
end

-- the pipe that matches an underground: the pipe its recipe is made from, else its name without "-to-ground"
-- (steel-pipe-to-ground -> steel-pipe, kr-steel-pipe-to-ground -> kr-steel-pipe)
local function matching_pipe(ug)
  local proto = prototypes.entity[ug]
  for _, item in pairs(proto.items_to_place_this or {}) do
    for _, rn in pairs(recipes_for(item.name)) do
      for _, ing in pairs(prototypes.recipe[rn].ingredients) do
        local it = ing.type == "item" and prototypes.item[ing.name]
        local res = it and it.place_result
        if res and is_type(res.name, "pipe") then return res.name end
      end
    end
  end
  local base = ug:gsub("%-to%-ground$", "")
  if base ~= ug and is_type(base, "pipe") then return base end
end

-- connection categories of a prototype's normal (above-ground) pipe connections
local function categories(proto)
  local set = {}
  for _, fb in pairs(proto.fluidbox_prototypes or {}) do
    for _, c in pairs(fb.pipe_connections or {}) do
      if c.connection_type == "normal" then
        for _, cat in pairs(c.connection_category or { "default" }) do set[cat] = true end
      end
    end
  end
  return set
end

-- every pipe that can go into an underground's gap, best match first:
-- the matching pipe, then plain "pipe", then the rest by name. Pipes that can't connect to it are left out.
local cand_cache = {}
local function pipe_candidates(ug)
  local list = cand_cache[ug]
  if list then return list end
  list = {}
  local cats, seen = categories(prototypes.entity[ug]), {}
  local function add(n, match)
    if not n or seen[n] or not is_type(n, "pipe") then return false end
    seen[n] = true
    for cat in pairs(categories(prototypes.entity[n])) do
      if cats[cat] then
        list[#list + 1] = { name = n, item = prototypes.entity[n].items_to_place_this[1].name, match = match }
        return true
      end
    end
    return false
  end
  local matched = add(matching_pipe(ug), true)
  add("pipe", not matched)
  local rest = {}
  for n in pairs(prototypes.get_entity_filtered({ { filter = "type", type = "pipe" } })) do rest[#rest + 1] = n end
  table.sort(rest)
  for _, n in ipairs(rest) do add(n, false) end
  cand_cache[ug] = list
  return list
end

local function researched(item, force)
  for _, name in pairs(recipes_for(item)) do
    local r = force.recipes[name]
    if r and r.enabled then return true end
  end
  return false
end

-- picks the pipe for an underground's gap by the player's "Pipe choice":
--   match       the pipe that matches the underground (steel with steel), then one you have, can craft, researched
--   have        one in your inventory, then one you can hand-craft, then the matching one
--   researched  only pipes whose recipe is researched (or that you carry), matching first
-- has(item) / craftable(item) answer for the player; ties go to the earlier candidate.
local function pick_pipe(ug, mode, force, has, craftable)
  local best, best_score
  for _, c in ipairs(pipe_candidates(ug)) do
    local m, h = c.match and 1 or 0, has(c.item) and 1 or 0
    local k, r = (h == 0 and craftable(c.item)) and 1 or 0, researched(c.item, force) and 1 or 0
    local score
    if mode == "have" then score = h * 8 + k * 4 + m * 2 + r
    elseif mode == "researched" then score = (r + h > 0) and (m * 4 + h * 2 + k + 1) or nil
    else score = m * 8 + h * 4 + k * 2 + r end
    if score and (not best_score or score > best_score) then best, best_score = c.name, score end
  end
  return best
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
    if t == "pipe-to-ground" then
      local c = pipe_candidates(ug)[1]
      v = c and c.name or false
    else
      v = belt_for(ug) or false
    end
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

  local free = not player or player.controller_type == defines.controllers.editor
  local inv = player and not free and player.get_main_inventory()
  if t_ == "pipe-to-ground" and player then
    name = pick_pipe(ug, player.mod_settings["ugf-pipe-choice"].value, force,
      function(item) return inv and inv.get_item_count({ name = item, quality = quality }) > 0 end,
      function(item)
        if free then return false end
        for _, r in pairs(recipes_for(item)) do
          local ok, n = pcall(player.get_craftable_count, r)
          if ok and n > 0 then return true end
        end
        return false
      end)
    if not name then return end
  end
  local item = prototypes.entity[name].items_to_place_this[1].name
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
  fill_cache, cand_cache, blocked = {}, {}, nil
end)
script.on_event(defines.events.on_runtime_mod_setting_changed, function(ev)
  if ev.setting == "ugf-blocked" then fill_cache, cand_cache, blocked = {}, {}, nil end
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
    fill_cache, cand_cache, blocked = {}, {}, nil
  end,
  -- the pipe `mode` ("match" / "have" / "researched") picks for underground `ug`, for a force holding `have`
  -- ({ [item] = count }); tests: headless games have no players
  pick_pipe = function(ug, mode, force, have)
    have = have or {}
    return pick_pipe(ug, mode, game.forces[force or "player"],
      function(item) return (have[item] or 0) > 0 end, function() return false end)
  end,
  fill_name = function(ug)
    local p = prototypes.entity[ug]
    return p and fill_name(p.type, ug)
  end,
})
