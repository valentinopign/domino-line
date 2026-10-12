-- Domino Line v0.8
-- Dynamic "domino" racing line for Assetto Corsa (requires Custom Shaders Patch).
--
-- How it works:
--  * Reads the track's AI line (fast_lane.ai) every 2 m.
--  * From the line's curvature and the car's grip it computes the max speed at
--    every point, then a braking ramp backwards from every corner.
--  * Every frame each block is coloured by YOUR speed vs the allowed speed there:
--    green = margin left, yellow/orange = braking zone coming, red = brake now.
--    Red blocks stand up; as you brake they turn green and fall like dominoes.
--  * Learning: corners are detected automatically. Clean passes faster than the
--    target raise that corner's grip (brake point moves later); going off or
--    spinning lowers it. Saved per car + track + layout.

local S = ac.storage({
  show = true,
  tab = 1,
  style = 1,          -- 1 = blocks, 2 = arrows, 3 = solid line
  gripG = 1.50,       -- mechanical lateral grip (g)
  brakeG = 1.40,      -- mechanical braking (g)
  aero = 1.00,        -- downforce multiplier
  safety = 0.88,      -- safety margin (1.00 = on the limit)
  ahead = 1500,       -- metres of line ahead
  behind = 10,        -- metres of line behind
  size = 0.55,        -- block / arrow size, line width (m)
  height = 0.06,      -- height above the asphalt (m)
  bright = 1.0,       -- brightness
  domino = true,      -- red blocks stand up and fall when you brake
  stand = 1.0,        -- standing block height (x size)
  fallSpeed = 10,     -- rise/fall animation speed
  learn = true,       -- per-corner learning on
  aggressive = false, -- aggressive learning
  page = 1,
})

local STEP = 2.0          -- metres between line points
local AERO_C = 0.0016     -- extra accel per (m/s)^2 at aero = 1 (approx. GT3)
local G = 9.81
local VCAP = 300 / 3.6
local STYLE_NAMES = { 'Blocks', 'Arrows', 'Line' }
local ROWS_PER_PAGE = 8

-- UI colours (muted, consistent)
local C_GREEN  = rgbm(0.30, 0.85, 0.40, 1)
local C_YELLOW = rgbm(1.00, 0.85, 0.20, 1)
local C_ORANGE = rgbm(1.00, 0.55, 0.15, 1)
local C_RED    = rgbm(1.00, 0.25, 0.20, 1)
local C_GREY   = rgbm(0.62, 0.66, 0.64, 1)
local C_DIM    = rgbm(0.62, 0.66, 0.64, 0.6)
local C_INFO   = rgbm(0.55, 0.85, 1.00, 1)
local C_TITLE  = rgbm(0.80, 0.92, 0.84, 1)

local N = 0
local P, D, K, VT, VP, VPB, VTB = {}, {}, {}, {}, {}, {}, {}
-- P/DA/KA = AI line. PE/D/K = line actually drawn (AI line + your own corners).
local PE, DA, KA = {}, {}, {}
local SAX, SAZ = {}, {}         -- AI line sideways direction (for lateral offsets)
local OFF = {}                  -- lateral offset of the drawn line from the AI line (m)
local VTA, VPA = {}, {}         -- AI line at the limit (no safety margin) -> virtual time
-- Acceleration the car really has at full throttle, learned per 10 km/h (m/s^2)
local ACCL = {}
local accSmooth, vPrevAcc = 0, nil
local vTopSeen = 0
local aiLapT, aiLapErr = 0, 0     -- AI line virtual lap time and its uncertainty
local bestLapMs = 0               -- your best lap with this car on this track
local TMPT, TMPP = {}, {}
local C_VIOLET = rgbm(0.72, 0.52, 1.00, 1)
local OWN_MAX_DEV = 1.5         -- within this many metres of the AI line = "on the AI line"
local GM = {}
local BX, BY, BZ = {}, {}, {}
local FX, FY, FZ = {}, {}, {}
local SX, SZ = {}, {}
local ANG = {}
local Q1, Q2, Q3, Q4 = vec3(), vec3(), vec3(), vec3()
local PAL = {}
local PAL_STEPS = 32
local frameDt = 0.016

local ready, err, built = false, nil, false
local ci, v = 1, 0
local brakeIn = nil
local hudText, hudColor = '', C_GREEN
local nextCornerKmh, nextCornerDist = nil, nil

local CORN = {}
local ZONE = {}
local saveKey = 'default'
local learnMsg, learnMsgTime = '', -100
local mapMinX, mapMaxX, mapMinZ, mapMaxZ = 0, 1, 0, 1
local MX, MZ = {}, {}      -- track points rotated for the map
local mapLayout = nil      -- cached label positions for the current map size

local applyLines   -- defined further down (needs the track build helpers)

local function idx(i) return ((i - 1) % N) + 1 end
local function fwdSteps(from, to) return (to - from) % N end

local function field(obj, name)
  local ok, val = pcall(function() return obj[name] end)
  if ok then return val end
  return nil
end

local SHAPES = {
  { { -0.5, 0, 0.5, 0, 0.5, 1, -0.5, 1 } },
  {
    { -0.6, 0.00, -0.6, 0.32, 0, 0.92, 0, 0.60 },
    { 0.6, 0.00, 0.6, 0.32, 0, 0.92, 0, 0.60 },
  },
}

local STOPS = {
  { 0.00, 0.05, 0.85, 0.00 },
  { 0.40, 1.00, 0.85, 0.00 },
  { 0.70, 1.00, 0.45, 0.00 },
  { 1.00, 1.00, 0.04, 0.02 },
}
local function paletteColor(t)
  for s = 1, #STOPS - 1 do
    local a, b = STOPS[s], STOPS[s + 1]
    if t <= b[1] then
      local u = (t - a[1]) / (b[1] - a[1])
      return a[2] + (b[2] - a[2]) * u, a[3] + (b[3] - a[3]) * u, a[4] + (b[4] - a[4]) * u
    end
  end
  return 1.0, 0.04, 0.02
end

local function buildPalette()
  for k = 0, PAL_STEPS do
    local r, g, b = paletteColor(k / PAL_STEPS)
    PAL[k] = rgbm(r * S.bright, g * S.bright, b * S.bright, 0.9)
  end
end

local function buildGeometry()
  for i = 1, N do
    local a, b = PE[i], PE[idx(i + 1)]
    local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z
    local lh = math.max(1e-4, math.sqrt(dx * dx + dz * dz))
    local l3 = math.max(1e-4, math.sqrt(dx * dx + dy * dy + dz * dz))
    BX[i], BY[i], BZ[i] = a.x, a.y + S.height, a.z
    FX[i], FY[i], FZ[i] = dx / l3, dy / l3, dz / l3
    SX[i], SZ[i] = dz / lh, -dx / lh
    ANG[i] = ANG[i] or 0
  end
end

local function accelAt(v)
  local b = math.floor(v * 3.6 / 10)
  local a = ACCL[b]
  if a and a > 0.3 then return a end
  -- default until learned: roughly a GT3 (about 0.9 g low down, fading near top speed)
  local vt = math.max(60, vTopSeen > 40 and vTopSeen * 1.03 or VCAP)
  return math.max(0.3, 0.9 * G * (1 - (v / vt) ^ 2))
end

-- Max speed from curvature + braking ramp computed backwards.
-- withAccel also limits how fast the car can accelerate out of corners.
-- gs scales grip and braking (used to estimate the uncertainty).
local function profileInto(vt, vp, kk, dd, sf, useGM, withAccel, gs)
  gs = gs or 1
  local c = AERO_C * S.aero
  for i = 1, N do
    local gm = (useGM and (GM[i] or 1) or 1) * gs
    local den = kk[i] - sf * gm * c
    local vmax
    if den <= 1e-6 then
      vmax = VCAP
    else
      vmax = math.min(VCAP, math.sqrt(sf * gm * S.gripG * G / den))
    end
    vt[i] = vmax
    vp[i] = vmax
  end
  for _ = 1, 2 do
    for i = N, 1, -1 do
      local nv = vp[idx(i + 1)]
      local a = sf * gs * (S.brakeG * G + c * nv * nv)
      local lim = math.sqrt(nv * nv + 2 * a * dd[i])
      if lim < vp[i] then vp[i] = lim end
    end
  end
  if withAccel then
    for _ = 1, 2 do
      for i = 1, N do
        local pv = vp[i]
        local j = idx(i + 1)
        local lim = math.sqrt(pv * pv + 2 * accelAt(pv) * dd[i])
        if lim < vp[j] then vp[j] = lim end
      end
    end
  end
end

local function lapTimeOf(vp, dd)
  local t = 0
  for i = 1, N do t = t + dd[i] / math.max(1, vp[i]) end
  return t
end

-- Drawn line (with learning) + AI line at the limit (for the virtual time)
local function computeProfile()
  profileInto(VT, VP, K, D, S.safety, true)
  profileInto(VTA, VPA, KA, DA, 1.0, true, true)
  aiLapT = lapTimeOf(VPA, DA)
  -- uncertainty: same lap with grip/braking 7% lower and higher
  profileInto(TMPT, TMPP, KA, DA, 1.0, true, true, 0.93)
  local slow = lapTimeOf(TMPP, DA)
  profileInto(TMPT, TMPP, KA, DA, 1.0, true, true, 1.07)
  local fast = lapTimeOf(TMPP, DA)
  aiLapErr = math.abs(slow - fast) / 2
end

-- Untrained AI line (reference for the Brake column)
local function profileBase()
  profileInto(VTB, VPB, KA, DA, S.safety, false)
end

local function recomputeAll()
  computeProfile()
  profileBase()
end

---------------------------------------------------------------------------
-- Learning
---------------------------------------------------------------------------

local function sanitize(s)
  s = tostring(s or 'x')
  return (s:gsub('[^%w%-_]', '_'))
end

local function dataFolder()
  local ok, dir = pcall(function() return __dirname end)
  if ok and type(dir) == 'string' and #dir > 0 then return dir end
  local ok2, dir2 = pcall(function() return ac.getFolder(ac.FolderID.ACApps) .. '/lua/DominoLine' end)
  if ok2 and dir2 then return dir2 end
  return '.'
end

local function writeFile(path, text)
  if io and io.save then
    local ok = pcall(io.save, path, text)
    if ok then return true end
  end
  local ok, f = pcall(io.open, path, 'w')
  if ok and f then f:write(text) f:close() return true end
  return false
end

local function readFile(path)
  if io and io.load then
    local ok, r = pcall(io.load, path)
    if ok and type(r) == 'string' and #r > 0 then return r end
  end
  local ok, f = pcall(io.open, path, 'r')
  if ok and f then
    local s = f:read('*a')
    f:close()
    return s
  end
  return nil
end

local function learnPath(suffix)
  return dataFolder() .. '/learn_' .. saveKey .. (suffix or '') .. '.txt'
end

local function setMsg(m)
  learnMsg = m
  learnMsgTime = os.clock()
end

local function applyGM()
  for i = 1, N do GM[i] = 1 end
  for _, c in ipairs(CORN) do
    if math.abs(c.mult - 1) > 1e-4 then
      local taper = 8
      for o = -c.infL - taper, c.infR + taper do
        local w = 1
        if o < -c.infL then w = 1 - (-c.infL - o) / taper
        elseif o > c.infR then w = 1 - (o - c.infR) / taper end
        local j = idx(c.m + o)
        GM[j] = GM[j] + (c.mult - 1) * w
      end
    end
  end
end

-- Where braking starts for this corner (metres before the apex) in a profile
local function brakeDistance(c, vp)
  local d = 0
  for o = 1, math.floor(1500 / STEP) do
    local j = idx(c.m - o)
    d = d + D[j]
    if vp[j] >= c.vEntry * 0.995 then return d end
  end
  return d
end

-- Metres the brake point moved vs. the untrained line (+ = later braking)
-- Metres the brake point moved vs. the untrained line (+ = later braking).
-- The braking ramp keeps its shape, so for the same approach speed it shifts by
-- (v_learned^2 - v_base^2) / (2 * decel at the apex). Only this corner counts.
local function brakeShift(c)
  local vl, vb = VT[c.m], VTB[c.m] or VT[c.m]
  local vm = math.max(vl, vb)
  local a = S.safety * (S.brakeG * G + AERO_C * S.aero * vm * vm)
  return (vl * vl - vb * vb) / (2 * math.max(1, a))
end

local function serialize()
  local t = { 'N;' .. N }
  for _, c in ipairs(CORN) do
    t[#t + 1] = string.format('%d;%.5f;%d;%d;%.3f;%.4f;%.4f;%d;%.4f;%.4f;%.4f;%d;%d', c.m, c.mult, c.passes,
      c.clean, c.bestV, c.bestT, c.baseSum, c.baseN, c.lastT, c.ownT, c.aiBestT, c.useOwn and 1 or 0, c.ownStart or 0)
  end
  local acc = {}
  for b = 0, 40 do acc[#acc + 1] = string.format('%.3f', ACCL[b] or 0) end
  t[#t + 1] = 'A;' .. string.format('%.2f', vTopSeen) .. ';' .. table.concat(acc, ',')
  t[#t + 1] = 'B;' .. string.format('%d', bestLapMs)
  for _, c in ipairs(CORN) do
    if c.own then
      local parts = {}
      for i2, o in ipairs(c.own) do parts[i2] = string.format('%.2f', o) end
      t[#t + 1] = 'L;' .. c.m .. ';' .. table.concat(parts, ',')
    end
  end
  return table.concat(t, '\n')
end

local function deserialize(text)
  if not text then return false end
  local lines = {}
  for line in text:gmatch('[^\r\n]+') do lines[#lines + 1] = line end
  if #lines == 0 or lines[1] ~= 'N;' .. N then return false end
  local byM = {}
  for _, c in ipairs(CORN) do byM[c.m] = c end
  for li = 2, #lines do
    local f = {}
    for part in lines[li]:gmatch('[^;]+') do f[#f + 1] = part end
    local c = f[1] and byM[tonumber(f[1])]
    if c and #f >= 5 then
      c.mult = tonumber(f[2]) or 1
      c.passes = tonumber(f[3]) or 0
      c.clean = tonumber(f[4]) or 0
      c.bestV = tonumber(f[5]) or 0
      c.bestT = tonumber(f[6]) or 0
      c.baseSum = tonumber(f[7]) or 0
      c.baseN = tonumber(f[8]) or 0
      c.lastT = tonumber(f[9]) or 0
      c.ownT = tonumber(f[10]) or 0
      c.aiBestT = tonumber(f[11]) or 0
      c.useOwn = f[12] == '1'
      c.ownStart = tonumber(f[13]) or 0
    elseif f[1] == 'A' and f[2] and f[3] then
      vTopSeen = tonumber(f[2]) or 0
      local b = 0
      for num in f[3]:gmatch('[^,]+') do
        local a = tonumber(num) or 0
        ACCL[b] = a > 0 and a or nil
        b = b + 1
      end
    elseif f[1] == 'B' and f[2] then
      bestLapMs = tonumber(f[2]) or 0
    elseif f[1] == 'L' and f[2] and f[3] then
      local cc = byM[tonumber(f[2])]
      if cc then
        cc.own = {}
        for num in f[3]:gmatch('[^,]+') do cc.own[#cc.own + 1] = tonumber(num) or 0 end
      end
    end
  end
  for _, c in ipairs(CORN) do
    if c.useOwn and not c.own then c.useOwn = false end
  end
  return true
end

local function saveLearning(suffix)
  return writeFile(learnPath(suffix), serialize())
end

local function resetCorners()
  for _, c in ipairs(CORN) do
    c.mult, c.passes, c.clean, c.bestV, c.last = 1, 0, 0, 0, ''
    c.bestT, c.baseSum, c.baseN, c.lastT, c.lastDelta = 0, 0, 0, 0, nil
    c.ownT, c.aiBestT, c.useOwn, c.own, c.ownStart, c.aiVirtT = 0, 0, false, nil, 0, 0
  end
  bestLapMs = 0
end

local function resetLines()
  for _, c in ipairs(CORN) do
    c.ownT, c.useOwn, c.own, c.ownStart = 0, false, nil, 0
  end
end

local function loadLearning(suffix)
  resetCorners()
  local ok = deserialize(readFile(learnPath(suffix)))
  applyGM()
  applyLines()
  computeProfile()
  return ok
end

local function buildCorners()
  CORN = {}
  for i = 1, N do ZONE[i] = nil end
  local win = math.floor(60 / STEP)
  for i = 1, N do
    local vi = VT[i]
    if vi < 240 / 3.6 then
      local isMin = true
      for o = -win, win do
        if o ~= 0 then
          local vo = VT[idx(i + o)]
          if vo < vi or (vo == vi and o < 0) then isMin = false break end
        end
      end
      if isMin then
        local before = 0
        for o = 1, math.floor(300 / STEP) do
          local vo = VT[idx(i - o)]
          if vo > before then before = vo end
        end
        if before > vi * 1.12 then
          CORN[#CORN + 1] = { m = i, mult = 1, passes = 0, clean = 0, bestV = 0, last = '', vEntry = before,
            bestT = 0, baseSum = 0, baseN = 0, lastT = 0,
            ownT = 0, aiBestT = 0, useOwn = false, own = nil, ownStart = 0, aiVirtT = 0 }
        end
      end
    end
  end
  table.sort(CORN, function(a, b) return a.m < b.m end)
  local nC = #CORN
  local cum, acc = {}, 0
  for i = 1, N do cum[i] = acc acc = acc + D[i] end
  for id, c in ipairs(CORN) do
    c.id = id
    c.km = cum[c.m] / 1000
    local prev = CORN[((id - 2) % nC) + 1]
    local nxt = CORN[(id % nC) + 1]
    local gapPrev = nC > 1 and fwdSteps(prev.m, c.m) or N
    local gapNext = nC > 1 and fwdSteps(c.m, nxt.m) or N
    c.zsOff = math.min(math.floor(250 / STEP), math.floor(gapPrev / 2))
    c.zeOff = math.min(math.floor(80 / STEP), math.floor(gapNext / 2) - 1)
    local lim = VT[c.m] * 1.25
    local maxW = math.floor(120 / STEP)
    c.infL, c.infR = 0, 0
    while c.infL < maxW and VT[idx(c.m - c.infL - 1)] < lim do c.infL = c.infL + 1 end
    while c.infR < maxW and VT[idx(c.m + c.infR + 1)] < lim do c.infR = c.infR + 1 end
    for o = -c.zsOff, c.zeOff do ZONE[idx(c.m + o)] = id end
  end
end

local pass = nil
local prevCi = nil

-- Seconds saved in this corner since learning started (baseline = avg of first 3 clean passes)
local function cornerGain(c)
  if c.baseN < 1 or c.bestT <= 0 then return nil end
  return c.baseSum / c.baseN - c.bestT
end

local function totalGain()
  local sum, n = 0, 0
  for _, c in ipairs(CORN) do
    local g = cornerGain(c)
    if g then sum, n = sum + g, n + 1 end
  end
  return sum, n
end

local function recordTime(c, t, clean)
  c.lastT = t
  c.lastDelta = (c.bestT > 0) and (t - c.bestT) or nil
  if clean then
    if c.baseN < 3 then
      c.baseSum = c.baseSum + t
      c.baseN = c.baseN + 1
    end
    if c.bestT <= 0 or t < c.bestT then c.bestT = t end
  end
end

-- Timed stretch of a corner: from the timer gate to the end of its zone
local function timedRange(c) return -(c.zsOff - 16), c.zeOff end

-- How long the AI line takes over the timed stretch at the limit (no safety margin)
local function aiVirtualTime(c)
  local k0, k1 = timedRange(c)
  local t = 0
  for k = k0, k1 do
    local j = idx(c.m + k)
    t = t + DA[j] / math.max(1, VPA[j])
  end
  return t
end

-- Turns the recorded lateral offsets of a pass into a smooth line over the corner zone
local function buildOwnLine(rec, k0, k1)
  local known = {}
  for k = k0, k1 do if rec[k] then known[#known + 1] = k end end
  if #known < (k1 - k0) * 0.3 then return nil end
  local arr, ki = {}, 1
  for k = k0, k1 do
    while known[ki + 1] and known[ki + 1] <= k do ki = ki + 1 end
    local a, b = known[ki], known[ki + 1]
    local val
    if k <= known[1] then val = rec[known[1]]
    elseif not b then val = rec[a]
    else val = rec[a] + (rec[b] - rec[a]) * (k - a) / (b - a) end
    arr[#arr + 1] = val
  end
  local sm = {}
  for t = 1, #arr do
    local sum, n = 0, 0
    for o = -4, 4 do
      local x = arr[t + o]
      if x then sum, n = sum + x, n + 1 end
    end
    sm[t] = sum / n
  end
  return sm
end

-- Decide whether your line replaces the AI line in this corner (or goes back to AI).
-- Your line only wins if a clean pass beats BOTH the AI line's virtual time at the
-- limit AND your own best real time while following the AI line.
local function judgeLine(c, p)
  c.aiVirtT = aiVirtualTime(c)
  if p.maxDev <= OWN_MAX_DEV then
    if c.aiBestT <= 0 or p.t < c.aiBestT then c.aiBestT = p.t end
    if c.useOwn and p.t < c.ownT then
      c.useOwn = false
      return string.format('C%d: AI line is faster again (%.2f s), switched back', c.id, p.t)
    end
    return nil
  end
  if c.aiBestT > 0 and p.t < c.aiVirtT and p.t < c.aiBestT and (not c.useOwn or p.t < c.ownT) then
    local zs = -c.zsOff
    local own = buildOwnLine(p.rec, zs, c.zeOff)
    if own then
      c.own, c.ownStart, c.ownT, c.useOwn = own, zs, p.t, true
      return string.format('C%d: your line adopted! %.2f s vs AI %.2f s (virtual)', c.id, p.t, c.aiVirtT)
    end
  end
  return nil
end

local function evaluatePass(p)
  local c = p.c
  local lineMsg = nil
  if p.timing and p.t > 0.3 and not (p.off or p.spin) then
    lineMsg = judgeLine(c, p)
  end
  local timed = p.timing and p.t > 0.3
  if timed then recordTime(c, p.t, not (p.off or p.spin)) end
  local target = VT[c.m]
  local aggr = S.aggressive
  local before = brakeShift(c)
  c.passes = c.passes + 1
  if p.off or p.spin then
    c.mult = math.max(0.70, c.mult * (1 - (aggr and 0.08 or 0.04)))
    c.last = p.spin and 'spin' or 'off track'
  else
    c.clean = c.clean + 1
    if p.minV > c.bestV then c.bestV = p.minV end
    local r = p.minV / target
    if r >= 1.0 then
      local gain = (r * r - 1) * (aggr and 0.9 or 0.35)
      gain = math.min(gain, aggr and 0.08 or 0.03)
      gain = math.max(gain, aggr and 0.015 or 0.005)
      c.mult = math.min(1.50, c.mult * (1 + gain))
      c.last = 'faster'
    elseif r >= 0.97 then
      c.mult = math.min(1.50, c.mult * (1 + (aggr and 0.01 or 0.003)))
      c.last = 'at limit'
    else
      c.last = 'clean'
    end
  end
  applyGM()
  if lineMsg then applyLines() end
  computeProfile()
  saveLearning()
  local moved = brakeShift(c) - before
  local msg = string.format('C%d %s', c.id, c.last)
  if timed then
    msg = msg .. string.format('  %.2f s', p.t)
    if c.lastDelta then msg = msg .. string.format(' (%+.2f vs best)', c.lastDelta) end
  end
  if math.abs(moved) >= 0.5 then
    msg = msg .. string.format('  | brake %.0f m %s', math.abs(moved), moved > 0 and 'later' or 'earlier')
  end
  setMsg(lineMsg or msg)
end

local function trackLearning(car)
  if not S.learn or #CORN == 0 then prevCi = ci return end
  if prevCi then
    local d = fwdSteps(prevCi, ci)
    if d > 40 and d < N - 5 then pass = nil end
  end
  prevCi = ci

  local inPit = field(car, 'isInPitlane') or field(car, 'isInPit')
  local z = ZONE[ci]
  if pass and z ~= pass.c.id then
    local c = pass.c
    local off = fwdSteps(c.m, ci)
    if pass.valid and off > 0 and off <= c.zeOff + 20 then evaluatePass(pass) end
    pass = nil
  end
  if not pass and z and not inPit then
    local c = CORN[z]
    local back = fwdSteps(ci, c.m)
    pass = { c = c, valid = back >= c.zsOff - 15 and v > 8, minV = 1e9, off = false, spin = false,
      timing = false, t = 0, rec = {}, maxDev = 0 }
  end
  if pass then
    -- record where you are relative to the AI line (lateral offset, metres)
    local pos = field(car, 'position')
    if pos then
      local k = fwdSteps(pass.c.m, ci)
      if k > N / 2 then k = k - N end
      local lat = (pos.x - P[ci].x) * SAX[ci] + (pos.z - P[ci].z) * SAZ[ci]
      pass.rec[k] = lat
      if pass.timing and math.abs(lat) > pass.maxDev then pass.maxDev = math.abs(lat) end
    end
    -- corner timer: starts at a fixed gate so every pass measures the same stretch
    local paused = field(ac.getSim(), 'isPaused')
    if pass.timing then
      if not paused then pass.t = pass.t + frameDt end
    elseif pass.valid and fwdSteps(ci, pass.c.m) <= pass.c.zsOff - 16 then
      pass.timing = true
      pass.t = 0
    end
    if v < pass.minV then pass.minV = v end
    local wo = field(car, 'wheelsOutside')
    if type(wo) == 'number' and wo >= 4 then pass.off = true end
    if v > 11 then
      local look, vel = field(car, 'look'), field(car, 'velocity')
      if look and vel then
        local ll = math.sqrt(look.x * look.x + look.z * look.z)
        local vl = math.sqrt(vel.x * vel.x + vel.z * vel.z)
        if ll > 1e-3 and vl > 1e-3 then
          local cosA = (look.x * vel.x + look.z * vel.z) / (ll * vl)
          if cosA < 0.82 then pass.spin = true end
        end
      end
    end
    if inPit then pass.valid = false end
  end
end

---------------------------------------------------------------------------
-- Track build
---------------------------------------------------------------------------

-- Horizontal curvature (Menger, ~8 m window), smoothed
local function curvature(pts, out)
  local w = math.max(2, math.floor(8 / STEP + 0.5))
  local raw = {}
  for i = 1, N do
    local a, b, c = pts[idx(i - w)], pts[i], pts[idx(i + w)]
    local abx, abz = b.x - a.x, b.z - a.z
    local acx, acz = c.x - a.x, c.z - a.z
    local bcx, bcz = c.x - b.x, c.z - b.z
    local cross = math.abs(abx * acz - abz * acx)
    local la = math.sqrt(abx * abx + abz * abz)
    local lb = math.sqrt(bcx * bcx + bcz * bcz)
    local lc = math.sqrt(acx * acx + acz * acz)
    local den = la * lb * lc
    raw[i] = den > 1e-6 and (2 * cross / den) or 0
  end
  for i = 1, N do
    local sum = 0
    for o = -w, w do sum = sum + raw[idx(i + o)] end
    out[i] = sum / (2 * w + 1)
  end
end

-- Builds the drawn line: AI line, replaced by your own line in corners where it won
applyLines = function()
  for i = 1, N do OFF[i] = 0 end
  for _, c in ipairs(CORN) do
    if c.useOwn and c.own then
      local n = #c.own
      for t = 1, n do
        local edge = math.min(t - 1, n - t)
        local w = math.min(1, edge / 15)          -- blend in/out over ~30 m
        OFF[idx(c.m + c.ownStart + t - 1)] = c.own[t] * w
      end
    end
  end
  local down = vec3(0, -1, 0)
  for i = 1, N do
    local o = OFF[i]
    if o ~= 0 then
      local p = P[i] + vec3(SAX[i] * o, 0, SAZ[i] * o)
      local ok, hit = pcall(physics.raycastTrack, p + vec3(0, 3, 0), down, 8)
      if ok and type(hit) == 'number' and hit >= 0 then p = p + vec3(0, 3 - hit, 0) end
      PE[i] = p
    else
      PE[i] = P[i]
    end
  end
  for i = 1, N do D[i] = math.max(0.1, (PE[idx(i + 1)] - PE[i]):length()) end
  curvature(PE, K)
  buildGeometry()
end

local function buildTrack()
  local sim = ac.getSim()
  local len = sim.trackLengthM
  if not len or len < 100 then
    local prev = ac.trackProgressToWorldCoordinate(0)
    len = 0
    for k = 1, 2000 do
      local p = ac.trackProgressToWorldCoordinate(k / 2000)
      len = len + (p - prev):length()
      prev = p
    end
  end
  N = math.max(200, math.floor(len / STEP))

  local down = vec3(0, -1, 0)
  local spread = 0
  for i = 1, N do
    local p = ac.trackProgressToWorldCoordinate((i - 1) / N)
    local ok, hit = pcall(physics.raycastTrack, p + vec3(0, 3, 0), down, 8)
    if ok and type(hit) == 'number' and hit >= 0 then
      p = p + vec3(0, 3 - hit, 0)
    end
    P[i] = p
    GM[i] = 1
    if i > 1 then spread = spread + (p - P[i - 1]):length() end
  end
  if spread < 50 then
    error('This track has no AI line (fast_lane.ai). Try another track or layout.')
  end

  for i = 1, N do
    local b = P[idx(i + 1)]
    DA[i] = math.max(0.1, (b - P[i]):length())
    D[i] = DA[i]
    PE[i] = P[i]
    OFF[i] = 0
    local dx, dz = b.x - P[i].x, b.z - P[i].z
    local lh = math.max(1e-4, math.sqrt(dx * dx + dz * dz))
    SAX[i], SAZ[i] = dz / lh, -dx / lh
  end

  -- Map: rotate the track so its longest axis is horizontal (fits the window better)
  local mx, mz = 0, 0
  for i = 1, N do mx = mx + P[i].x mz = mz + P[i].z end
  mx, mz = mx / N, mz / N
  local sxx, szz, sxz = 0, 0, 0
  for i = 1, N do
    local dx, dz = P[i].x - mx, P[i].z - mz
    sxx, szz, sxz = sxx + dx * dx, szz + dz * dz, sxz + dx * dz
  end
  local atan2 = math.atan2 or math.atan
  local th = 0.5 * atan2(2 * sxz, sxx - szz)
  local cs, sn = math.cos(-th), math.sin(-th)
  mapMinX, mapMaxX, mapMinZ, mapMaxZ = 1e9, -1e9, 1e9, -1e9
  for i = 1, N do
    local dx, dz = P[i].x - mx, P[i].z - mz
    local rx, rz = dx * cs - dz * sn, dx * sn + dz * cs
    MX[i], MZ[i] = rx, rz
    if rx < mapMinX then mapMinX = rx end
    if rx > mapMaxX then mapMaxX = rx end
    if rz < mapMinZ then mapMinZ = rz end
    if rz > mapMaxZ then mapMaxZ = rz end
  end
  mapLayout = nil

  curvature(P, KA)
  for i = 1, N do K[i] = KA[i] end

  buildGeometry()
  computeProfile()
  profileBase()
  buildCorners()
  buildPalette()

  local carId, trackId, layout = 'car', 'track', ''
  pcall(function() carId = ac.getCarID(0) end)
  pcall(function() trackId = ac.getTrackID() end)
  pcall(function() layout = ac.getTrackLayout() or '' end)
  saveKey = sanitize(carId) .. '__' .. sanitize(trackId) .. (layout ~= '' and ('_' .. sanitize(layout)) or '')
  if loadLearning() then setMsg('Learning loaded for this car and track') end
end

local function colorIndex(ratio)
  local t = (ratio - 0.90) / 0.15
  if t < 0 then t = 0 elseif t > 1 then t = 1 end
  return math.floor(t * PAL_STEPS + 0.5)
end

local function update(dt)
  if not built then
    built = true
    local ok, e = pcall(buildTrack)
    if ok then ready = true else err = tostring(e) end
  end
  if not ready then return end

  local car = ac.getCar(0)
  if not car then return end
  local sp = car.splinePosition or 0
  ci = idx(math.floor(sp * N) + 1)
  v = (car.speedKmh or 0) / 3.6

  pcall(function()
    -- learn the car's real acceleration at full throttle
    local gas, brk = field(car, 'gas') or 0, field(car, 'brake') or 0
    if vPrevAcc and frameDt > 0.001 then
      local a = (v - vPrevAcc) / frameDt
      if a > 25 or a < -60 then a = 0 accSmooth = 0 end   -- resets / teleports: ignore
      accSmooth = accSmooth + (a - accSmooth) * 0.15
      if gas > 0.95 and brk < 0.05 and v > 5 then
        local b = math.floor(v * 3.6 / 10)
        local cur = ACCL[b] or 0
        if accSmooth > cur then ACCL[b] = cur + (accSmooth - cur) * 0.05 end
      end
    end
    vPrevAcc = v
    if v > vTopSeen then vTopSeen = v end
    -- your best lap (from the game)
    local bl = field(car, 'bestLapTimeMs')
    if type(bl) == 'number' and bl > 10000 and (bestLapMs <= 0 or bl < bestLapMs) then
      bestLapMs = bl
      computeProfile()
      saveLearning()
    end
  end)
  local ok, e = pcall(trackLearning, car)
  if not ok then pass = nil setMsg('Learning error: ' .. tostring(e)) end

  local dist = 0
  brakeIn = nil
  local maxSteps = math.floor(math.max(S.ahead, 600) / STEP)
  for o = 0, maxSteps do
    local j = idx(ci + o)
    if v > VP[j] then brakeIn = dist break end
    dist = dist + D[j]
  end

  local minV, minD, dd = 1e9, 0, 0
  for o = 1, math.floor(800 / STEP) do
    local j = idx(ci + o)
    dd = dd + D[j]
    if VT[j] < minV then minV, minD = VT[j], dd end
  end
  if minV < VCAP * 0.95 then
    nextCornerKmh, nextCornerDist = minV * 3.6, minD
  else
    nextCornerKmh, nextCornerDist = nil, nil
  end

  if brakeIn == nil then
    hudText, hudColor = 'CLEAR', C_GREEN
  elseif brakeIn < 3 then
    hudText, hudColor = 'BRAKE!', C_RED
  elseif brakeIn < 60 then
    hudText, hudColor = string.format('BRAKE IN %.0f m', brakeIn), C_ORANGE
  elseif brakeIn < 200 then
    hudText, hudColor = string.format('Brake in %.0f m', brakeIn), C_YELLOW
  else
    hudText, hudColor = string.format('Brake in %.0f m', brakeIn), C_GREEN
  end
end

-- Ctrl+Shift+D toggles the line
local hotWas = false
local function keyDown(k)
  local ok, r = pcall(ac.isKeyDown, k)
  return ok and r
end
local function hotkey()
  local KI = ui and ui.KeyIndex
  if not KI or not KI.Control or not KI.Shift or not KI.D then return end
  local now = keyDown(KI.Control) and keyDown(KI.Shift) and keyDown(KI.D)
  if now and not hotWas then
    S.show = not S.show
    setMsg(S.show and 'Line on' or 'Line off')
  end
  hotWas = now and true or false
end

function script.update(dt)
  frameDt = dt or 0.016
  update(dt)
  pcall(hotkey)
end

---------------------------------------------------------------------------
-- 3D drawing
---------------------------------------------------------------------------

local function place(q, j, s, f, ca, sa)
  local fc = f * ca
  q.x = BX[j] + SX[j] * s + FX[j] * fc
  q.y = BY[j] + FY[j] * fc + f * sa
  q.z = BZ[j] + SZ[j] * s + FZ[j] * fc
end

local function drawShape(j, shape, size, ca, sa, col)
  for qi = 1, #shape do
    local q = shape[qi]
    place(Q1, j, q[1] * size, q[2] * size, ca, sa)
    place(Q2, j, q[3] * size, q[4] * size, ca, sa)
    place(Q3, j, q[5] * size, q[6] * size, ca, sa)
    place(Q4, j, q[7] * size, q[8] * size, ca, sa)
    render.quad(Q1, Q2, Q3, Q4, col)
  end
end

local function drawLine(j, halfW, len, col)
  place(Q1, j, -halfW, 0, 1, 0)
  place(Q2, j, halfW, 0, 1, 0)
  place(Q3, j, halfW, len, 1, 0)
  place(Q4, j, -halfW, len, 1, 0)
  render.quad(Q1, Q2, Q3, Q4, col)
end

function draw3D()
  if not ready or not S.show then return end
  render.setBlendMode(render.BlendMode.AlphaBlend)
  render.setCullMode(render.CullMode.None)
  render.setDepthMode(render.DepthMode.ReadOnlyLessEqual)
  local fromO = -math.floor(S.behind / STEP)
  local toO = math.floor(S.ahead / STEP)
  local ease = math.min(1, frameDt * S.fallSpeed)
  local style = math.floor(S.style + 0.5)
  local size = S.size
  local shape = SHAPES[style]
  local useTilt = S.domino and shape ~= nil

  for o = fromO, toO do
    local j = idx(ci + o)
    local k = colorIndex(v / VP[j])
    local col = PAL[k]
    if shape == nil then
      drawLine(j, size * 0.3, D[j] * 1.02, col)
    else
      local ca, sa = 1, 0
      if useTilt then
        local t = k / PAL_STEPS
        local target = (t - 0.55) / 0.40
        if target < 0 then target = 0 elseif target > 1 then target = 1 end
        local a = ANG[j] + (target - ANG[j]) * ease
        ANG[j] = a
        if a > 0.02 then
          local th = a * 1.5707963
          ca, sa = math.cos(th), math.sin(th) * S.stand
        end
      end
      drawShape(j, shape, size, ca, sa, col)
    end
  end
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------

local function offY(y) if ui.offsetCursorY then ui.offsetCursorY(y) end end

local function availW()
  local ok, w = pcall(ui.availableSpaceX)
  if ok and type(w) == 'number' and w > 50 then return w end
  return 360
end

local function header(text)
  offY(4)
  ui.textColored(text, C_TITLE)
  ui.separator()
end

local function hint(text) ui.textColored(text, C_DIM) end

local function slider(key, label, min, max, fmt, rebuild)
  if ui.setNextItemWidth then ui.setNextItemWidth(availW()) end
  local val, changed = ui.slider('##' .. key, S[key], min, max, label .. ': ' .. fmt)
  if changed then
    S[key] = val
    if ready then
      if rebuild == 'profile' then recomputeAll()
      elseif rebuild == 'geometry' then buildGeometry()
      elseif rebuild == 'palette' then buildPalette() end
    end
  end
end

local function toggle(key, label)
  if ui.checkbox(label, S[key]) then S[key] = not S[key] end
end

local function multColor(m)
  if m > 1.005 then return C_GREEN
  elseif m < 0.995 then return C_ORANGE end
  return C_GREY
end

-- Brake distance bar (fills up as the brake point gets closer)
local function drawBrakeBar()
  local w, h = availW(), 8
  local p = ui.getCursor()
  local frac = 0
  if brakeIn then frac = 1 - math.min(1, brakeIn / 300) end
  ui.drawRectFilled(p, vec2(p.x + w, p.y + h), rgbm(1, 1, 1, 0.08), 3)
  if frac > 0 then
    ui.drawRectFilled(p, vec2(p.x + w * frac, p.y + h), hudColor, 3)
  end
  ui.dummy(vec2(w, h))
end

local function hud()
  ui.pushFont(ui.Font.Huge)
  ui.textColored(hudText, hudColor)
  ui.popFont()
  pcall(drawBrakeBar)
  offY(2)
  if nextCornerKmh then
    ui.text(string.format('Next corner  %.0f km/h  in %.0f m', nextCornerKmh, nextCornerDist))
  else
    ui.textColored('No slow corner in the next 800 m', C_DIM)
  end
  ui.textColored(string.format('Speed  %.0f km/h', v * 3.6), C_GREY)
  if learnMsg ~= '' and os.clock() - learnMsgTime < 8 then
    ui.textColored(learnMsg, C_INFO)
  end
end

-- Label layout: start each label on the outside of its corner (perpendicular to
-- the track), then nudge labels apart until they don't overlap each other or the
-- track. Cached until the map size or corner list changes.
local function buildMapLayout(w, h)
  local pad = 18
  local sx = math.max(1, mapMaxX - mapMinX)
  local sz = math.max(1, mapMaxZ - mapMinZ)
  local scale = math.min((w - pad * 2) / sx, (h - pad * 2) / sz)
  local ox = (w - sx * scale) / 2
  local oy = (h - sz * scale) / 2
  local function pr(i) return ox + (MX[i] - mapMinX) * scale, oy + (mapMaxZ - MZ[i]) * scale end

  local stride = math.max(3, math.floor(N / 450))
  local TS = {}
  for i = 1, N, stride do
    local x, y = pr(i)
    TS[#TS + 1] = { x, y }
  end

  local labs = {}
  for _, c in ipairs(CORN) do
    local px, py = pr(c.m)
    local ax, ay = pr(idx(c.m - 5))
    local bx, by = pr(idx(c.m + 5))
    local tx, ty = bx - ax, by - ay
    local tl = math.max(1e-3, math.sqrt(tx * tx + ty * ty))
    local nx, ny = -ty / tl, tx / tl
    -- pick the side of the track with less stuff around
    local best, bestCount = 1, 1e9
    for _, s in ipairs({ 1, -1 }) do
      local qx, qy = px + nx * s * 18, py + ny * s * 18
      local cnt = 0
      for _, t in ipairs(TS) do
        if math.abs(t[1] - qx) < 16 and math.abs(t[2] - qy) < 10 then cnt = cnt + 1 end
      end
      if cnt < bestCount then best, bestCount = s, cnt end
    end
    local label = 'C' .. c.id
    labs[#labs + 1] = {
      c = c, label = label, px = px, py = py,
      x = px + nx * best * 18, y = py + ny * best * 18,
      w = 7 * #label + 4, h = 13,
    }
  end

  local function sgn(v) return v >= 0 and 1 or -1 end
  for _ = 1, 90 do
    for i, a in ipairs(labs) do
      local fx, fy = 0, 0
      for j, b in ipairs(labs) do
        if i ~= j then
          local dx, dy = a.x - b.x, a.y - b.y
          local ovx = (a.w + b.w) / 2 + 3 - math.abs(dx)
          local ovy = (a.h + b.h) / 2 + 2 - math.abs(dy)
          if ovx > 0 and ovy > 0 then
            if ovx < ovy then fx = fx + sgn(dx) * ovx * 0.5 else fy = fy + sgn(dy) * ovy * 0.5 end
          end
        end
        -- keep off every corner dot
        local ddx, ddy = a.x - b.px, a.y - b.py
        if math.abs(ddx) < a.w / 2 + 4 and math.abs(ddy) < a.h / 2 + 4 then
          fx, fy = fx + sgn(ddx) * 1.2, fy + sgn(ddy) * 1.2
        end
      end
      for _, t in ipairs(TS) do
        local dx, dy = a.x - t[1], a.y - t[2]
        if math.abs(dx) < a.w / 2 + 3 and math.abs(dy) < a.h / 2 + 3 then
          fx, fy = fx + sgn(dx) * 0.8, fy + sgn(dy) * 0.8
        end
      end
      -- don't drift too far from its corner
      local dx, dy = a.px - a.x, a.py - a.y
      local d = math.sqrt(dx * dx + dy * dy)
      if d > 34 then fx, fy = fx + dx / d * (d - 34) * 0.15, fy + dy / d * (d - 34) * 0.15 end
      a.x = math.min(w - a.w / 2 - 2, math.max(a.w / 2 + 2, a.x + fx))
      a.y = math.min(h - a.h / 2 - 2, math.max(a.h / 2 + 2, a.y + fy))
    end
  end

  return { w = w, h = h, n = #CORN, pr = pr, labs = labs }
end

local function drawMap(w, h)
  local origin = ui.getCursor()
  if not mapLayout or mapLayout.w ~= w or mapLayout.h ~= h or mapLayout.n ~= #CORN then
    mapLayout = buildMapLayout(w, h)
  end
  local L = mapLayout
  local ox, oy = origin.x, origin.y
  local function proj(i)
    local x, y = L.pr(i)
    return vec2(ox + x, oy + y)
  end
  ui.drawRectFilled(origin, vec2(ox + w, oy + h), rgbm(0, 0, 0, 0.18), 6)

  local stride = 6
  local prev = proj(1)
  for i = 1 + stride, N + stride, stride do
    local j = idx(i)
    local cur = proj(j)
    ui.drawLine(prev, cur, multColor(GM[j] or 1), 3)
    prev = cur
  end

  for _, a in ipairs(L.labs) do
    local c = a.c
    local active = pass and pass.c == c
    local col = active and rgbm(1, 1, 0.5, 1) or multColor(c.mult)
    local p = vec2(ox + a.px, oy + a.py)
    -- leader line to the nearest edge of the label box
    local ex = math.max(a.x - a.w / 2, math.min(a.px, a.x + a.w / 2))
    local ey = math.max(a.y - a.h / 2, math.min(a.py, a.y + a.h / 2))
    ui.drawLine(p, vec2(ox + ex, oy + ey), rgbm(col.r, col.g, col.b, 0.5), 1)
    ui.drawCircleFilled(p, active and 4 or 2.5, col)
    ui.setCursor(vec2(ox + a.x - a.w / 2 + 2, oy + a.y - a.h / 2 - 1))
    ui.textColored(a.label, col)
  end

  ui.drawCircleFilled(proj(ci), 5, rgbm(1, 1, 1, 1))
  ui.setCursor(origin)
  ui.dummy(vec2(w, h))
end

local LAST_COLOR = {
  ['faster'] = C_GREEN, ['at limit'] = C_GREEN, ['clean'] = C_GREY,
  ['spin'] = C_RED, ['off track'] = C_RED,
}

-- The corner you are in, or the next one ahead
local function focusCorner()
  local z = ZONE[ci]
  if z then return CORN[z] end
  local best, bd = nil, 1e9
  for _, c in ipairs(CORN) do
    local d = fwdSteps(ci, c.m)
    if d < bd then best, bd = c, d end
  end
  return best
end

local manualPageTime = -100   -- after pressing < or >, auto paging waits a bit

local function cornersTable()
  if #CORN == 0 then
    hint('No corners detected yet.')
    return
  end
  local pages = math.max(1, math.ceil(#CORN / ROWS_PER_PAGE))
  -- follow the car: show the page of the corner you're in / approaching
  if os.clock() - manualPageTime > 10 then
    local fc = focusCorner()
    if fc then S.page = math.ceil(fc.id / ROWS_PER_PAGE) end
  end
  if S.page > pages then S.page = pages end
  if S.page < 1 then S.page = 1 end
  local gain, timedN = totalGain()
  if timedN > 0 then
    local gs = math.abs(gain) < 0.005 and '0.00' or string.format('%s%.2f', gain >= 0 and '-' or '+', math.abs(gain))
    ui.textColored(string.format('Learning gain: %s s per lap  (%d corners timed)', gs, timedN),
      gain >= 0 and C_GREEN or C_ORANGE)
  else
    hint('Lap time gain shows up after your first clean passes.')
  end
  ui.pushFont(ui.Font.Monospace)
  ui.textColored('Corner Target Grip  Brake  Best    Gain toAI  Clean Last', C_TITLE)
  local from = (S.page - 1) * ROWS_PER_PAGE + 1
  local shown = 0
  for i = from, math.min(#CORN, from + ROWS_PER_PAGE - 1) do
    local c = CORN[i]
    local g = cornerGain(c)
    local bestS = c.bestT > 0 and string.format('%5.2fs', c.bestT) or '   -  '
    local gainS = g and (math.abs(g) < 0.005 and ' 0.00' or string.format('%+5.2f', -g)) or '   - '
    local function r0(x) local y = math.floor(x + 0.5) if y == 0 then return 0 end return y end
    local lineS
    if c.useOwn then
      lineS = 'YOU'
    elseif c.bestT > 0 then
      lineS = string.format('%+.2f', c.bestT - aiVirtualTime(c))
    else
      lineS = 'AI'
    end
    local line = string.format('C%-4d %4.0f  %+4d%% %+4dm  %s %s %-5s %2d/%-2d ',
      c.id, VT[c.m] * 3.6, r0((c.mult - 1) * 100), r0(brakeShift(c)), bestS, gainS,
      lineS, c.clean, c.passes)
    local active = pass and pass.c == c
    ui.textColored(line, active and rgbm(1, 1, 0.5, 1) or multColor(c.mult))
    ui.sameLine(0, 0)
    ui.textColored(c.last or '', LAST_COLOR[c.last or ''] or C_GREY)
    shown = shown + 1
  end
  for _ = shown + 1, ROWS_PER_PAGE do ui.text(' ') end   -- keep the height fixed
  ui.popFont()
  offY(2)
  if ui.button('  <  ') and S.page > 1 then S.page = S.page - 1 manualPageTime = os.clock() end
  ui.sameLine()
  ui.text(string.format('Page %d / %d', S.page, pages))
  ui.sameLine()
  if ui.button('  >  ') and S.page < pages then S.page = S.page + 1 manualPageTime = os.clock() end
  hint('Row colour: total learned. Last: latest pass only.')
  hint('Brake: metres later (+) / earlier (-) than untrained.')
  hint('Gain: best vs your first 3 clean passes (- = faster).')
  hint('toAI: your best vs the AI line at its limit (- = you beat it).')
  hint('YOU: your own line won in that corner.')
end

-- Button that shows as selected (filled green) when active
local hasStyleColor = ui.pushStyleColor ~= nil and ui.StyleColor ~= nil
local function choiceButton(label, selected, w)
  local pushed = 0
  if selected and hasStyleColor then
    local ok = pcall(function()
      ui.pushStyleColor(ui.StyleColor.Button, rgbm(0.18, 0.55, 0.28, 1))
      pushed = pushed + 1
      ui.pushStyleColor(ui.StyleColor.ButtonHovered, rgbm(0.22, 0.65, 0.33, 1))
      pushed = pushed + 1
      ui.pushStyleColor(ui.StyleColor.ButtonActive, rgbm(0.15, 0.48, 0.24, 1))
      pushed = pushed + 1
    end)
    if not ok then end
  end
  local text = label
  if selected and pushed == 0 then text = '> ' .. label .. ' <' end
  local clicked = ui.button(text, vec2(w, 0))
  if pushed > 0 then ui.popStyleColor(pushed) end
  return clicked
end

local function tabDrive()
  header('Line')
  toggle('show', 'Show line')
  ui.sameLine()
  hint('  Ctrl+Shift+D')
  offY(4)
  ui.text('Style')
  local bw = math.floor((availW() - 16) / 3)
  for i = 1, 3 do
    if i > 1 then ui.sameLine() end
    if choiceButton(STYLE_NAMES[i], math.floor(S.style + 0.5) == i, bw) then S.style = i end
  end
  if math.floor(S.style + 0.5) ~= 3 then
    offY(4)
    toggle('domino', '3D domino (red blocks stand up)')
  end
  header('Learning')
  toggle('learn', 'Learn from my laps')
  hint(string.format('%d corners detected on this track', #CORN))
end

local function tabLearning()
  header('Mode')
  toggle('learn', 'Learn from my laps')
  toggle('aggressive', 'Aggressive mode')
  if S.aggressive then
    ui.textColored('Adapts in 1-2 laps, but can learn from a lucky pass', C_ORANGE)
    ui.textColored('and make you brake too late. Use it once you know the track.', C_ORANGE)
  else
    hint('Conservative: max +3% per pass, -4% when you go off.')
  end

  header('Track map')
  local function fmtLap(t)
    local m = math.floor(t / 60)
    return string.format('%d:%06.3f', m, t - m * 60)
  end
  local beaten = bestLapMs > 0 and bestLapMs / 1000 < aiLapT
  ui.textColored(string.format('AI expected  %s  (+/- %.1f s)', fmtLap(aiLapT), aiLapErr),
    beaten and C_GREEN or C_VIOLET)
  if bestLapMs > 0 then
    ui.sameLine()
    ui.textColored(string.format('   Your best  %s', fmtLap(bestLapMs / 1000)),
      beaten and C_VIOLET or C_GREY)
  end
  local ok, e = pcall(drawMap, math.floor(availW()), 240)
  if not ok then ui.text('Map unavailable: ' .. tostring(e)) end
  ui.textColored('green: faster than calculated', C_GREEN)
  ui.sameLine()
  ui.textColored('  orange: struggled', C_ORANGE)

  header('Corners')
  cornersTable()

  header('Saved data')
  hint(saveKey)
  if ui.button('Save backup') then
    setMsg(saveLearning('_backup') and 'Backup saved' or 'Could not save backup')
  end
  ui.sameLine()
  if ui.button('Restore backup') then
    setMsg(loadLearning('_backup') and 'Backup restored' or 'No backup for this car and track')
    saveLearning()
  end
  ui.sameLine()
  if ui.button('Reset my lines') then
    resetLines()
    applyLines()
    computeProfile()
    saveLearning()
    setMsg('Back to the AI line in every corner')
  end
  ui.sameLine()
  if ui.button('Reset track') then
    resetCorners()
    applyGM()
    applyLines()
    computeProfile()
    saveLearning()
    setMsg('Learning reset for this car and track')
  end
end

local function tabSettings()
  header('Physics')
  hint('Warns you too late? Lower Braking or Margin.')
  slider('gripG', 'Lateral grip', 0.8, 2.5, '%.2f g', 'profile')
  slider('brakeG', 'Braking', 0.8, 2.5, '%.2f g', 'profile')
  slider('aero', 'Downforce', 0.0, 2.0, '%.2fx', 'profile')
  slider('safety', 'Margin', 0.60, 1.00, '%.2f', 'profile')
  header('Visual')
  slider('ahead', 'Distance ahead', 100, 3000, '%.0f m')
  slider('behind', 'Distance behind', 0, 50, '%.0f m')
  slider('size', 'Size', 0.20, 1.50, '%.2f m')
  slider('height', 'Height', 0.00, 0.50, '%.2f m', 'geometry')
  slider('bright', 'Brightness', 0.3, 4.0, '%.1f', 'palette')
  if math.floor(S.style + 0.5) ~= 3 and S.domino then
    header('Domino')
    slider('stand', 'Standing height', 0.5, 3.0, '%.1fx')
    slider('fallSpeed', 'Fall speed', 2, 30, '%.0f')
  end
end

local TABS = {
  { 'Drive', tabDrive },
  { 'Learning', tabLearning },
  { 'Settings', tabSettings },
}

-- Compact window: just the brake call and the bar
function windowHud(dt)
  if not ready then
    hint(err and 'Domino Line: error' or 'Loading...')
    return
  end
  ui.pushFont(ui.Font.Huge)
  ui.textColored(hudText, hudColor)
  ui.popFont()
  pcall(drawBrakeBar)
  if nextCornerKmh then
    ui.textColored(string.format('%.0f km/h in %.0f m', nextCornerKmh, nextCornerDist), C_GREY)
  end
end

function windowMain(dt)
  if err then
    ui.textColored('Error: ' .. err, C_RED)
    return
  end
  if not ready then
    ui.text('Loading racing line...')
    return
  end

  hud()
  offY(6)

  if ui.tabBar and ui.tabItem then
    ui.tabBar('##dominoTabs', function()
      for _, t in ipairs(TABS) do
        ui.tabItem(t[1], t[2])
      end
    end)
  else
    for i, t in ipairs(TABS) do
      if i > 1 then ui.sameLine() end
      if ui.button((S.tab == i and '> ' or '') .. t[1]) then S.tab = i end
    end
    ui.separator()
    if not TABS[S.tab] then S.tab = 1 end
    TABS[S.tab][2]()
  end
end
