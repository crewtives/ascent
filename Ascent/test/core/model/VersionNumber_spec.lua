-- The comparison everything else in the update check rests on. The case that
-- matters most is the last group: text nobody can read must never win, because
-- the failure it produces is not a missed update -- it is telling a player to go
-- and install a version that does not exist.

describe("VersionNumber", function()
  local VersionNumber

  before_each(function()
    VersionNumber = AscentTest.loadWith("core/model/VersionNumber.lua").core.VersionNumber
  end)

  describe("parse", function()
    it("reads major, minor and patch", function()
      local version = VersionNumber.parse("1.2.3")
      assert.equal(1, version.major)
      assert.equal(2, version.minor)
      assert.equal(3, version.patch)
      assert.is_nil(version.pre)
    end)

    it("tolerates the leading v a git tag carries", function()
      assert.same(VersionNumber.parse("0.1.0"), VersionNumber.parse("v0.1.0"))
    end)

    -- A TOC line is read with a trailing newline or a stray carriage return often
    -- enough that the release script strips them by hand; a version that differs
    -- by whitespace is the same version.
    it("tolerates surrounding whitespace", function()
      assert.same(VersionNumber.parse("0.1.0"), VersionNumber.parse("  0.1.0 "))
    end)

    it("keeps a pre-release and discards build metadata", function()
      assert.equal("beta1", VersionNumber.parse("0.2.0-beta1").pre)
      assert.is_nil(VersionNumber.parse("0.2.0+abc123").pre)
      assert.equal("rc.1", VersionNumber.parse("0.2.0-rc.1+abc123").pre)
    end)

    it("refuses anything that is not a version", function()
      for _, text in ipairs({ "", "1.2", "1.2.3.4", "one.two.three", "v", "0.1.0-", "99" }) do
        assert.is_nil(VersionNumber.parse(text), ("parsed %q"):format(text))
      end
      assert.is_nil(VersionNumber.parse(nil))
      assert.is_nil(VersionNumber.parse(42))
    end)

    -- The standard packager's @project-version@ yields this on any untagged commit,
    -- and it is PERFECTLY VALID semver -- hyphens are allowed inside a pre-release.
    -- It is also read as a pre-release OF 0.1.0, so a build five commits after
    -- 0.1.0 orders BEFORE it and its owner would be told to upgrade to the version
    -- they are already past. Ordering it wrong is worse than refusing it, and is
    -- the concrete reason this project keeps a clean semver in the TOC.
    it("reads the packager's untagged version as older than the tag it came after", function()
      assert.equal("5-gabc1234", VersionNumber.parse("v0.1.0-5-gabc1234").pre)
      assert.equal(-1, VersionNumber.compare("v0.1.0-5-gabc1234", "0.1.0"))
    end)
  end)

  describe("compare", function()
    it("orders by major, then minor, then patch", function()
      assert.equal(1, VersionNumber.compare("1.0.0", "0.9.9"))
      assert.equal(1, VersionNumber.compare("0.2.0", "0.1.9"))
      assert.equal(1, VersionNumber.compare("0.1.2", "0.1.1"))
      assert.equal(-1, VersionNumber.compare("0.1.1", "0.1.2"))
      assert.equal(0, VersionNumber.compare("0.1.0", "0.1.0"))
    end)

    it("puts a pre-release before the release it leads to", function()
      assert.equal(-1, VersionNumber.compare("0.2.0-beta1", "0.2.0"))
      assert.equal(1, VersionNumber.compare("0.2.0", "0.2.0-beta1"))
    end)

    it("orders pre-releases among themselves, numerically where they are numbers", function()
      assert.equal(-1, VersionNumber.compare("0.2.0-alpha", "0.2.0-beta"))
      assert.equal(-1, VersionNumber.compare("0.2.0-rc.1", "0.2.0-rc.2"))
      assert.equal(-1, VersionNumber.compare("0.2.0-rc.2", "0.2.0-rc.10"))
      -- Fewer identifiers is the smaller version when everything before is equal.
      assert.equal(-1, VersionNumber.compare("0.2.0-rc", "0.2.0-rc.1"))
    end)

    it("orders beta10 BEFORE beta2, which is semver and is why the dot matters", function()
      -- An identifier containing letters compares as text, in ASCII order: "beta10"
      -- sorts before "beta2" the way "b10" sorts before "b2" in a file listing.
      -- Surprising enough to pin down, and the reason this project's tags would
      -- spell a second beta "0.2.0-beta.2" rather than "0.2.0-beta2".
      assert.equal(-1, VersionNumber.compare("0.2.0-beta10", "0.2.0-beta2"))
    end)

    it("ignores build metadata", function()
      assert.equal(0, VersionNumber.compare("0.1.0+one", "0.1.0+two"))
    end)

    it("has no ordering for something it cannot read", function()
      assert.is_nil(VersionNumber.compare("nonsense", "0.1.0"))
      assert.is_nil(VersionNumber.compare("0.1.0", "nonsense"))
    end)
  end)

  describe("isNewer", function()
    it("is true only for a strictly later version", function()
      assert.is_true(VersionNumber.isNewer("0.2.0", "0.1.0"))
      assert.is_false(VersionNumber.isNewer("0.1.0", "0.1.0"))
      assert.is_false(VersionNumber.isNewer("0.0.9", "0.1.0"))
    end)

    it("is false for anything unreadable, on either side", function()
      assert.is_false(VersionNumber.isNewer("99999", "0.1.0"))
      assert.is_false(VersionNumber.isNewer("0.2.0", "not a version"))
      assert.is_false(VersionNumber.isNewer(nil, "0.1.0"))
      assert.is_false(VersionNumber.isNewer({}, "0.1.0"))
    end)
  end)
end)
