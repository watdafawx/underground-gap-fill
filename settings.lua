data:extend({
  { type = "bool-setting", name = "ugf-pipes", setting_type = "runtime-per-user", default_value = true, order = "a" },
  { type = "bool-setting", name = "ugf-belts", setting_type = "runtime-per-user", default_value = true, order = "b" },
  { type = "string-setting", name = "ugf-blocked", setting_type = "runtime-global", default_value = "void-pipe",
    allow_blank = true, order = "c" },
})
