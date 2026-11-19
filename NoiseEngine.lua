-- NoiseEngine.lua
local NoiseEngine = {}

-- ===== ШУМЫ =====

function NoiseEngine.fbm(x, y, octaves, persistence)
    local total, frequency, amplitude = 0, 1, 1
    local maxValue = 0
    for i = 1, octaves do
        total = total + love.math.noise(x * frequency, y * frequency) * amplitude
        maxValue = maxValue + amplitude
        amplitude = amplitude * persistence
        frequency = frequency * 2
    end
    return total / maxValue
end

function NoiseEngine.ridged(x, y)
    return 1 - math.abs(love.math.noise(x, y) * 2 - 1)
end

function NoiseEngine.domainWarp(x, y)
    local qx = love.math.noise(x * 0.1, y * 0.1)
    local qy = love.math.noise(x * 0.1 + 5.2, y * 0.1 + 1.3)
    return love.math.noise(x + qx * 10, y + qy * 10)
end

function NoiseEngine.blended(x, y, t)
    local fb = NoiseEngine.fbm(x * 0.05 + t, y * 0.05, 5, 0.5)
    local rg = NoiseEngine.ridged(x * 0.1, y * 0.1)
    return 0.6 * fb + 0.4 * rg
end

function NoiseEngine.masked(x, y)
    local mask = love.math.noise(x * 0.05, y * 0.05)
    if mask > 0.5 then
        return NoiseEngine.fbm(x, y, 4, 0.5)
    else
        return NoiseEngine.ridged(x, y)
    end
end

-- ===== КЭШ =====

NoiseEngine.cache = {}

function NoiseEngine.defineVisuals()
    NoiseEngine.visuals = {
        cave = {
            ceilingFunc = function(x, y, t)
                local b = 0.4 + 0.4 * NoiseEngine.fbm(x * 0.02, y * 0.02 + t, 4, 0.5)
                return {30 * b / 255, 30 * b / 255, 60 * b / 255}
            end,
            floorFunc = function(x, y, t)
                local g = 0.5 + 0.4 * NoiseEngine.domainWarp(x * 0.05 + t, y * 0.05)
                return {g, g, g}
            end
        },

        forest = {
            ceilingFunc = function(x, y, t)
                local g = 0.4 + 0.3 * math.sin(x * 0.03 + t)
                return {0.1, g, 0.1}
            end,
            floorFunc = function(x, y, t)
                local l = 0.5 + 0.4 * NoiseEngine.blended(x * 0.05, y * 0.05, t)
                return {l, l + 0.1, l}
            end
        },

        dungeon = {
            ceilingFunc = function(x, y, t)
                local s = 0.3 + 0.2 * math.sin(y * 0.05 + t)
                return {s, s, s + 0.1}
            end,
            floorFunc = function(x, y, t)
                local gray = 0.4 + 0.2 * NoiseEngine.fbm(x * 0.05, y * 0.05, 3, 0.4)
                return {gray, gray, gray}
            end
        },
		castle = {
            ceilingFunc = function(x, y, t)
                local gold = 0.6 + 0.3 * math.sin(y * 0.03 + t)
                return {gold, gold * 0.8, gold * 0.2}
            end,
            floorFunc = function(x, y, t)
                local marble = 0.5 + 0.3 * NoiseEngine.fbm(x * 0.04, y * 0.04, 3, 0.5)
                return {marble * 0.9, marble * 0.9, marble}
            end
        },

        ruins = {
            ceilingFunc = function(x, y, t)
                local ash = 0.25 + 0.25 * NoiseEngine.ridged(x * 0.04 + t, y * 0.04)
                return {ash * 0.7, ash * 0.75, ash}
            end,
            floorFunc = function(x, y, t)
                local cracked = 0.25 + 0.45 * NoiseEngine.domainWarp(x * 0.035, y * 0.035 + t)
                return {cracked * 0.8, cracked * 0.75, cracked * 0.65}
            end
        }

    }
	
end

function NoiseEngine.precompute(baseWidth, baseHeight)
    NoiseEngine.cache = {}
    local t = 0
    for biomeName, visual in pairs(NoiseEngine.visuals) do
        NoiseEngine.cache[biomeName] = { floor = {}, ceiling = {} }
        for y = 0, baseHeight, 4 do
            NoiseEngine.cache[biomeName].floor[y] = {}
            NoiseEngine.cache[biomeName].ceiling[y] = {}
            for x = 0, baseWidth, 4 do
                local fc = visual.floorFunc(x, y, t)
                local cc = visual.ceilingFunc(x, y, t)
                NoiseEngine.cache[biomeName].floor[y][x] = fc
                NoiseEngine.cache[biomeName].ceiling[y][x] = cc
            end
        end
    end
end

function NoiseEngine.get(biome, layer, x, y)
    local b = NoiseEngine.cache[biome] or NoiseEngine.cache.dungeon
    if not b or not b[layer] then return {0, 0, 0} end
    return b[layer][y] and b[layer][y][x] or {0, 0, 0}
end

return NoiseEngine
