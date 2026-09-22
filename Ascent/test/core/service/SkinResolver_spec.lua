describe("SkinResolver", function()
  local ns, SkinResolver, SkinShape, Frozen, FillKind, BorderKind

  before_each(function()
    ns = AscentTest.loadDomain("core/service/SkinResolver.lua")
    SkinResolver = ns.core.SkinResolver
    SkinShape = ns.core.SkinShape
    Frozen = ns.core.Frozen
    FillKind = ns.core.FillKind
    BorderKind = ns.core.BorderKind
  end)

  -- Every key of the shape, at every depth, as a sorted list of dotted paths.
  -- If a normalized skin has exactly the shape's keys, no downstream read can
  -- hit a missing one, so one assertion stands in for a sweep over skins.
  local function paths(value, prefix, out)
    out = out or {}
    prefix = prefix or ""
    if Frozen.isFrozen(value) then
      for key, inner in Frozen.each(value) do
        paths(inner, prefix .. tostring(key) .. ".", out)
      end
    elseif type(value) == "table" then
      local keys = {}
      for key in pairs(value) do keys[#keys + 1] = tostring(key) end
      table.sort(keys)
      for _, key in ipairs(keys) do
        paths(value[key], prefix .. key .. ".", out)
      end
    else
      out[#out + 1] = prefix:sub(1, -2)
    end
    return out
  end

  describe("normalize", function()
    it("gives a skin that states nothing the complete shape", function()
      local normalized = SkinResolver.normalize({})

      assert.same(paths(SkinShape), paths(normalized))
    end)

    it("gives a skin that states one field the same complete shape", function()
      local normalized = SkinResolver.normalize({ fill = { kind = FillKind.GRADIENT_UP } })

      assert.same(paths(SkinShape), paths(normalized))
      assert.equal(FillKind.GRADIENT_UP, normalized.fill.kind)
    end)

    it("keeps the rest of a nested field when only one of its keys is stated", function()
      local normalized = SkinResolver.normalize({ border = { thickness = 3 } })

      assert.equal(3, normalized.border.thickness)
      assert.equal(BorderKind.NONE, normalized.border.kind)
      assert.equal(0.25, normalized.border.color.r)
    end)

    it("falls back a field whose stated value is of the wrong type", function()
      local normalized = SkinResolver.normalize({
        border = { thickness = "thick" },
        background = "black",
      })

      assert.equal(1, normalized.border.thickness)
      assert.equal(0, normalized.background.r)
      assert.equal(0.6, normalized.background.a)
    end)

    it("drops a key the shape does not declare", function()
      local normalized = SkinResolver.normalize({ sparkle = true, fill = { rainbow = 7 } })

      assert.same(paths(SkinShape), paths(normalized))
      assert.is_nil(rawget(normalized, "sparkle"))
      assert.is_nil(rawget(normalized.fill, "rainbow"))
    end)

    it("survives a skin that is not a table at all", function()
      assert.same(paths(SkinShape), paths(SkinResolver.normalize(nil)))
      assert.same(paths(SkinShape), paths(SkinResolver.normalize("obsidian")))
    end)

    it("does not hand back the shape itself, which is frozen and shared", function()
      local normalized = SkinResolver.normalize({})
      normalized.background.a = 0.1

      assert.equal(0.6, SkinShape.background.a)
    end)
  end)

  describe("resolve", function()
    local ColorMode, Palette

    before_each(function()
      ColorMode = ns.core.ColorMode
      Palette = ns.core.Palette
    end)

    local function resolve(skin, overrides, highContrast)
      return SkinResolver.resolve({
        skin = skin, overrides = overrides, palette = Palette, highContrast = highContrast,
      })
    end

    -- How far apart the two closest colours of a palette look, mirroring the
    -- weighting the resolver uses. Recomputed here rather than reached into, so
    -- the guarantee is checked against an independent reading of the result.
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

    local function paletteOf(appearance)
      local colors = {}
      for key, color in Frozen.each(appearance.colors) do
        colors[key] = color
      end
      return colors
    end

    it("refuses to resolve without a palette", function()
      assert.has_error(function() SkinResolver.resolve({ skin = {} }) end)
    end)

    it("leaves the semantic palette untouched when the skin does not modulate", function()
      local appearance = resolve({})

      assert.equal(Palette.MOB_KILL.r, appearance.colors.MOB_KILL.r)
      assert.equal(Palette.QUEST_TURNIN.b, appearance.colors.QUEST_TURNIN.b)
      assert.equal(0, appearance.tintScale)
    end)

    it("applies a modest tint the skin asks for", function()
      local appearance = resolve({
        tint = {
          mode = ColorMode.MODULATED, saturation = 0.85, brightness = 0.9,
          towards = { r = 0.1, g = 0, b = 0.2 }, amount = 0.15,
        },
      })

      assert.equal(1, appearance.tintScale)
      assert.is_not.equal(Palette.MOB_KILL.r, appearance.colors.MOB_KILL.r)
    end)

    it("walks back a tint that would make two sources look alike", function()
      -- Fully desaturated and pulled almost all the way to one colour: every
      -- source would land on the same grey-violet without the guarantee.
      local appearance = resolve({
        tint = {
          mode = ColorMode.MODULATED, saturation = 0, brightness = 1,
          towards = { r = 0.2, g = 0.1, b = 0.3 }, amount = 0.95,
        },
      })

      assert.equal(0, appearance.tintScale)
      assert.equal(Palette.MOB_KILL.r, appearance.colors.MOB_KILL.r)
    end)

    it("keeps the closest pair of a modulated palette above the floor", function()
      local plain = closest(paletteOf(resolve({})))
      local appearance = resolve({
        tint = {
          mode = ColorMode.MODULATED, saturation = 0.4, brightness = 1,
          towards = { r = 0.3, g = 0.3, b = 0.35 }, amount = 0.5,
        },
      })

      assert.is_true(closest(paletteOf(appearance)) >= plain * 0.6)
    end)

    it("ignores every tint in high contrast", function()
      local tint = {
        mode = ColorMode.MODULATED, saturation = 0.5, brightness = 0.8,
        towards = { r = 0, g = 0, b = 0 }, amount = 0.3,
      }

      local appearance = resolve({ tint = tint }, nil, true)

      assert.equal(0, appearance.tintScale)
      assert.equal(Palette.EXPLORATION.g, appearance.colors.EXPLORATION.g)
    end)

    it("lets a player override one field without losing the skin's others", function()
      local skin = { border = { kind = BorderKind.BEVEL, thickness = 2 } }

      local appearance = resolve(skin, { border = { thickness = 4 } })

      assert.equal(4, appearance.border.thickness)
      assert.equal(BorderKind.BEVEL, appearance.border.kind)
    end)

    it("ignores an override key nobody declared", function()
      local appearance = resolve({}, { nonsense = 1, border = { glitter = true } })

      assert.is_false(Frozen.has(appearance, "nonsense"))
      assert.is_false(Frozen.has(appearance.border, "glitter"))
    end)

    it("ignores an override whose value is of the wrong type", function()
      local appearance = resolve({ fill = { gloss = 0.3 } }, { fill = { gloss = "lots" } })

      assert.equal(0.3, appearance.fill.gloss)
    end)

    -- One surface's own tweaks, over the choices every surface shares. The pull
    -- plate is the caller: it follows the bar's skin and the bar's own map, and
    -- may then adjust a handful of axes for itself.
    describe("a surface's own layer", function()
      local function layered(skin, overrides, own)
        return SkinResolver.resolve({
          skin = skin, overrides = overrides, own = own, palette = Palette,
        })
      end

      it("wins the axis it states over the shared choice", function()
        local appearance = layered({}, { border = { thickness = 4 } }, { border = { thickness = 7 } })

        assert.equal(7, appearance.border.thickness)
      end)

      -- The map is partial: what it leaves out is not a decision, so changing
      -- the bar's skin still carries the plate with it.
      it("leaves an axis it does not state following the layer below", function()
        local skin = { border = { kind = BorderKind.BEVEL, thickness = 2 } }

        local appearance = layered(skin, { accent = { r = 0.1, g = 0.2, b = 0.3 } },
          { border = { thickness = 7 } })

        assert.equal(7, appearance.border.thickness)
        assert.equal(0.1, appearance.accent.r)
        assert.equal(BorderKind.BEVEL, appearance.border.kind)
      end)

      it("changes nothing at all when there is no own layer", function()
        local skin = { border = { kind = BorderKind.BEVEL, thickness = 2 } }

        assert.same(paths(layered(skin, { fill = { gloss = 0.3 } })),
          paths(layered(skin, { fill = { gloss = 0.3 } }, {})))
        assert.equal(0.3, layered(skin, { fill = { gloss = 0.3 } }, {}).fill.gloss)
      end)
    end)

    it("hands back a frozen table, so a typo downstream fails where it happens", function()
      local appearance = resolve({})

      assert.has_error(function() return appearance.bordr end)
    end)

    -- The table a drawer reads on every redraw. The domain's palette carries
    -- r/g/b only and every drawer asks for alpha, so without it the first
    -- repaint raises "'a' is not a key of" and takes the whole bar with it.
    it("gives every resolved colour a complete r/g/b/a, so a drawer can read alpha", function()
      for _, highContrast in ipairs({ false, true }) do
        local appearance = resolve({
          tint = { mode = ColorMode.MODULATED, saturation = 0.9, brightness = 1.05,
                   towards = { r = 0.2, g = 0.2, b = 0.3 }, amount = 0.1 },
        }, nil, highContrast)

        for _, key in ipairs(Frozen.keys(appearance.colors)) do
          local color = appearance.colors[key]
          assert.same({ "a", "b", "g", "r" }, Frozen.keys(color), key .. " is missing a channel")
          assert.has_no.errors(function() return color.a end)
        end
      end
    end)

    it("carries every colour the palette declares, not only the four sources", function()
      local appearance = resolve({})

      assert.same(Frozen.keys(Palette), Frozen.keys(appearance.colors))
    end)
  end)
end)
