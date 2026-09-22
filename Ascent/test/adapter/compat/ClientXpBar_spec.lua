-- The client's bar is looked up by name at call time, so a spec can put one in
-- _G, take it away, or leave it half-built, and see what the addon does about it.

describe("ClientXpBar", function()
  local ns, ClientXpBar, BarSlot, slot

  -- Enough of a frame to be anchored to and quieted. Records what was done to it
  -- so a spec can assert on the calls rather than only on the end state.
  local function fakeFrame(fields)
    local frame = {
      alpha = (fields or {}).alpha or 1,
      mouse = (fields or {}).mouse ~= false,
    }
    function frame:GetWidth() return 400 end
    -- Thin, like the client's own bar: the height the inventory reports decides
    -- whether the text can stay inside it.
    function frame:GetHeight() return 10 end
    function frame:GetAlpha() return self.alpha end
    function frame:SetAlpha(value) self.alpha = value end
    function frame:IsMouseEnabled() return self.mouse end
    function frame:EnableMouse(value) self.mouse = value end
    return frame
  end

  -- A texture: alpha but no mouse, which is the shape half the pieces have.
  local function fakeTexture()
    local texture = { alpha = 1 }
    function texture:GetAlpha() return self.alpha end
    function texture:SetAlpha(value) self.alpha = value end
    return texture
  end

  local NAMES = {
    "MainMenuExpBar", "MainMenuBarExpText", "ExhaustionTick", "ExhaustionLevelFillBar",
    "MainMenuXPBarTextureLeftCap", "MainMenuXPBarTextureRightCap", "MainMenuXPBarTextureMid",
    "MainStatusTrackingBarContainer", "StatusTrackingBarManager", "MainMenuBar",
  }

  local function clearClient()
    for _, name in ipairs(NAMES) do
      _G[name] = nil
    end
  end

  local function buildClient()
    _G.MainMenuExpBar = fakeFrame()
    _G.MainMenuBarExpText = fakeFrame()
    _G.ExhaustionTick = fakeFrame()
    _G.ExhaustionLevelFillBar = fakeTexture()
    _G.MainMenuXPBarTextureLeftCap = fakeTexture()
    _G.MainMenuXPBarTextureRightCap = fakeTexture()
    _G.MainMenuXPBarTextureMid = fakeTexture()
  end

  before_each(function()
    ns = AscentTest.loadDomain("core/service/BarSlotPolicy.lua", "adapter/compat/ClientXpBar.lua")
    ClientXpBar = ns.adapter.ClientXpBar
    BarSlot = ns.core.BarSlot
    clearClient()
    slot = ClientXpBar.new()
  end)

  after_each(clearClient)

  describe("finding it", function()
    it("hands back the client's bar as something to anchor to", function()
      buildClient()

      assert.is_true(slot:present())
      assert.equal(_G.MainMenuExpBar, slot:frame())
    end)

    it("reports absent when the client has no such bar", function()
      assert.is_false(slot:present())
      assert.is_nil(slot:frame())
    end)

    -- What another addon leaves behind when it replaces the main bar: the name is
    -- taken, by something that is not a frame.
    it("reports absent when the name holds something that is not a frame", function()
      _G.MainMenuExpBar = "taken"

      assert.is_false(slot:present())
    end)

    it("reports absent when the name holds a table with no geometry to offer", function()
      _G.MainMenuExpBar = {}

      assert.is_false(slot:present())
    end)
  end)

  describe("going quiet", function()
    before_each(buildClient)

    it("makes the bar and its readouts invisible and deaf to the cursor", function()
      slot:applySlot(BarSlot.INSET)

      assert.equal(0, _G.MainMenuExpBar.alpha)
      assert.equal(0, _G.MainMenuBarExpText.alpha)
      assert.equal(0, _G.ExhaustionTick.alpha)
      assert.equal(0, _G.ExhaustionLevelFillBar.alpha)
      assert.is_false(_G.MainMenuExpBar.mouse)
      assert.is_false(_G.ExhaustionTick.mouse)
    end)

    it("leaves the frame the client draws around the bar alone in the inset slot", function()
      slot:applySlot(BarSlot.INSET)

      assert.equal(1, _G.MainMenuXPBarTextureLeftCap.alpha)
      assert.equal(1, _G.MainMenuXPBarTextureMid.alpha)
    end)

    it("quiets that frame too in the replace slot", function()
      slot:applySlot(BarSlot.REPLACE)

      assert.equal(0, _G.MainMenuXPBarTextureLeftCap.alpha)
      assert.equal(0, _G.MainMenuXPBarTextureRightCap.alpha)
      assert.equal(0, _G.MainMenuXPBarTextureMid.alpha)
    end)

    it("does nothing at all in the off slot", function()
      slot:applySlot(BarSlot.OFF)

      assert.equal(1, _G.MainMenuExpBar.alpha)
      assert.is_true(_G.MainMenuExpBar.mouse)
    end)

    it("skips a piece this client does not have instead of failing", function()
      _G.ExhaustionTick = nil

      assert.has_no.errors(function() slot:applySlot(BarSlot.REPLACE) end)
      assert.equal(0, _G.MainMenuExpBar.alpha)
    end)
  end)

  describe("giving it back", function()
    before_each(buildClient)

    it("restores exactly what was there", function()
      slot:applySlot(BarSlot.REPLACE)
      slot:restore()

      assert.equal(1, _G.MainMenuExpBar.alpha)
      assert.is_true(_G.MainMenuExpBar.mouse)
      assert.equal(1, _G.MainMenuXPBarTextureMid.alpha)
    end)

    -- A piece somebody else had already turned off must not come back on:
    -- full opacity is not assumed to be the natural state.
    it("leaves a piece that was already invisible invisible", function()
      _G.MainMenuBarExpText = fakeFrame({ alpha = 0, mouse = false })

      slot:applySlot(BarSlot.INSET)
      slot:restore()

      assert.equal(0, _G.MainMenuBarExpText.alpha)
      assert.is_false(_G.MainMenuBarExpText.mouse)
    end)

    it("does not record its own silence as the value to give back", function()
      slot:applySlot(BarSlot.INSET)
      slot:applySlot(BarSlot.INSET)
      slot:applySlot(BarSlot.INSET)
      slot:restore()

      assert.equal(1, _G.MainMenuExpBar.alpha)
    end)

    -- Switching between the two active slots without passing through off: the
    -- frame art has to come back, and the readouts have to stay quiet.
    it("gives back only what the new slot no longer covers", function()
      slot:applySlot(BarSlot.REPLACE)
      slot:applySlot(BarSlot.INSET)

      assert.equal(1, _G.MainMenuXPBarTextureMid.alpha)
      assert.equal(0, _G.MainMenuExpBar.alpha)
    end)

    it("has nothing to give back when it never quieted anything", function()
      assert.has_no.errors(function() slot:restore() end)
      assert.equal(1, _G.MainMenuExpBar.alpha)
    end)
  end)
  -- The registry is the real one, so "appears in the list of what got turned off"
  -- is the addon's own diagnostic surface rather than a list written for the test.
  describe("as a capability", function()
    local Capabilities

    before_each(function()
      ns = AscentTest.loadDomain(
        "core/service/BarSlotPolicy.lua",
        "adapter/compat/Capabilities.lua",
        "adapter/compat/ClientXpBar.lua")
      ClientXpBar = ns.adapter.ClientXpBar
      Capabilities = ns.adapter.Capabilities
      BarSlot = ns.core.BarSlot
      slot = ClientXpBar.new()
    end)

    it("is present when the client has the bar", function()
      buildClient()
      local registry = Capabilities.new()
      registry:register("client_xp_bar", function() return slot:present() end)

      assert.is_true(registry:has("client_xp_bar"))
      assert.same({}, registry:missing())
      assert.equal(BarSlot.INSET, slot:effectiveSlot(BarSlot.INSET))
    end)

    it("is absent, and the chosen slot does not take effect, when the bar is gone", function()
      local registry = Capabilities.new()
      registry:register("client_xp_bar", function() return slot:present() end)

      assert.is_false(registry:has("client_xp_bar"))
      assert.same({ "client_xp_bar" }, registry:missing())
      assert.equal(BarSlot.OFF, slot:effectiveSlot(BarSlot.REPLACE))
    end)

    it("keeps the player's choice on disk while it cannot be honoured", function()
      local chosen = BarSlot.REPLACE

      assert.equal(BarSlot.OFF, slot:effectiveSlot(chosen))
      buildClient()
      assert.equal(BarSlot.REPLACE, slot:effectiveSlot(chosen))
    end)
  end)
  -- The inventory lets a client that cannot be run here say, in a chat window,
  -- which bar frames it has and how big they are.
  describe("the inventory it can be asked for", function()
    local function rowFor(rows, name)
      for _, row in ipairs(rows) do
        if row.name == name then return row end
      end
    end

    it("reports what is there, with its width and height", function()
      buildClient()

      local rows = slot:inventory()
      local bar = rowFor(rows, "MainMenuExpBar")

      assert.is_true(bar.present)
      assert.is_true(bar.used)
      assert.equal(400, bar.width)
      assert.equal(10, bar.height)
    end)

    it("reports what is missing rather than leaving it out", function()
      local row = rowFor(slot:inventory(), "MainMenuExpBar")

      assert.is_false(row.present)
      assert.is_nil(row.width)
    end)

    -- A piece with alpha but no geometry -- a texture -- must be reported as
    -- there rather than crashing the diagnostic that went looking for its size.
    it("reports a piece that has no geometry to offer", function()
      buildClient()

      local row = rowFor(slot:inventory(), "ExhaustionLevelFillBar")

      assert.is_true(row.present)
      assert.is_nil(row.width)
    end)

    -- Names the addon does not use are probed so a client that keeps its bar
    -- somewhere else says where. MainMenuBar is one: on the Anniversary Burning
    -- Crusade Classic client it is present and is not the bar -- 1024x53, the
    -- whole bottom bar.
    it("probes names it does not use, and marks them as such", function()
      _G.MainMenuBar = fakeFrame()

      local row = rowFor(slot:inventory(), "MainMenuBar")

      assert.is_true(row.present)
      assert.is_false(row.used)
    end)
  end)
  -- The Anniversary Burning Crusade Classic client has none of the classic tree:
  -- its experience bar lives in the modern status-tracking system. This fixture
  -- reproduces what was measured there.
  describe("on a client with the modern status tracking bar", function()
    before_each(function()
      _G.MainStatusTrackingBarContainer = fakeFrame()
      _G.StatusTrackingBarManager = fakeFrame()
      _G.MainMenuBar = fakeFrame()
    end)

    it("anchors to the container that holds the bar, not to the manager", function()
      assert.equal("MainStatusTrackingBarContainer", slot:anchorName())
      assert.equal(_G.MainStatusTrackingBarContainer, slot:frame())
      assert.is_true(slot:present())
    end)

    it("prefers the classic bar when a client has both", function()
      buildClient()

      assert.equal("MainMenuExpBar", slot:anchorName())
    end)

    it("quiets whichever frame it anchored to", function()
      slot:applySlot(BarSlot.INSET)

      assert.equal(0, _G.MainStatusTrackingBarContainer.alpha)
      assert.is_false(_G.MainStatusTrackingBarContainer.mouse)
      -- The manager above it is not the bar, and quieting it would take the
      -- reputation bar with it.
      assert.equal(1, _G.StatusTrackingBarManager.alpha)
    end)

    it("gives it back", function()
      slot:applySlot(BarSlot.REPLACE)
      slot:restore()

      assert.equal(1, _G.MainStatusTrackingBarContainer.alpha)
      assert.is_true(_G.MainStatusTrackingBarContainer.mouse)
    end)

    -- On this client the anchor is the container and the art of the client's
    -- frame is its child, so quieting the anchor takes the frame with it. The
    -- inset slot must quiet only the bar inside and keep the frame.
    describe("with the bar living inside the container", function()
      local bar, art

      before_each(function()
        bar = fakeFrame()
        function bar:GetStatusBarTexture() return {} end
        art = fakeFrame()
        local container = _G.MainStatusTrackingBarContainer
        -- The bar is nested one deeper than the container, the way the client
        -- nests it: container -> bar frame -> StatusBar.
        local holder = fakeFrame()
        function holder:GetChildren() return bar end
        function container:GetChildren() return holder, art end
      end)

      it("quiets the bar and leaves the client's frame in the inset slot", function()
        slot:applySlot(BarSlot.INSET)

        assert.equal(0, bar.alpha)
        assert.equal(1, _G.MainStatusTrackingBarContainer.alpha,
          "the inset slot took the client's frame down with the bar")
        assert.equal(1, art.alpha, "the art around the bar went quiet too")
      end)

      it("quiets the whole container in the replace slot", function()
        slot:applySlot(BarSlot.REPLACE)

        assert.equal(0, _G.MainStatusTrackingBarContainer.alpha)
      end)

      -- applyQuiet converges on the new slot because the player can move
      -- between the two active slots without passing through off.
      it("converges when the player moves from one slot to the other", function()
        slot:applySlot(BarSlot.INSET)
        slot:applySlot(BarSlot.REPLACE)

        assert.equal(0, _G.MainStatusTrackingBarContainer.alpha)
        assert.equal(1, bar.alpha, "the bar inside was not given back")

        slot:applySlot(BarSlot.INSET)
        assert.equal(1, _G.MainStatusTrackingBarContainer.alpha)
        assert.equal(0, bar.alpha)
      end)

      it("gives the bar inside back", function()
        slot:applySlot(BarSlot.INSET)
        slot:restore()

        assert.equal(1, bar.alpha)
        assert.is_true(bar.mouse)
      end)

      -- A piece with no global name is invisible to a diagnostic that only walks
      -- fixed lists, and "did inset keep the client's frame?" is exactly what the
      -- diagnostic is asked.
      it("reports what it quieted even though it has no name", function()
        slot:applySlot(BarSlot.INSET)

        local quieted = {}
        for _, row in ipairs(slot:inventory()) do
          if row.quieted then
            quieted[#quieted + 1] = row.name
          end
        end
        assert.equal(1, #quieted)
        assert.is_truthy(quieted[1]:find("MainStatusTrackingBarContainer", 1, true),
          "the row does not say which anchor the bar was found under")
      end)
    end)
  end)
  -- A piece that was already invisible when the addon arrived must not be
  -- recorded as this addon's to give back, or giving it back hides it for good.
  describe("a piece that was already invisible", function()
    before_each(buildClient)

    it("is left alone rather than recorded", function()
      _G.MainMenuBarExpText = fakeFrame({ alpha = 0 })

      slot:applySlot(BarSlot.INSET)

      local held
      for _, row in ipairs(slot:inventory()) do
        if row.name == "MainMenuBarExpText" then held = row.quieted end
      end
      assert.is_nil(held)
    end)

    it("is not turned back on when the slot is given up", function()
      _G.MainMenuBarExpText = fakeFrame({ alpha = 0 })

      slot:applySlot(BarSlot.INSET)
      slot:restore()

      assert.equal(0, _G.MainMenuBarExpText.alpha)
    end)

    -- A piece this addon did quiet still comes back, including across a
    -- re-application: its own zero is not mistaken for somebody else's.
    it("does not stop the addon giving back what it did quiet", function()
      slot:applySlot(BarSlot.INSET)
      slot:applySlot(BarSlot.INSET)
      slot:restore()

      assert.equal(1, _G.MainMenuExpBar.alpha)
    end)
  end)
end)
