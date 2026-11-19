-- LootGenerator.lua
-- v11: предметы получили уровень, редкость, мягкий power-scaling и нормализацию процентных статов.

local LootTags = require("LootTags")
local LootTagEffects = require("LootTagEffects")

local LootGenerator = {}

local function clamp(v, a, b) if v < a then return a elseif v > b then return b else return v end end
local function pickRandom(tbl) if type(tbl) ~= "table" or #tbl == 0 then return nil end return tbl[love.math.random(1, #tbl)] end
local function normalizeKey(str) if type(str) ~= "string" then return str end return (str:gsub("%s+", "_"):gsub("%-", "_")) end
local function lookup(tbl, key) if type(tbl) ~= "table" then return nil end return tbl[key] or tbl[normalizeKey(key)] end
local function cloneStats(src) local t = {} for k, v in pairs(src or {}) do t[k] = v end return t end
local function normalizedStat(stat, value) if type(value) ~= "number" then return 0 end if (stat == "critChance" or stat == "dodge") and math.abs(value) > 1 then return value / 100 end return value end

local function mergeStats(base, bonus)
    if type(bonus) ~= "table" then return end
    for k, v in pairs(bonus) do
        if k == "allStats" then
            base.damage = (base.damage or 0) + 3; base.armor = (base.armor or 0) + 3; base.speed = (base.speed or 0) + 0.2; base.luck = (base.luck or 0) + 0.2
        elseif k == "randomStats" then
            local pool = {"damage", "armor", "speed", "luck", "range", "critChance", "attackSpeed", "critMultiplier", "dodge"}
            for _ = 1, 2 do local stat = pickRandom(pool); if stat then base[stat] = (base[stat] or 0) + love.math.random(1, 3) end end
        elseif k ~= "multiplier" and type(v) == "number" then
            base[k] = (base[k] or 0) + normalizedStat(k, v)
        end
    end
    if bonus.multiplier then for stat, value in pairs(base) do if type(value) == "number" then base[stat] = value * bonus.multiplier end end end
end

local rarityFallbackColors = { common = {1,1,1}, rare = {0.3,0.6,1}, epic = {0.8,0.4,1}, legendary = {1,0.8,0.1}, cursed = {0.65,0.15,0.15} }
local rarityPower = { common = 1.00, rare = 1.18, epic = 1.42, legendary = 1.75, cursed = 1.55 }

local function rollRarity(data)
    local luck = clamp(data.playerLuck or 0, -0.2, 1.5)
    local depth = data.depth or 1
    local roll = love.math.random()
    local legendary = 0.018 + luck * 0.025 + depth * 0.002
    local epic = legendary + 0.07 + luck * 0.06 + depth * 0.004
    local rare = epic + 0.20 + luck * 0.08
    if roll < legendary then return "legendary" end
    if roll < epic then return "epic" end
    if roll < rare then return "rare" end
    if love.math.random() < 0.045 + depth * 0.003 then return "cursed" end
    return "common"
end

local function statWeight(stat)
    local weights = { damage = 1.0, armor = 0.9, maxHealth = 0.22, attackSpeed = 11, critChance = 45, critMultiplier = 8, range = 3.5, luck = 6, speed = 0.08, dodge = 40 }
    return weights[stat] or 1
end
local function computePower(stats) local total = 0 for stat, value in pairs(stats or {}) do if type(value) == "number" then total = total + math.abs(normalizedStat(stat, value)) * statWeight(stat) end end return total end

local function inferBuildHint(stats, itemType)
    stats = stats or {}
    local score = {
        bruiser = (stats.damage or 0) * 1.2 + (stats.armor or 0) * 0.8 + (stats.maxHealth or 0) * 0.08,
        duelist = (stats.attackSpeed or 0) * 18 + (stats.critChance or 0) * 70 + (stats.dodge or 0) * 45,
        hunter = (stats.range or 0) * 6 + (stats.critMultiplier or 0) * 7 + (stats.speed or 0) * 0.10,
        scavenger = (stats.luck or 0) * 22 + (stats.speed or 0) * 0.06,
        guardian = (stats.armor or 0) * 1.4 + (stats.maxHealth or 0) * 0.10
    }
    local best, bestScore = "balanced", -999
    for k, v in pairs(score) do if v > bestScore then best, bestScore = k, v end end
    local names = {bruiser="силовой", duelist="дуэлянт", hunter="охотник", scavenger="искатель", guardian="страж", balanced="сбалансированный"}
    return names[best] or "сбалансированный"
end

local function postProcessItem(result, data, rarity)
    local itemLevel = math.max(1, math.floor(data.itemLevel or data.playerLevel or data.difficulty or 1))
    local levelScale = 1 + (itemLevel - 1) * 0.075
    local rScale = rarityPower[rarity] or 1
    local stats = cloneStats(result.baseStats)
    for stat, value in pairs(stats) do
        if type(value) == "number" then
            value = normalizedStat(stat, value)
            if stat == "damage" or stat == "armor" or stat == "maxHealth" then
                value = value * levelScale * rScale
            elseif stat == "speed" then
                value = value * (1 + (rScale - 1) * 0.4)
            elseif stat == "critChance" or stat == "dodge" or stat == "luck" or stat == "attackSpeed" or stat == "range" or stat == "critMultiplier" then
                value = value * (1 + (rScale - 1) * 0.55)
            end
            stats[stat] = value
        end
    end
    if result.type and result.type:find("weapon") then
        stats.damage = math.max(stats.damage or 0, 3 + itemLevel * 0.8) * rScale
    elseif result.type and result.type:find("armor") then
        stats.armor = math.max(stats.armor or 0, 1.5 + itemLevel * 0.45) * rScale
    elseif result.type == "potion" then
        result.healFraction = 0.38 + math.min(0.18, itemLevel * 0.01)
    end
    if stats.critChance then stats.critChance = clamp(stats.critChance, -0.25, 0.35) end
    if stats.dodge then stats.dodge = clamp(stats.dodge, -0.20, 0.25) end
    if stats.attackSpeed then stats.attackSpeed = clamp(stats.attackSpeed, -0.55, 0.9) end
    if stats.luck then stats.luck = clamp(stats.luck, -0.4, 0.7) end
    if stats.speed then stats.speed = clamp(stats.speed, -35, 55) end
    result.stats = stats; result.baseStats = stats; result.itemLevel = itemLevel; result.rarityKey = rarity; result.powerScore = computePower(stats)
    result.buildHint = inferBuildHint(stats, result.type)
    return result
end

local function generateSimpleItem(itemType, data)
    local item = pickRandom(LootTags.itemType[itemType]) or "предмет"
    local result = { name = item, type = itemType, baseStats = {}, tags = {}, displayName = item, stats = {}, rarityColor = {1,1,1} }
    return postProcessItem(result, data or {}, "common")
end

function LootGenerator.generateBasicItem(data)
    local simpleTypes = { "potion", "tool", "material", "junk" }
    return generateSimpleItem(pickRandom(simpleTypes) or "junk", data or {})
end

function LootGenerator.generateCombatItem(data)
    data = data or {}
    if data.playerStats and data.playerStats.lowHP and love.math.random() < 0.22 then return generateSimpleItem("potion", data) end
    local result = { name = "", type = nil, baseStats = {}, tags = {}, rarityColor = {1,1,1} }
    local isWeapon = love.math.random() < 0.52
    if isWeapon then
        local weaponType = love.math.random() < 0.62 and "melee" or "ranged"
        local weapon = pickRandom(LootTags.itemType.weapon[weaponType]) or "оружие"
        result.type = "weapon (" .. weaponType .. ")"; result.name = weapon; result.baseStats = cloneStats(lookup(LootTagEffects.itemType.weapon[weaponType], weapon) or {})
    else
        local armorSlot = pickRandom({ "head", "torso", "legs" }) or "torso"
        local armor = pickRandom(LootTags.itemType.armor[armorSlot]) or "броня"
        result.type = "armor (" .. armorSlot .. ")"; result.name = armor; result.baseStats = cloneStats(lookup(LootTagEffects.itemType.armor[armorSlot], armor) or {})
    end
    local itemLevel = math.max(1, math.floor(data.itemLevel or data.playerLevel or data.difficulty or 1))
    local totalTags = love.math.random(1, math.min(5, 1 + math.floor((data.playerLuck or 0) * 3) + math.floor(itemLevel / 4)))
    local function tryAddTag(field, tagType)
        if totalTags <= 0 or not data[field] then return end
        local tag = pickRandom((LootTags[tagType] and LootTags[tagType][data[field]]) or {})
        if tag then table.insert(result.tags, tag); mergeStats(result.baseStats, lookup(LootTagEffects[tagType], tag) or {}); totalTags = totalTags - 1 end
    end
    tryAddTag("enemyType", "enemyType"); tryAddTag("location", "location")
    local rarity = rollRarity(data)
    local rarityTag = pickRandom(LootTags.rarity[rarity]) or "обычный"
    table.insert(result.tags, rarityTag); mergeStats(result.baseStats, lookup(LootTagEffects.rarity, rarityTag) or {})
    result.rarityTag = rarityTag; result.rarityColor = lookup(LootTags.rarityColors or {}, rarityTag) or rarityFallbackColors[rarity] or {1,1,1}
    if result.name and #result.tags > 0 then result.displayName = string.format("[ %s ] %s ур.%d", table.concat(result.tags, " "), result.name, itemLevel) else result.displayName = result.name .. " ур." .. tostring(itemLevel) end
    return postProcessItem(result, data, rarity)
end

return LootGenerator
