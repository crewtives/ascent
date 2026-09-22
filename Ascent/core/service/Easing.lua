-- Ascent - the curves motion is allowed to follow.
--
-- Named, not passed as functions: a skin or a preset that travels as text can
-- carry "out_cubic" but not a closure, so everything that decides how the bar
-- moves stays serializable, comparable and diffable.
--
-- Every curve obeys one contract, asserted by the tests: f(0) is exactly 0, f(1)
-- is exactly 1, and nothing in between leaves [0, 1]. A curve that overshoots
-- would drive a boundary past its neighbour's and make the bar's pieces cross
-- mid-animation; adding one would need the tween to clamp.

local _, ns = ...
ns.core = ns.core or {}

local Frozen = ns.core.Frozen

ns.core.EasingName = Frozen.enum("EasingName", {
  LINEAR       = "linear",
  OUT_QUAD     = "out_quad",
  OUT_CUBIC    = "out_cubic",
  IN_OUT_CUBIC = "in_out_cubic",
})

local EasingName = ns.core.EasingName

local Easing = {}

local CURVES = {
  [EasingName.LINEAR] = function(t) return t end,
  [EasingName.OUT_QUAD] = function(t) return 1 - (1 - t) * (1 - t) end,
  [EasingName.OUT_CUBIC] = function(t) return 1 - (1 - t) ^ 3 end,
  [EasingName.IN_OUT_CUBIC] = function(t)
    if t < 0.5 then
      return 4 * t * t * t
    end
    return 1 - ((-2 * t + 2) ^ 3) / 2
  end,
}

Easing.DEFAULT = EasingName.OUT_CUBIC

-- Never raises and never returns nil. A name out of saved data, out of an
-- imported preset, or out of a version that had one more curve than this one
-- resolves to the default.
function Easing.byName(name)
  return CURVES[name] or CURVES[Easing.DEFAULT]
end

-- `t` outside [0, 1] is clamped rather than extrapolated: a caller handing over
-- 1.2 has already overshot its own clock, and following the curve past its end
-- would turn a late frame into a visible overshoot.
function Easing.at(name, t)
  if t <= 0 then return 0 end
  if t >= 1 then return 1 end
  return Easing.byName(name)(t)
end

ns.core.Easing = Easing
