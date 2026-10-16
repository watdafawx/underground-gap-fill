-- pipe families for the "Pipe choice" checks:
--   test-steel-pipe (+ its underground, made from it): not researched
--   test-alien-pipe: another connection category, never fits a vanilla underground
local steel = table.deepcopy(data.raw.pipe.pipe)
steel.name, steel.minable.result = "test-steel-pipe", "test-steel-pipe"
local steel_item = table.deepcopy(data.raw.item.pipe)
steel_item.name, steel_item.place_result = "test-steel-pipe", "test-steel-pipe"

local steel_ug = table.deepcopy(data.raw["pipe-to-ground"]["pipe-to-ground"])
steel_ug.name, steel_ug.minable.result = "test-steel-pipe-to-ground", "test-steel-pipe-to-ground"
local steel_ug_item = table.deepcopy(data.raw.item["pipe-to-ground"])
steel_ug_item.name, steel_ug_item.place_result = "test-steel-pipe-to-ground", "test-steel-pipe-to-ground"

local alien = table.deepcopy(data.raw.pipe.pipe)
alien.name, alien.minable.result = "test-alien-pipe", "test-alien-pipe"
for _, c in pairs(alien.fluid_box.pipe_connections) do c.connection_category = "test-alien" end
local alien_item = table.deepcopy(data.raw.item.pipe)
alien_item.name, alien_item.place_result = "test-alien-pipe", "test-alien-pipe"

data:extend({
  steel, steel_item, steel_ug, steel_ug_item, alien, alien_item,
  { type = "recipe", name = "test-steel-pipe", enabled = false, ingredients = { { type = "item", name = "steel-plate", amount = 1 } },
    results = { { type = "item", name = "test-steel-pipe", amount = 1 } } },
  { type = "recipe", name = "test-steel-pipe-to-ground", enabled = false,
    ingredients = { { type = "item", name = "test-steel-pipe", amount = 10 } },
    results = { { type = "item", name = "test-steel-pipe-to-ground", amount = 2 } } },
  { type = "recipe", name = "test-alien-pipe", enabled = true, ingredients = { { type = "item", name = "iron-plate", amount = 1 } },
    results = { { type = "item", name = "test-alien-pipe", amount = 1 } } },
})
