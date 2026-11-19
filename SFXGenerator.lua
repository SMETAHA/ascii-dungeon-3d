local SFXGenerator = {
  -- Для коротких процедурных SFX 22050 хватает, а CPU/памяти ест почти в 2 раза меньше.
  sampleRate = 22050,
  maxLayers = 4,
  cache = {},
  cacheOrder = {},
  maxCacheItems = 96,
  masterVolume = 1.0,
  sfxVolume = 0.9,
  activeSources = {},
  maxActiveSources = 24
}

local function clamp(v, a, b)
  if v < a then return a end
  if v > b then return b end
  return v
end

local function round(v, step)
  step = step or 1
  return math.floor(v / step + 0.5) * step
end

local function range(r)
  if type(r) ~= "table" then return r or 0 end
  return r[1] + math.random() * ((r[2] or r[1]) - r[1])
end

local function pick(t)
  if type(t) ~= "table" then return t end
  return t[math.random(1, #t)]
end

local function distort(x, factor)
  if factor <= 1 then return x end
  return math.floor(x * factor) / factor
end

local function cacheKey(params)
  local e = params.effects or {}
  local a = params.adsr or {}
  return table.concat({
    params.waveform,
    tostring(round(params.frequency, 5)),
    tostring(round(params.duration, 0.01)),
    tostring(round(params.volume, 0.05)),
    tostring(round(e.pitchbend or 0, 0.05)),
    tostring(round(e.vibrato or 0, 0.5)),
    tostring(round(e.bitcrush or 0, 0.05)),
    tostring(round(e.tremolo or 0, 0.05)),
    tostring(round(a.attack or 0, 0.01)),
    tostring(round(a.decay or 0, 0.01)),
    tostring(round(a.sustain or 0, 0.05)),
    tostring(round(a.release or 0, 0.01))
  }, "|")
end

function SFXGenerator:clearCache()
  self.cache = {}
  self.cacheOrder = {}
end

function SFXGenerator:remember(key, data)
  if self.cache[key] then return end
  self.cache[key] = data
  table.insert(self.cacheOrder, key)

  while #self.cacheOrder > self.maxCacheItems do
    local old = table.remove(self.cacheOrder, 1)
    self.cache[old] = nil
  end
end

function SFXGenerator:setVolume(master, sfx)
  if master ~= nil then self.masterVolume = master end
  if sfx ~= nil then self.sfxVolume = sfx end
end

function SFXGenerator:cleanupSources()
  for i = #self.activeSources, 1, -1 do
    if not self.activeSources[i]:isPlaying() then
      table.remove(self.activeSources, i)
    end
  end
end

function SFXGenerator:generate(config)
  self:cleanupSources()
  if #self.activeSources >= self.maxActiveSources then return end
  for i, layer in ipairs(config.layers or {}) do
    if i > self.maxLayers then break end
    local params = self:buildParams(layer, config.context)
    self:playLayer(params)
  end
end

function SFXGenerator:buildParams(layer, context)
  local adsr = layer.adsr or {attack = 0.01, decay = 0.05, sustain = 0.8, release = 0.1}
  return {
    waveform = pick(layer.waveform) or "sine",
    frequency = math.max(1, range(layer.frequency or {220, 220})),
    duration = clamp(range(layer.duration or {0.08, 0.08}), 0.01, 2.0),
    volume = clamp(range(layer.volume or {0.5, 0.5}), 0, 1),
    effects = layer.effects or {},
    adsr = adsr,
    pan = layer.pan or 0
  }
end

function SFXGenerator:buildSoundData(params)
  local n = math.max(1, math.floor(params.duration * self.sampleRate))
  local data = love.sound.newSoundData(n, self.sampleRate, 16, 1)

  local a = math.max(params.adsr.attack or 0.01, 0.0001)
  local d = math.max(params.adsr.decay or 0.05, 0.0001)
  local s = params.adsr.sustain or 0.8
  local r = math.max(params.adsr.release or 0.1, 0.0001)

  local pitchbend = params.effects.pitchbend or 0
  local vibrato = params.effects.vibrato or 0
  local bitcrush = params.effects.bitcrush or 0
  local tremolo = params.effects.tremolo or 0

  for i = 0, n - 1 do
    local t = i / self.sampleRate
    local freq = params.frequency + (pitchbend * params.frequency * t) + math.sin(2 * math.pi * vibrato * t) * params.frequency * 0.02
    local phase = t * freq
    local amp = 0

    if params.waveform == "sine" then
      amp = math.sin(2 * math.pi * freq * t)
    elseif params.waveform == "square" then
      amp = math.sin(2 * math.pi * freq * t) > 0 and 1 or -1
    elseif params.waveform == "saw" then
      amp = 2 * (phase - math.floor(phase + 0.5))
    elseif params.waveform == "triangle" then
      amp = 2 * math.abs(2 * (phase - math.floor(phase + 0.5))) - 1
    elseif params.waveform == "noise" then
      amp = math.random() * 2 - 1
    end

    if bitcrush > 0 then amp = distort(amp, 2 ^ math.floor(8 * bitcrush)) end
    if tremolo > 0 then amp = amp * (1 + math.sin(2 * math.pi * 5 * t) * tremolo) end

    local env = 1
    if t < a then
      env = t / a
    elseif t < a + d then
      env = 1 - (1 - s) * ((t - a) / d)
    elseif t < params.duration - r then
      env = s
    else
      env = s * math.max(0, (params.duration - t) / r)
    end

    amp = clamp(amp * env * params.volume, -1, 1)
    data:setSample(i, amp)
  end

  return data
end

function SFXGenerator:playLayer(params)
  local key = cacheKey(params)
  local data = self.cache[key]
  if not data then
    data = self:buildSoundData(params)
    self:remember(key, data)
  end

  if #self.activeSources >= self.maxActiveSources then return end
  local source = love.audio.newSource(data)
  source:setVolume(clamp((self.masterVolume or 1) * (self.sfxVolume or 1), 0, 1))
  source:play()
  table.insert(self.activeSources, source)
end

return SFXGenerator
