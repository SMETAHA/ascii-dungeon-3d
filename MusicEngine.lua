-- MusicEngine.lua
-- Контекстная процедурная музыка. Версия с кэшем нот, чтобы не пересобирать SoundData каждые 0.3 сек.
local MusicEngine = {
  sampleRate = 22050,
  context = {},
  layers = {},
  percussion = {},
  drones = {},
  timer = 0,
  time = 0,
  noteCache = {},
  noteCacheOrder = {},
  maxCacheItems = 128,
  masterVolume = 1.0,
  musicVolume = 0.55,
  enabled = true,
  activeSources = {},
  maxActiveSources = 32
}

MusicEngine.instruments = {
  basic_sine = { waveform = "sine", envelope = {attack = 0.01, decay = 0.05}, effects = {tremolo = 0.1} },
  fat_square = { waveform = "square", envelope = {attack = 0.02, decay = 0.2}, effects = {vibrato = 5, detune = 0.01} },
  bass_saw = { waveform = "saw", envelope = {attack = 0.01, decay = 0.3}, effects = {tremolo = 0.05, detune = -0.02} },
  noisy_crunch = { waveform = "noise", envelope = {attack = 0.01, decay = 0.1}, effects = {} },
  ambient_triangle = { waveform = "triangle", envelope = {attack = 0.2, decay = 1.0}, effects = {tremolo = 0.2, vibrato = 2} }
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

local function noteKey(freq, dur, instr)
  local effects = instr.effects or {}
  local env = instr.envelope or {}
  return table.concat({
    instr.waveform or "sine",
    tostring(round(freq or 0, 0.01)),
    tostring(round(dur or 0, 0.01)),
    tostring(round(effects.vibrato or 0, 0.1)),
    tostring(round(effects.detune or 0, 0.001)),
    tostring(round(effects.tremolo or 0, 0.01)),
    tostring(round(env.attack or 0, 0.01)),
    tostring(round(env.decay or 0, 0.01))
  }, "|")
end

function MusicEngine:clearCache()
  self.noteCache = {}
  self.noteCacheOrder = {}
end

function MusicEngine:rememberNote(key, data)
  if self.noteCache[key] then return end
  self.noteCache[key] = data
  table.insert(self.noteCacheOrder, key)

  while #self.noteCacheOrder > self.maxCacheItems do
    local old = table.remove(self.noteCacheOrder, 1)
    self.noteCache[old] = nil
  end
end

function MusicEngine:setVolume(master, music)
  if master ~= nil then self.masterVolume = master end
  if music ~= nil then self.musicVolume = music end
end

function MusicEngine:cleanupSources()
  for i = #self.activeSources, 1, -1 do
    if not self.activeSources[i]:isPlaying() then
      table.remove(self.activeSources, i)
    end
  end
end

function MusicEngine:addLayer(name, cfg)
  cfg.fadeVolume = 0
  cfg.targetActive = false
  cfg.state = cfg.state or math.random(1, #cfg.scale)
  cfg.prevStates = {cfg.state}
  cfg.fadeSpeed = cfg.fadeSpeed or 0.5
  cfg.markovMemory = cfg.markovMemory or 1
  self.layers[name] = cfg
end

function MusicEngine:addPercussion(name, cfg)
  cfg.index, cfg.timer = 1, 0
  self.percussion[name] = cfg
end

function MusicEngine:addDrone(name, cfg)
  cfg.fadeVolume, cfg.timer = 0, 0
  self.drones[name] = cfg
end

function MusicEngine:updateContext(ctx)
  for k, v in pairs(ctx) do self.context[k] = v end
end

function MusicEngine:update(dt)
  if not self.enabled then return end
  self:cleanupSources()
  self.time = self.time + dt
  self.timer = self.timer + dt
  local shouldTick = self.timer >= 0.3

  for _, l in pairs(self.layers) do
    local active = l.condition and l.condition(self.context) or 0
    l.targetActive = active > 0
    l.targetVolume = active * (l.volume or 1.0)
    local delta = l.fadeSpeed * dt
    if l.targetActive then
      l.fadeVolume = math.min(l.targetVolume, l.fadeVolume + delta)
    else
      l.fadeVolume = math.max(0, l.fadeVolume - delta)
    end

    if l.fadeVolume > 0.001 and shouldTick then
      self:playLayer(l)
    end
  end

  for _, d in pairs(self.drones) do
    d.fadeVolume = math.min(d.volume or 0.1, d.fadeVolume + dt * 0.05)
    d.timer = d.timer + dt
    if d.timer > (d.interval or 8) then
      d.timer = 0
      self:playNote(d.note, d.duration or 4.0, d.fadeVolume, d.instrument)
    end
  end

  for _, p in pairs(self.percussion) do
    p.timer = p.timer + dt
    if p.pattern and #p.pattern > 0 then
      local item = p.pattern[p.index]
      if p.timer >= item.time then
        p.timer = 0
        self:playPercussion(item)
        p.index = (p.index % #p.pattern) + 1
      end
    end
  end

  if shouldTick then self.timer = self.timer - 0.3 end
end

function MusicEngine:playLayer(layer)
  local currState = layer.state
  local rhythm = self:getRhythm(layer.rhythm)
  local props = (layer.stateProperties and layer.stateProperties[currState]) or {}

  local vol = props.volume or layer.fadeVolume
  local dur = props.duration or rhythm
  local instr = props.instrument or layer.instrument or self.instruments.basic_sine
  local freq = layer.scale[currState] or layer.scale[1]

  self:playNote(freq, dur, vol, instr)

  local nextState = self:getNextState(layer.prevStates, layer.transitions, layer.markovMemory)
  table.insert(layer.prevStates, nextState)
  if #layer.prevStates > layer.markovMemory then table.remove(layer.prevStates, 1) end

  layer.state = nextState
end

function MusicEngine:buildNote(freq, dur, instr)
  dur = math.max(0.01, dur or 0.2)
  freq = math.max(1, freq or 220)
  instr = instr or self.instruments.basic_sine

  local s = love.sound.newSoundData(math.floor(dur * self.sampleRate), self.sampleRate, 16, 1)
  local waveform = instr.waveform or "sine"
  local effects = instr.effects or {}
  local env = instr.envelope or {attack = 0.01, decay = 0.1}
  local attack = math.max(env.attack or 0.01, 0.0001)
  local decay = math.max(env.decay or 0.1, 0.0001)

  for i = 0, s:getSampleCount() - 1 do
    local t = i / self.sampleRate
    local modF = freq * (1 + math.sin(2 * math.pi * (effects.vibrato or 0) * t) * 0.01) + (freq * (effects.detune or 0))
    local phase = t * modF
    local amp =
      waveform == "sine"     and math.sin(2 * math.pi * modF * t) or
      waveform == "square"   and (math.sin(2 * math.pi * modF * t) > 0 and 1 or -1) or
      waveform == "triangle" and 2 * math.abs(2 * (phase - math.floor(phase + 0.5))) - 1 or
      waveform == "saw"      and 2 * (phase - math.floor(phase + 0.5)) or
      waveform == "noise"    and (math.random() * 2 - 1) or 0

    local trem = 1 + math.sin(2 * math.pi * 5 * t) * (effects.tremolo or 0)
    local sample = amp * trem

    if t < attack then
      sample = sample * (t / attack)
    elseif t > dur - decay then
      sample = sample * math.max(0, (dur - t) / decay)
    end

    s:setSample(i, clamp(sample, -1, 1))
  end

  return s
end

function MusicEngine:playNote(freq, dur, vol, instr)
  instr = instr or self.instruments.basic_sine
  vol = clamp((vol or 0.5) * (self.masterVolume or 1) * (self.musicVolume or 1), 0, 1)
  if vol <= 0.001 or #self.activeSources >= self.maxActiveSources then return end

  local key = noteKey(freq, dur, instr)
  local data = self.noteCache[key]
  if not data then
    data = self:buildNote(freq, dur, instr)
    self:rememberNote(key, data)
  end

  local source = love.audio.newSource(data)
  source:setVolume(vol)
  source:play()
  table.insert(self.activeSources, source)
end

function MusicEngine:playPercussion(item)
  local instr = item.instrument or self.instruments.noisy_crunch
  local freq = item.freq or (item.sound == "kick" and 80 or item.sound == "snare" and 200 or item.sound == "hihat" and 4000 or 1000)
  self:playNote(freq, item.duration or 0.2, item.volume or 0.5, instr)
end

function MusicEngine:getRhythm(r)
  if not r then return 0.5 end
  local rVal, sum = math.random(), 0
  for _, chance in pairs(r) do sum = sum + chance end
  if sum <= 0 then return 0.5 end

  local acc = 0
  for dur, chance in pairs(r) do
    acc = acc + chance / sum
    if rVal <= acc then return dur end
  end
  return 0.5
end

function MusicEngine:getNextState(prevStates, transitions, mem)
  mem = mem or 1
  local tr = transitions
  for i = #prevStates - mem + 1, #prevStates do
    local s = prevStates[i]
    if tr and s then tr = tr[s] end
  end
  if type(tr) == "table" then
    local r, sum = math.random(), 0
    for _, v in pairs(tr) do sum = sum + v end
    if sum > 0 then
      for k, v in pairs(tr) do
        r = r - v / sum
        if r <= 0 then return k end
      end
    end
  end
  return prevStates[#prevStates]
end

return MusicEngine
