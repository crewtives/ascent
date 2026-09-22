-- Not what any skin looks like, which will change, but what every entry must
-- have whatever it looks like: it normalizes to the full shape, and it cannot
-- make the palette unreadable.

describe("SkinCatalog", function()
  local ns, SkinCatalog, SkinResolver, Frozen, Palette

  before_each(function()
    ns = AscentTest.loadDomain("core/registry/SkinCatalog.lua", "core/service/SkinResolver.lua")
    SkinCatalog = ns.core.SkinCatalog
    SkinResolver = ns.core.SkinResolver
    Frozen = ns.core.Frozen
    Palette = ns.core.Palette
  end)

  local function closest(colors)
    local keys = {}
    for key in pairs(colors) do keys[#keys + 1] = key end
    local best
    for i = 1, #keys do
      for j = i + 1, #keys do
        local a, b = colors[keys[i]], colors[keys[j]]
        local dr, dg, db = a.r - b.r, a.g - b.g, a.b - b.b
        local d = math.sqrt(dr * dr * 0.30 + dg * dg * 0.59 + db * db * 0.11)
        if best == nil or d < best then best = d end
      end
    end
    return best
  end

  local function semanticPalette()
    local colors = {}
    for key, color in Frozen.each(Palette) do
      colors[key] = { r = color.r, g = color.g, b = color.b }
    end
    return colors
  end

  local function resolvedPalette(appearance)
    local colors = {}
    for key, color in Frozen.each(appearance.colors) do
      colors[key] = color
    end
    return colors
  end

  it("ships at least the six skins the first release promises", function()
    assert.is_true(#Frozen.keys(SkinCatalog) >= 6)
  end)

  it("names a default that is actually in the catalogue", function()
    assert.is_true(Frozen.has(SkinCatalog, ns.core.DEFAULT_SKIN_ID))
  end)

  it("normalizes every skin to exactly the shape, with no key missing or extra", function()
    local expected = Frozen.keys(ns.core.SkinShape)

    for _, id in ipairs(Frozen.keys(SkinCatalog)) do
      local normalized = SkinResolver.normalize(SkinCatalog[id])
      local keys = {}
      for key in pairs(normalized) do keys[#keys + 1] = key end
      table.sort(keys)
      assert.same(expected, keys, id .. " does not normalize to the shape")
    end
  end)

  it("keeps every source distinguishable under every skin", function()
    local floor = closest(semanticPalette()) * 0.6

    for _, id in ipairs(Frozen.keys(SkinCatalog)) do
      local appearance = SkinResolver.resolve({ skin = SkinCatalog[id], palette = Palette })
      assert.is_true(closest(resolvedPalette(appearance)) >= floor, id .. " blurs two sources together")
    end
  end)

  it("resolves a skin straight out of the frozen catalogue", function()
    -- The catalogue is frozen, and a skin states only what it changes, so every
    -- field it leaves out is a key that raises when read. If normalize did not
    -- go through a guarded read this would blow up rather than fail an assert.
    local appearance = SkinResolver.resolve({ skin = SkinCatalog.phantom, palette = Palette })

    assert.equal(0, appearance.background.a)
    assert.equal(ns.core.FillKind.FLAT, appearance.fill.kind)
  end)

  it("falls back to the default skin for an id that is not in the catalogue", function()
    local skin = SkinResolver.skinFor(SkinCatalog, "obsidian-deluxe", ns.core.DEFAULT_SKIN_ID)

    assert.equal(SkinCatalog[ns.core.DEFAULT_SKIN_ID], skin)
  end)

  -- The options panel labels its skin buttons by looking up "skin_<id>". A skin
  -- added without its name is a blank button, and nothing else would catch it:
  -- the locale suite only checks keys written literally in the source.
  it("gives every skin a display name in the base locale", function()
    local locale = AscentTest.loadWith("core/registry/SkinCatalog.lua", "locale/")

    for _, id in ipairs(Frozen.keys(SkinCatalog)) do
      assert.is_true(locale.locale.tables.enUS["skin_" .. id] ~= nil, id .. " has no display name")
    end
  end)

  it("falls back for an id that is not even a string", function()
    assert.equal(
      SkinCatalog[ns.core.DEFAULT_SKIN_ID],
      SkinResolver.skinFor(SkinCatalog, 7, ns.core.DEFAULT_SKIN_ID)
    )
  end)
end)
