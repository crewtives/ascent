-- Ascent - the curves motion is allowed to follow (task 4.1).
--
-- Named, not passed as functions, and that is the point (design D33's corollary
-- about movement being DATA): a skin or a preset that travels as text can carry
-- "out_cubic", and cannot carry a closure. Everything that decides how the bar
-- moves therefore stays serializable, comparable and diffable.
--
-- Every curve here obeys the same contract, and the tests assert it rather than
-- assuming it: f(0) is exactly 0, f(1) is exactly 1, and nothing in between
-- leaves [0, 1]. The last part is not decoration -- a curve that overshoots
-- would drive a boundary past its neighbour's, and a bar whose pieces cross each
-- other mid-animation is a defect, not a flourish. An overshoot curve can exist
-- one day; it will need the tween to clamp, and that is a decision to take then.

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
-- imported preset, or out of a version that had one more curve than this one,
-- all resolve to the default -- losing an easing is not worth a broken bar.
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
