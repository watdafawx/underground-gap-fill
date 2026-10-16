-- builds gap layouts with create_entity, fills each through the remote, checks what landed in the gap
local out, fails = {}, 0
local function log(s) out[#out + 1] = s end
local function check(ok, what)
  if not ok then fails = fails + 1 end
  log((ok and "ok   " or "FAIL ") .. what)
end

script.on_nth_tick(5, function(ev)
  if ev.tick ~= 5 then return end
  local s = game.surfaces.nauvis
  local f = game.forces.player
  local area = { { -10, -10 }, { 60, 40 } }
  for _, e in pairs(s.find_entities_filtered({ area = area })) do e.destroy() end
  local tiles = {}
  for x = -10, 60 do for y = -10, 40 do tiles[#tiles + 1] = { name = "lab-dark-1", position = { x, y } } end end
  s.set_tiles(tiles)

  local D = defines.direction
  local function make(name, x, y, dir, extra)
    local spec = { name = name, position = { x, y }, direction = dir, force = f }
    for k, v in pairs(extra or {}) do spec[k] = v end
    local e = s.create_entity(spec)
    assert(e, "can't place " .. name .. " at " .. x .. "," .. y)
    return e
  end
  local function fill(e) return remote.call("underground-gap-fill", "fill", e) end
  local function at(x, y)
    for _, o in pairs(s.find_entities_filtered({ position = { x, y } })) do return o end
  end

  -- convention: a pipe-to-ground's direction is the side its pipe connection opens onto
  local conv = make("pipe-to-ground", -5.5, -5.5, D.north)
  local c = conv.fluidbox.get_pipe_connections(1)[1]
  check(c.connection_type == "normal" and c.target_position.x == -5.5 and c.target_position.y == -6.5,
    "pipe-to-ground north opens north: " .. serpent.line(c.target_position))

  -- pipes
  local a = make("pipe-to-ground", 0.5, 0.5, D.east)
  make("pipe-to-ground", 2.5, 0.5, D.west)
  local p = fill(a)
  check(p and p.name == "pipe" and p.position.x == 1.5 and p.position.y == 0.5, "pipe straight gap filled")

  a = make("pipe-to-ground", 6.5, 0.5, D.east)
  make("pipe-to-ground", 7.5, 1.5, D.north)
  p = fill(a)
  check(p and p.name == "pipe" and p.position.x == 7.5 and p.position.y == 0.5, "pipe corner gap filled")

  local tank = make("storage-tank", 14.5, 1.5, D.north)
  local tc = tank.fluidbox.get_pipe_connections(1)[1]
  local vx, vy = tc.target_position.x - tc.position.x, tc.target_position.y - tc.position.y
  local dir = vx > 0 and D.west or vx < 0 and D.east or vy > 0 and D.north or D.south
  a = make("pipe-to-ground", tc.target_position.x + vx, tc.target_position.y + vy, dir)
  p = fill(a)
  check(p and p.position.x == tc.target_position.x and p.position.y == tc.target_position.y, "pipe into storage tank")

  a = make("pipe-to-ground", 0.5, 5.5, D.east)
  local b = make("pipe-to-ground", 2.5, 5.5, D.west)
  a.insert_fluid({ name = "water", amount = 10 })
  b.insert_fluid({ name = "crude-oil", amount = 10 })
  check(fill(a) == nil and at(1.5, 5.5) == nil, "fluid mixing gap left empty")

  a = make("entity-ghost", 6.5, 5.5, D.east, { inner_name = "pipe-to-ground" })
  make("pipe-to-ground", 8.5, 5.5, D.west)
  p = fill(a)
  check(p and p.name == "entity-ghost" and p.ghost_name == "pipe", "ghost underground gets a ghost pipe")

  a = make("pipe-to-ground", 12.5, 5.5, D.east)
  make("pipe-to-ground", 14.5, 5.5, D.west)
  make("wooden-chest", 13.5, 5.5)
  check(fill(a) == nil, "occupied gap left alone")

  a = make("pipe-to-ground", 18.5, 5.5, D.east)
  make("pipe", 19.5, 6.5)
  check(fill(a) == nil and at(19.5, 5.5) == nil, "a plain pipe beside the gap doesn't count")

  check(fill(make("pipe-to-ground", 24.5, 5.5, D.east)) == nil, "lone underground pipe: nothing")

  -- belts
  a = make("underground-belt", 0.5, 10.5, D.east, { type = "output" })
  make("underground-belt", 2.5, 10.5, D.east, { type = "input" })
  p = fill(a)
  check(p and p.name == "transport-belt" and p.position.x == 1.5 and p.direction == D.east, "belt straight gap (from exit)")

  make("underground-belt", 6.5, 10.5, D.east, { type = "output" })
  b = make("underground-belt", 8.5, 10.5, D.east, { type = "input" })
  p = fill(b)
  check(p and p.name == "transport-belt" and p.position.x == 7.5 and p.direction == D.east, "belt straight gap (from entrance)")

  a = make("underground-belt", 12.5, 10.5, D.east, { type = "output" })
  make("underground-belt", 13.5, 11.5, D.south, { type = "input" })
  p = fill(a)
  check(p and p.position.x == 13.5 and p.position.y == 10.5 and p.direction == D.south, "belt corner gap faces the entrance")

  a = make("underground-belt", 18.5, 10.5, D.east, { type = "output" })
  make("underground-belt", 20.5, 10.5, D.west, { type = "output" })
  check(fill(a) == nil, "exit facing an exit: nothing")

  check(fill(make("underground-belt", 24.5, 10.5, D.east, { type = "output" })) == nil, "lone exit: nothing")

  a = make("fast-underground-belt", 0.5, 15.5, D.south, { type = "output" })
  make("fast-underground-belt", 0.5, 17.5, D.south, { type = "input" })
  p = fill(a)
  check(p and p.name == "fast-transport-belt" and p.direction == D.south, "fast underground gets a fast belt")

  if prototypes.quality.legendary then
    a = make("underground-belt", 6.5, 15.5, D.west, { type = "output", quality = "legendary" })
    make("underground-belt", 4.5, 15.5, D.west, { type = "input", quality = "legendary" })
    p = fill(a)
    check(p and p.quality.name == "legendary", "quality kept")
  end

  -- block list
  check(settings.global["ugf-blocked"].value == "void-pipe", "void-pipe blocked by default")
  remote.call("underground-gap-fill", "set_blocked", "foo, pipe")
  check(remote.call("underground-gap-fill", "fill_name", "pipe-to-ground") == nil, "blocked pipe never chosen")
  a = make("pipe-to-ground", 0.5, 22.5, D.east)
  make("pipe-to-ground", 2.5, 22.5, D.west)
  check(fill(a) == nil and at(1.5, 22.5) == nil, "blocked pipe: gap left empty")
  remote.call("underground-gap-fill", "set_blocked", "void-pipe")
  check(remote.call("underground-gap-fill", "fill_name", "pipe-to-ground") == "pipe", "unblocked again")

  log(fails == 0 and "ALL PASS" or (fails .. " FAILED"))
  helpers.write_file("ugf-test.txt", table.concat(out, "\n") .. "\n")
end)
