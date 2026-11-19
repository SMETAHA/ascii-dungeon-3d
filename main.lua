-- Основные переменные и настройки ГЕНЕРИТЕ
local LootGenerator = require("LootGenerator")
local Balance = require("Balance")
local NoiseEngine = require("NoiseEngine")
local MusicEngine = require("MusicEngine")
local SFXGenerator = require("SFXGenerator")

-- ===== Core constants / small helpers =====
local TILE_SIZE = 30
local MAX_RAY_DISTANCE = 1000
local BG_BLOCK_SIZE = 6

if not math.atan2 then
    function math.atan2(y, x)
        if x > 0 then return math.atan(y / x) end
        if x < 0 and y >= 0 then return math.atan(y / x) + math.pi end
        if x < 0 and y < 0 then return math.atan(y / x) - math.pi end
        if x == 0 and y > 0 then return math.pi / 2 end
        if x == 0 and y < 0 then return -math.pi / 2 end
        return 0
    end
end

-- Audio handles must be declared before gameplay callbacks, because endRun() is defined early.
local sounds = {}
local music

local function clearArray(t)
    for i = #t, 1, -1 do
        t[i] = nil
    end
end

local function clamp(v, a, b)
    if v < a then return a end
    if v > b then return b end
    return v
end

local function smoothstep(edge0, edge1, x)
    if edge0 == edge1 then
        return x < edge0 and 0 or 1
    end
    local t = clamp((x - edge0) / (edge1 - edge0), 0, 1)
    return t * t * (3 - 2 * t)
end




-- ===== Gameplay math / balance helpers (v11) =====
function normalizedStatValue(stat, value)
    if type(value) ~= "number" then return 0 end
    if stat == "critChance" or stat == "dodge" then
        if math.abs(value) > 1 then return value / 100 end
        return value
    end
    if stat == "speed" then
        if value ~= 0 and math.abs(value) <= 1 then return value * 45 end
        return value
    end
    return value
end

function addStatValue(target, stat, value)
    if type(value) ~= "number" then return end
    target[stat] = (target[stat] or 0) + normalizedStatValue(stat, value)
end

function statLabel(stat)
    local names = {
        maxHealth = "HP", armor = "броня", damage = "урон", attackSpeed = "скор. атаки",
        range = "дальность", critChance = "крит", critMultiplier = "сила крита",
        luck = "удача", speed = "скорость", dodge = "уклонение"
    }
    return names[stat] or stat
end

function formatStatValue(stat, value)
    value = normalizedStatValue(stat, value)
    if stat == "critChance" or stat == "dodge" then
        return string.format("%+.0f%%", value * 100)
    elseif stat == "attackSpeed" or stat == "critMultiplier" or stat == "luck" or stat == "range" then
        return string.format("%+.2f", value)
    else
        return string.format("%+.0f", value)
    end
end

function getExpForLevel(level)
    level = math.max(1, level or 1)
    local cfg = Balance.leveling or {}
    return math.floor((cfg.baseXp or 80) + math.pow(level, cfg.power or 1.55) * (cfg.levelMul or 42))
end

function getDifficultyMultiplier()
    local playerLevel = Player and Player.level or 1
    local depth = currentDepth or 1
    local cfg = Balance.difficulty or {}
    return (cfg.base or 1) + (depth - 1) * (cfg.depthMul or 0.16) + (playerLevel - 1) * (cfg.levelMul or 0.09)
end

function armorReduction(armor)
    armor = math.max(0, armor or 0)
    return armor / (armor + 55)
end

function applyArmorReduction(rawDamage, armor)
    local reduction = armorReduction(armor)
    return math.max(1, rawDamage * (1 - reduction))
end

function rollDamage(attackerStats, defenderArmor, damageScale)
    attackerStats = attackerStats or {}
    local base = math.max(1, attackerStats.damage or 1) * (damageScale or 1)
    local variance = 0.88 + love.math.random() * 0.24
    local raw = base * variance
    local critChance = clamp(attackerStats.critChance or 0, 0, 0.85)
    local crit = love.math.random() < critChance
    if crit then raw = raw * math.max(1, attackerStats.critMultiplier or 1.5) end
    local final = applyArmorReduction(raw, defenderArmor or 0)
    return final, crit, raw
end

function getWeaponProfile()
    local weapon = Player and Player.equipped and Player.equipped.weapon
    local isRanged = weapon and weapon.type and weapon.type:find("ranged")
    local range = (Player.stats.range or 2.5) * TILE_SIZE
    local cfg = isRanged and Balance.weaponProfiles.ranged or Balance.weaponProfiles.melee
    return {
        kind = isRanged and "ranged" or "melee",
        range = range + (cfg.rangeBonus or 0),
        angle = math.rad(cfg.angleDeg or 45),
        maxTargets = cfg.maxTargets or 1,
        damageScale = cfg.damageScale or 1,
        cooldown = cfg.cooldown or (isRanged and 0.66 or 0.52),
        knockback = cfg.knockback or (isRanged and 70 or 135),
        hitStop = cfg.hitStop or (isRanged and 0.025 or 0.045),
        shake = cfg.shake or (isRanged and 2.2 or 3.6)
    }
end

function hasLineOfSightTo(tx, ty, maxDist)
    local angle = math.atan2(ty - Player.y, tx - Player.x)
    local wallDist = raycast(Player.x, Player.y, angle)
    return (wallDist or math.huge) + 4 >= (maxDist or 0)
end

function enemyDisplayName(enemy)
    if not enemy then return "враг" end
    local lvl = enemy.level and (" ур." .. tostring(enemy.level)) or ""
    return (enemy.name or enemy.type or "враг") .. lvl
end

function addInventoryItem(item, messagePrefix)
    if not item then return end
    table.insert(Player.inventory, item)
    recordItemFound(item, messagePrefix)
    if messagePrefix then
        inventoryMessage = messagePrefix .. (item.displayName or item.name or "предмет")
        inventoryMessageTimer = 3
    end
end

function resetRunStats()
    runStats = {
        startTime = love.timer.getTime(),
        endTime = nil,
        maxDepth = currentDepth or 1,
        depthsCleared = 0,
        enemiesKilled = 0,
        itemsFound = 0,
        chestsOpened = 0,
        altarsUsed = 0,
        damageDealt = 0,
        damageTaken = 0,
        bestHit = 0,
        bestItemName = "-",
        bestItemPower = 0,
        deathReason = ""
    }
end

function runElapsed()
    if not runStats then return 0 end
    local finish = runStats.endTime or love.timer.getTime()
    return math.max(0, finish - (runStats.startTime or finish))
end

function formatTime(seconds)
    seconds = math.floor(seconds or 0)
    return string.format("%02d:%02d", math.floor(seconds / 60), seconds % 60)
end

function recordItemFound(item, source)
    if not runStats or not item then return end
    runStats.itemsFound = (runStats.itemsFound or 0) + 1
    local pwr = item.powerScore or 0
    if pwr > (runStats.bestItemPower or 0) then
        runStats.bestItemPower = pwr
        runStats.bestItemName = item.displayName or item.name or "предмет"
    end
end

function recordDamageDealt(value)
    if not runStats then return end
    value = math.max(0, value or 0)
    runStats.damageDealt = (runStats.damageDealt or 0) + value
    runStats.bestHit = math.max(runStats.bestHit or 0, value)
end

function recordDamageTaken(value)
    if not runStats then return end
    runStats.damageTaken = (runStats.damageTaken or 0) + math.max(0, value or 0)
end

function loadHighScore()
    highScore = {depth = 1, kills = 0, level = 1, time = 0}
    if not love.filesystem.getInfo("records.cfg") then return end
    local data = love.filesystem.read("records.cfg") or ""
    for line in data:gmatch("[^\r\n]+") do
        local key, value = line:match("^([%w_]+)%s*=%s*([%d%.%-]+)$")
        if key and value then highScore[key] = tonumber(value) or highScore[key] end
    end
end

function saveHighScore()
    if not highScore then return end
    local out = {}
    for k, v in pairs(highScore) do
        if type(v) == "number" then table.insert(out, string.format("%s=%.3f", k, v)) end
    end
    love.filesystem.write("records.cfg", table.concat(out, "\n"))
end

function updateHighScore()
    highScore = highScore or {depth = 1, kills = 0, level = 1, time = 0}
    local betterDepth = (runStats.maxDepth or 1) > (highScore.depth or 1)
    local betterKills = (runStats.enemiesKilled or 0) > (highScore.kills or 0)
    local betterLevel = (Player.level or 1) > (highScore.level or 1)
    if betterDepth then highScore.depth = runStats.maxDepth or 1 end
    if betterKills then highScore.kills = runStats.enemiesKilled or 0 end
    if betterLevel then highScore.level = Player.level or 1 end
    highScore.time = math.max(highScore.time or 0, runElapsed())
    saveHighScore()
end

function endRun(reason)
    if isGameOver then return end
    isGameOver = true
    runStats = runStats or {}
    runStats.endTime = love.timer.getTime()
    runStats.deathReason = reason or "погиб"
    updateHighScore()
    love.mouse.setRelativeMode(false)
    if sounds and sounds.gameOver then sounds.gameOver:stop(); sounds.gameOver:play() end
end

function getEnemyStats(enemy)
    return {
        damage = enemy.strength or 1,
        critChance = enemy.critChance or 0,
        critMultiplier = enemy.critMultiplier or 1.35,
        attackSpeed = enemy.attackSpeed or 1,
        dodge = enemy.dodge or 0
    }
end

local function toCell(v)
    return math.floor(v / TILE_SIZE)
end

local function getPlayerCell()
    return toCell(Player.x), toCell(Player.y)
end

local canvas
Player = {
    x = 0,
    y = 0,
    angle = math.pi / 2,
    baseSpeed = 205,
    vx = 0,
    vy = 0,
    radius = 10,
    health = 100,
    level = 1,
    experience = 0,
    experienceToNextLevel = 100,
    inventory = {},
    equipped = {
        weapon = nil,
        armor = {
            head = nil,
            torso = nil,
            legs = nil
        }
    },
    stats = {
        maxHealth = 100,
        armor = 5,
        damage = 10,
        attackSpeed = 1.0,
        range = 2.5,
        critChance = 0.1,
        critMultiplier = 1.5,
        luck = 0.2,
        speed = 0,
        dodge = 0.03
    }
}
local selectedSetting = 1

local rooms = {}
local map = {}
local settings = {}
local FOV, numRays, miniMapScale, showMenu, mouseSensitivity
local rows, cols, maxRooms, roomMinSize, roomMaxSize
local windowWidth, windowHeight -- текущие размеры окна
local baseWidth, baseHeight = 1280, 720 -- базовое разрешение для расчетов
local scale -- общий масштаб
local offsetX, offsetY -- смещения для центрирования
local particles = {}
local enemies = {}
local items = {}
local wallDistances = {}
local visibleSprites = {}
local biomeMap = {}
local backgroundCanvases = {}
local biomeTypes = {"dungeon", "cave", "forest", "castle", "ruins"}
local walkableCells = {}
local spawnCell = nil
local exitCell = nil
local interactiveObjects = {}
local floatingTexts = {}
currentDepth = 1
runStats = {}
highScore = {}
currentSeed = nil
local inventoryFilterIndex = 1
local inventoryFilters = {"all", "weapon", "armor", "potion", "tool", "material", "junk"}
local fullMapVisible = false
local showDepthOverlay = false
local showSpriteOverlay = false
local objectInteractHint = ""
local lastInteractObject = nil
local footstepTimer = 0
local footstepInterval = 0.24
local attackBufferTimer = 0
local attackBufferWindow = 0.28
local attackHoldWindow = 0.16
local attackVisualTimer = 0
local hitStopTimer = 0
local screenShakeTimer = 0
local screenShakePower = 0
local playerMoveResponsiveness = 18
local playerFrictionResponsiveness = 20
local lastCombatEvent = ""
local enemiesKilledThisDepth = 0
local footstepSfx = {
    layers = {{
        waveform = {"triangle", "square"},
        frequency = {180, 320},
        duration = {0.045, 0.075},
        volume = {0.18, 0.28},
        effects = {bitcrush = 0.15}
    }}
}


function triggerHitStop(duration)
    hitStopTimer = math.max(hitStopTimer or 0, duration or 0.035)
end

function triggerScreenShake(power, duration)
    screenShakePower = math.max(screenShakePower or 0, power or 3)
    screenShakeTimer = math.max(screenShakeTimer or 0, duration or 0.12)
end

function approach(current, target, rate)
    return current + (target - current) * clamp(rate, 0, 1)
end

function applyKnockbackToEnemy(enemy, fromX, fromY, impulse)
    if not enemy then return end
    local dx = enemy.x - fromX
    local dy = enemy.y - fromY
    local dist = math.sqrt(dx * dx + dy * dy)
    if dist < 0.001 then
        dx, dy, dist = math.cos(Player.angle), math.sin(Player.angle), 1
    end
    local nx, ny = dx / dist, dy / dist
    enemy.vx = (enemy.vx or 0) + nx * (impulse or 120)
    enemy.vy = (enemy.vy or 0) + ny * (impulse or 120)
end

function applyKnockbackToPlayer(fromX, fromY, impulse)
    if not Player then return end
    local dx = Player.x - fromX
    local dy = Player.y - fromY
    local dist = math.sqrt(dx * dx + dy * dy)
    if dist < 0.001 then dx, dy, dist = -math.cos(Player.angle), -math.sin(Player.angle), 1 end
    local nx, ny = dx / dist, dy / dist
    Player.vx = (Player.vx or 0) + nx * (impulse or 150)
    Player.vy = (Player.vy or 0) + ny * (impulse or 150)
end

isGameOver = false
local maxRenderDistance = 300 -- Максимальная дистанция отображения спрайтов
local damageFlash = 0
local selectedMenuItem = 1
local flashTimer = 0
local flashInterval = 0.5
local flashVisible = true
gameDifficulty = 1.0 -- от 0.5 до 2.0, 1.0 — по умолчанию
local utf8 = require("utf8")
inventoryMessage = ""
inventoryMessageTimer = 0
isContextMenuOpen = false
local scrollTimers = {}
local previousSelectedIndex = 1

selectedContextOption = 1
local inventoryScroll = {
    offset = 0,
    speed = 30,
    activeIndex = nil,
    timer = 0
}


local scrollOffset = 0
local scrollSpeed = 30 -- пикселей в секунду

-- Символы и цвета
local particleSymbols = {".", "~", "*", "'", "`", "░", "▒", "▓"}

local floorColor = {100, 100, 100}
local ceilingColor = {50, 50, 100}
local ansiMenuOptions = {"Начать игру", "Настройки", "Выход"}
local ansiMenu = {
    {text = "╔══════════════════════════════╗", color = {255, 255, 0}},
    {text = "║                              ║", color = {255, 255, 0}},
    {text = "║      ASCII DUNGEON 3D        ║", color = {0, 255, 255}},
    {text = "║                              ║", color = {255, 255, 0}},
    {text = "║  ► Начать игру               ║", color = {0, 255, 0}},
    {text = "║  ► Настройки                 ║", color = {0, 255, 0}},
    {text = "║  ► Выход                     ║", color = {0, 255, 0}},
    {text = "╚══════════════════════════════╝", color = {255, 255, 0}}
}

local settingsMenu = {
    {key = "fov", name = "Поле зрения (FOV)", value = math.pi / 3, min = 0.1, max = math.pi / 2, step = 0.05, fmt = "%.2f"},
    {key = "speed", name = "Скорость игрока", value = 205, min = 80, max = 380, step = 10, fmt = "%.0f"},
    {key = "rays", name = "Количество лучей", value = 300, min = 80, max = 500, step = 10, fmt = "%.0f"},
    {key = "mouse", name = "Чувствительность мыши", value = 0.003, min = 0.0005, max = 0.008, step = 0.0005, fmt = "%.4f"},
    {key = "master", name = "Master volume", value = 0.9, min = 0, max = 1, step = 0.05, fmt = "%.2f"},
    {key = "music", name = "Music volume", value = 0.55, min = 0, max = 1, step = 0.05, fmt = "%.2f"},
    {key = "sfx", name = "SFX volume", value = 0.9, min = 0, max = 1, step = 0.05, fmt = "%.2f"}
}


local isInSettingsMenu = false


local isInventoryOpen = false
local selectedInventoryItem = 1


local biomeVisuals = {
    cave = {
        ceilingFunc = function(x, y, t)
            local brightness = 0.4 + 0.4 * NoiseEngine.fbm(x * 0.02, y * 0.02 + t, 4, 0.5)
            return {brightness * 0.1, brightness * 0.1, brightness * 0.2}
        end,
        floorFunc = function(x, y, t)
            local g = 0.5 + 0.4 * NoiseEngine.domainWarp(x * 0.05 + t, y * 0.05)
            return {g, g, g}
        end,
        objectSpawner = function(x, y, t)
            return NoiseEngine.ridged(x * 0.1, y * 0.1 + t) > 0.7
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
        end,
        objectSpawner = function(x, y, t)
            return NoiseEngine.masked(x, y + t) > 0.6
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
        end,
        objectSpawner = function(x, y, t)
            return NoiseEngine.domainWarp(x * 0.15, y * 0.15 + t) > 0.8
        end
    }
}




local wallTextures = {
    ['1'] = { color = {132, 164, 205} }, -- cold stone
    ['2'] = { color = {178, 82, 70} },   -- rust/brick
    ['3'] = { color = {92, 166, 105} },  -- moss/organic
    ['4'] = { color = {88, 176, 172} },  -- circuit/teal
    ['0'] = { color = {119, 119, 119} }
}

local enemyTypes = {
    skeleton = {
        locations = { "dungeon", "ruins" },
        health = 50,
        speed = 40,
        strength = 8,
        defense = 2,
        dropChance = 0.3
    },
    wizard = {
        locations = { "castle", "ruins" },
        health = 40,
        speed = 60,
        strength = 12,
        defense = 1,
        dropChance = 0.5
    },
    goblin = {
        locations = { "forest", "cave" },
        health = 30,
        speed = 80,
        strength = 6,
        defense = 1,
        dropChance = 0.2
    },
    slime = {
        locations = { "cave", "forest" },
        health = 25,
        speed = 30,
        strength = 4,
        defense = 0,
        dropChance = 0.1
    },
    beast = {
        locations = { "forest", "ruins" },
        health = 60,
        speed = 70,
        strength = 10,
        defense = 3,
        dropChance = 0.4
    },
    boss = {
        locations = { "castle" },
        health = 150,
        speed = 50,
        strength = 20,
        defense = 5,
        dropChance = 1.0
    }
}


local enemySprites = {
    skeleton = {
        height = 30,
        parts = {
            { offsetX = 0, offsetY = -22, shape = "circle", radius = 4.4, color = {215, 215, 205} }, -- череп
            { offsetX = -1.7, offsetY = -23, shape = "circle", radius = 0.75, color = {15, 15, 18} },
            { offsetX = 1.7, offsetY = -23, shape = "circle", radius = 0.75, color = {15, 15, 18} },
            { offsetX = 0, offsetY = -12, shape = "rectangle", width = 4.2, height = 11, color = {178, 178, 166} },
            { offsetX = -5.2, offsetY = -10, shape = "line", x2 = -8.5, y2 = -3, thickness = 1.4, color = {185, 185, 175} },
            { offsetX = 5.2, offsetY = -10, shape = "line", x2 = 8.5, y2 = -3, thickness = 1.4, color = {185, 185, 175} },
            { offsetX = -1.8, offsetY = -3, shape = "line", x2 = -4.8, y2 = 0, thickness = 1.3, color = {170, 170, 160} },
            { offsetX = 1.8, offsetY = -3, shape = "line", x2 = 4.8, y2 = 0, thickness = 1.3, color = {170, 170, 160} },
        }
    },
    wizard = {
        height = 34,
        parts = {
            { offsetX = 0, offsetY = -28, shape = "triangle", width = 12, height = 15, color = {95, 35, 180} }, -- капюшон
            { offsetX = 0, offsetY = -17, shape = "circle", radius = 3.2, color = {170, 130, 220} },
            { offsetX = 0, offsetY = -8, shape = "rectangle", width = 10, height = 18, color = {55, 20, 130} }, -- мантия
            { offsetX = 6.5, offsetY = -11, shape = "line", x2 = 10, y2 = 1, thickness = 1.1, color = {185, 130, 40} }, -- посох
            { offsetX = 10, offsetY = -1, shape = "circle", radius = 1.8, color = {90, 205, 255} },
        }
    },
    goblin = {
        height = 27,
        parts = {
            { offsetX = -5.8, offsetY = -18, shape = "triangle", width = 5, height = 6, color = {45, 170, 55} },
            { offsetX = 5.8, offsetY = -18, shape = "triangle", width = 5, height = 6, color = {45, 170, 55} },
            { offsetX = 0, offsetY = -18, shape = "circle", radius = 4.8, color = {20, 205, 60} }, -- башка
            { offsetX = -1.6, offsetY = -19, shape = "circle", radius = 0.65, color = {20, 20, 15} },
            { offsetX = 1.6, offsetY = -19, shape = "circle", radius = 0.65, color = {20, 20, 15} },
            { offsetX = 0, offsetY = -7, shape = "rectangle", width = 8.4, height = 13, color = {20, 135, 45} }, -- тело
            { offsetX = -4.2, offsetY = -2, shape = "line", x2 = -7, y2 = 0, thickness = 1.2, color = {20, 135, 45} },
            { offsetX = 4.2, offsetY = -2, shape = "line", x2 = 7, y2 = 0, thickness = 1.2, color = {20, 135, 45} },
        }
    },
    slime = {
        height = 18,
        parts = {
            { offsetX = 0, offsetY = -9, shape = "circle", radius = 7.4, color = {0, 235, 160} },
            { offsetX = -2.8, offsetY = -10.5, shape = "circle", radius = 0.9, color = {0, 40, 35} },
            { offsetX = 2.8, offsetY = -10.5, shape = "circle", radius = 0.9, color = {0, 40, 35} },
            { offsetX = 0, offsetY = -4.4, shape = "rectangle", width = 12.5, height = 3.2, color = {0, 190, 130} },
        }
    },
    beast = {
        height = 34,
        parts = {
            { offsetX = -4.5, offsetY = -27, shape = "triangle", width = 5, height = 8, color = {125, 70, 34} },
            { offsetX = 4.5, offsetY = -27, shape = "triangle", width = 5, height = 8, color = {125, 70, 34} },
            { offsetX = 0, offsetY = -22, shape = "circle", radius = 6.2, color = {150, 78, 35} }, -- морда
            { offsetX = 0, offsetY = -9, shape = "rectangle", width = 12, height = 18, color = {95, 58, 32} }, -- туловище
            { offsetX = -5, offsetY = -4, shape = "line", x2 = -8.5, y2 = 0, thickness = 1.5, color = {105, 67, 38} },
            { offsetX = 5, offsetY = -4, shape = "line", x2 = 8.5, y2 = 0, thickness = 1.5, color = {105, 67, 38} },
        }
    },
    boss = {
        height = 43,
        parts = {
            { offsetX = -6.5, offsetY = -37, shape = "triangle", width = 8, height = 12, color = {180, 20, 20} },
            { offsetX = 6.5, offsetY = -37, shape = "triangle", width = 8, height = 12, color = {180, 20, 20} },
            { offsetX = 0, offsetY = -30, shape = "circle", radius = 8.2, color = {245, 35, 35} }, -- голова
            { offsetX = 0, offsetY = -12, shape = "rectangle", width = 16, height = 24, color = {115, 0, 0} }, -- тело
            { offsetX = -9, offsetY = -13, shape = "line", x2 = -14, y2 = 0, thickness = 2, color = {135, 0, 0} },
            { offsetX = 9, offsetY = -13, shape = "line", x2 = 14, y2 = 0, thickness = 2, color = {135, 0, 0} },
        }
    }
}



local spriteTypes = {
    enemy = {

        color = {255, 0, 0},
        height = 100
    }
}



-- Звуки и музыка
-- sounds/music are declared near the top so every callback shares the same table.

-- Кэш для шрифтов
local fontFileName = "DejaVuSansMono.ttf"
local defaultFont
local uiFont
local titleFont
local uiLargeFont
local smallFont
local wallFont
local showDebugOverlay = false

-- Переменные для обработки ввода меню с задержкой (debounce)
local inputCooldown = 0.12
local lastInputTime = 0

-- Функция love.load() вызывается при запуске игры
function love.load()
    love.graphics.setDefaultFilter("nearest", "nearest")
    initGame()
end

-- Инициализация игры
function initGame()
    love.window.setTitle("ASCII Dungeon 3D")
    currentDepth = 1
    currentSeed = os.time() + love.math.random(1, 100000)
    love.math.setRandomSeed(currentSeed)
    loadHighScore()
    resetRunStats()
    interactiveObjects = {}
    floatingTexts = {}
    objectInteractHint = ""
    lastInteractObject = nil

    initSettings()
    initFonts()
    loadSounds()
    loadMusic()

    NoiseEngine.defineVisuals()
    NoiseEngine.precompute(baseWidth, baseHeight)

    map = generateDungeon()
    assignBiomesToMap()

    love.window.setMode(baseWidth, baseHeight, {resizable = true, minwidth = 400, minheight = 300, vsync = 1})
    resizeWindow(love.graphics.getWidth(), love.graphics.getHeight())
    initPlayer()
    buildBackgroundCanvases()

    love.mouse.setRelativeMode(false)
    spawnEnemies()
    spawnInteractiveObjects()

    -- На повторный init не копим старые слои из singleton-модуля.
    MusicEngine.layers = {}
    MusicEngine.percussion = {}
    MusicEngine.drones = {}
    MusicEngine.timer = 0

    MusicEngine:addLayer("biome_dungeon", {
        scale = {110, 146.83, 220},
        instrument = MusicEngine.instruments.fat_square,
        rhythm = {[1.0] = 0.6, [2.0] = 0.4},
        volume = 0.35,
        condition = function(ctx) return ctx.biome == "dungeon" and not ctx.showMenu and 1 or 0 end
    })

    MusicEngine:addLayer("biome_cave", {
        scale = {130.81, 174.61, 220.00},
        instrument = MusicEngine.instruments.noisy_crunch,
        rhythm = {[0.5] = 0.5, [1.0] = 0.5},
        volume = 0.3,
        condition = function(ctx) return ctx.biome == "cave" and not ctx.showMenu and 1 or 0 end
    })

    MusicEngine:addLayer("biome_forest", {
        scale = {261.63, 329.63, 392.00, 440.00},
        instrument = MusicEngine.instruments.ambient_triangle,
        rhythm = {[0.25] = 0.3, [0.5] = 0.5, [1.0] = 0.2},
        volume = 0.25,
        condition = function(ctx) return ctx.biome == "forest" and not ctx.showMenu and 1 or 0 end
    })

    MusicEngine:addLayer("biome_castle", {
        scale = {220.00, 293.66, 349.23},
        instrument = MusicEngine.instruments.bass_saw,
        rhythm = {[0.5] = 0.5, [1.0] = 0.5},
        volume = 0.4,
        condition = function(ctx) return ctx.biome == "castle" and not ctx.showMenu and 1 or 0 end
    })

    MusicEngine:addLayer("biome_ruins", {
        scale = {196, 261.63, 311.13},
        instrument = MusicEngine.instruments.basic_sine,
        rhythm = {[0.25] = 0.6, [0.5] = 0.4},
        volume = 0.3,
        condition = function(ctx) return ctx.biome == "ruins" and not ctx.showMenu and 1 or 0 end
    })
end

-- Инициализация параметров игры и генерация подземелий
function initSettings()
    rows, cols = 50, 50
    maxRooms, roomMinSize, roomMaxSize = 10, 5, 10
    miniMapScale = 10
    showMenu = true
    baseWidth, baseHeight = 1280, 720
    loadSettings()
    applySettings()
end

function getSettingValue(key, fallback)
    for _, setting in ipairs(settingsMenu) do
        if setting.key == key then return setting.value end
    end
    return fallback
end

function setSettingValue(key, value)
    for _, setting in ipairs(settingsMenu) do
        if setting.key == key then
            setting.value = clamp(value, setting.min, setting.max)
            return
        end
    end
end

function loadSettings()
    local info = love.filesystem.getInfo("settings.cfg")
    if not info then return end
    local data = love.filesystem.read("settings.cfg") or ""
    for line in data:gmatch("[^\r\n]+") do
        local key, value = line:match("^([%w_]+)%s*=%s*([%d%.%-]+)$")
        if key and value then
            setSettingValue(key, tonumber(value) or 0)
        end
    end
end

function saveSettings()
    local out = {}
    for _, setting in ipairs(settingsMenu) do
        table.insert(out, string.format("%s=%.6f", setting.key or setting.name, setting.value))
    end
    love.filesystem.write("settings.cfg", table.concat(out, "\n"))
end

function applySettings()
    FOV = getSettingValue("fov", math.pi / 3)
    numRays = math.max(20, math.floor(getSettingValue("rays", 300)))
    mouseSensitivity = getSettingValue("mouse", 0.003)
    if Player then
        Player.baseSpeed = getSettingValue("speed", 205)
    end
    local master = getSettingValue("master", 0.9)
    MusicEngine:setVolume(master, getSettingValue("music", 0.55))
    SFXGenerator:setVolume(master, getSettingValue("sfx", 0.9))
end

-- Инициализация игрока
function initPlayer()
    local c = spawnCell or randomWalkableCell(0)
    Player = createDefaultPlayer((c.x + 0.5) * TILE_SIZE, (c.y + 0.5) * TILE_SIZE)
    applySettings()
end



-- Инициализация канваса
function initCanvas()
    canvas = love.graphics.newCanvas(baseWidth, baseHeight)
end


local function biomeVisualPalette(biome)
    -- v13: не делаем фон главным героем кадра. Он должен давать глубину,
    -- но не спорить со стенами и спрайтами.
    local palettes = {
        dungeon = {ceiling={0.070,0.074,0.100}, floor={0.105,0.100,0.086}, accent={0.34,0.36,0.46}},
        cave    = {ceiling={0.052,0.060,0.074}, floor={0.096,0.088,0.074}, accent={0.32,0.33,0.34}},
        forest  = {ceiling={0.046,0.075,0.061}, floor={0.080,0.110,0.070}, accent={0.28,0.42,0.26}},
        castle  = {ceiling={0.088,0.076,0.054}, floor={0.120,0.104,0.078}, accent={0.50,0.42,0.20}},
        ruins   = {ceiling={0.066,0.072,0.098}, floor={0.108,0.102,0.086}, accent={0.38,0.37,0.31}},
    }
    return palettes[biome] or palettes.dungeon
end

local function drawReadableBackgroundLayer(kind, biome, w, h)
    local pal = biomeVisualPalette(biome)
    local base = kind == "ceiling" and pal.ceiling or pal.floor
    local accent = pal.accent

    -- Спокойный градиент: верх/низ различимы, но без шумовой стены на весь экран.
    for y = 0, h, 6 do
        local t = h > 0 and y / h or 0
        local factor
        if kind == "ceiling" then
            factor = 0.86 + t * 0.34
        else
            factor = 1.08 - t * 0.22
        end
        love.graphics.setColor(base[1] * factor, base[2] * factor, base[3] * factor, 1)
        love.graphics.rectangle("fill", 0, y, w, 6)
    end

    -- Редкая текстовая пыль фона. Намёк на материал, не каша.
    love.graphics.setFont(smallFont or defaultFont)
    local glyphs = kind == "ceiling" and {".", "'", "`"} or {".", ":", ","}
    local cellW, cellH = 34, 22
    for y = 0, h - cellH, cellH do
        for x = 0, w - cellW, cellW do
            local n = NoiseEngine.fbm(x * 0.010 + (kind == "floor" and 7.1 or 1.9), y * 0.013 + 3.4, 3, 0.50)
            local threshold = kind == "floor" and 0.67 or 0.72
            if n > threshold then
                local g = glyphs[(math.floor(n * 997) % #glyphs) + 1]
                local a = kind == "floor" and 0.10 or 0.075
                local shade = 0.75 + n * 0.35
                love.graphics.setColor(accent[1] * shade, accent[2] * shade, accent[3] * shade, a)
                love.graphics.print(g, x + (n * 13) % 9, y + (n * 17) % 7)
            end
        end
    end
    love.graphics.setFont(defaultFont)
end

function buildBackgroundCanvases()
    backgroundCanvases = {}
    for _, biome in ipairs(biomeTypes) do
        backgroundCanvases[biome] = {
            ceiling = love.graphics.newCanvas(baseWidth, baseHeight / 2),
            floor = love.graphics.newCanvas(baseWidth, baseHeight / 2)
        }

        love.graphics.setCanvas(backgroundCanvases[biome].ceiling)
        love.graphics.clear()
        drawReadableBackgroundLayer("ceiling", biome, baseWidth, baseHeight / 2)

        love.graphics.setCanvas(backgroundCanvases[biome].floor)
        love.graphics.clear()
        drawReadableBackgroundLayer("floor", biome, baseWidth, baseHeight / 2)
    end
    love.graphics.setCanvas()
end

-- Инициализация шрифтов
local function makeFont(size)
    if love.filesystem.getInfo(fontFileName) then
        return love.graphics.newFont(fontFileName, size)
    end
    return love.graphics.newFont(size)
end

function initFonts()
    defaultFont = makeFont(12)
    uiFont = makeFont(15)
    titleFont = makeFont(24)
    uiLargeFont = makeFont(19)
    smallFont = makeFont(10)
    wallFont = makeFont(13)
    love.graphics.setFont(defaultFont)
end


-- Функция для изменения размеров окна и пересчета масштаба
function resizeWindow(newWidth, newHeight)
    windowWidth = newWidth
    windowHeight = newHeight

    local scaleX = windowWidth / baseWidth
    local scaleY = windowHeight / baseHeight
    scale = math.min(scaleX, scaleY)

    offsetX = (windowWidth - baseWidth * scale) / 2
    offsetY = (windowHeight - baseHeight * scale) / 2

    if canvas then
        canvas:release()
    end
    canvas = love.graphics.newCanvas(baseWidth, baseHeight)
end


-- Обрабатываем событие изменения размеров окна
function love.resize(newWidth, newHeight)
    resizeWindow(newWidth, newHeight)
end
---------------------------------------------------------------------------------------
local biomeCenters = {}
-- biomeTypes объявлен выше как local; не переобъявляем здесь

function generateBiomeCenters(num)
    biomeCenters = {}
    for i = 1, num do
        table.insert(biomeCenters, {
            x = love.math.random(1, cols),
            y = love.math.random(1, rows),
            type = biomeTypes[love.math.random(1, #biomeTypes)]
        })
    end
end

function getBiomeForCell(x, y)
    local closest, minDist = nil, math.huge
    for _, center in ipairs(biomeCenters) do
        local dx = x - center.x
        local dy = y - center.y
        local dist = dx * dx + dy * dy
        if dist < minDist then
            closest = center
            minDist = dist
        end
    end
    return closest and closest.type or "dungeon"
end

function biomeToWallType(biome)
    local lookup = {
        dungeon = '1',
        cave = '2',
        forest = '3',
        castle = '4',
        ruins = '2' -- можешь потом сделать отдельный тип, я не твоя мама
    }
    return lookup[biome] or '1'
end


function isWalkableCell(x, y)
    return map and map[y] and map[y][x] == '0'
end

local function collectRegion(srcMap, sx, sy, visited)
    local queue = {{x = sx, y = sy}}
    local region = {}
    visited[sy] = visited[sy] or {}
    visited[sy][sx] = true

    local head = 1
    while head <= #queue do
        local c = queue[head]
        head = head + 1
        table.insert(region, c)

        local dirs = {{1,0}, {-1,0}, {0,1}, {0,-1}}
        for _, d in ipairs(dirs) do
            local nx, ny = c.x + d[1], c.y + d[2]
            if srcMap[ny] and srcMap[ny][nx] == '0' and not (visited[ny] and visited[ny][nx]) then
                visited[ny] = visited[ny] or {}
                visited[ny][nx] = true
                table.insert(queue, {x = nx, y = ny})
            end
        end
    end

    return region
end

function normalizeDungeonConnectivity(srcMap)
    local visited = {}
    local best = {}

    for y = 2, rows - 1 do
        for x = 2, cols - 1 do
            if srcMap[y][x] == '0' and not (visited[y] and visited[y][x]) then
                local region = collectRegion(srcMap, x, y, visited)
                if #region > #best then best = region end
            end
        end
    end

    -- Если шум дал слишком закрытый уровень, вырезаем простую центральную область.
    if #best < 80 then
        for y = 2, rows - 1 do
            for x = 2, cols - 1 do
                local dx, dy = x - cols / 2, y - rows / 2
                if dx * dx + dy * dy < 160 then srcMap[y][x] = '0' end
            end
        end
        visited, best = {}, {}
        for y = 2, rows - 1 do
            for x = 2, cols - 1 do
                if srcMap[y][x] == '0' and not (visited[y] and visited[y][x]) then
                    local region = collectRegion(srcMap, x, y, visited)
                    if #region > #best then best = region end
                end
            end
        end
    end

    local keep = {}
    for _, c in ipairs(best) do
        keep[c.y] = keep[c.y] or {}
        keep[c.y][c.x] = true
    end

    for y = 1, rows do
        for x = 1, cols do
            if y == 1 or x == 1 or y == rows or x == cols then
                srcMap[y][x] = biomeToWallType(getBiomeForCell(x, y))
            elseif srcMap[y][x] == '0' and not (keep[y] and keep[y][x]) then
                srcMap[y][x] = biomeToWallType(getBiomeForCell(x, y))
            end
        end
    end

    walkableCells = best
    if #walkableCells > 0 then
        spawnCell = walkableCells[love.math.random(1, #walkableCells)]
        local far, farD = spawnCell, -1
        for _, c in ipairs(walkableCells) do
            local dx, dy = c.x - spawnCell.x, c.y - spawnCell.y
            local d = dx * dx + dy * dy
            if d > farD then
                farD = d
                far = c
            end
        end
        exitCell = far
    else
        spawnCell = {x = 2, y = 2}
        exitCell = {x = cols - 2, y = rows - 2}
        srcMap[spawnCell.y][spawnCell.x] = '0'
        srcMap[exitCell.y][exitCell.x] = '0'
        walkableCells = {spawnCell, exitCell}
    end
end

function randomWalkableCell(minDistFromPlayer)
    if #walkableCells == 0 then return {x = 2, y = 2} end
    minDistFromPlayer = minDistFromPlayer or 0
    for _ = 1, 60 do
        local c = walkableCells[love.math.random(1, #walkableCells)]
        if not Player or minDistFromPlayer <= 0 then return c end
        local wx, wy = (c.x + 0.5) * TILE_SIZE, (c.y + 0.5) * TILE_SIZE
        local dx, dy = wx - Player.x, wy - Player.y
        if dx * dx + dy * dy >= minDistFromPlayer * minDistFromPlayer then
            return c
        end
    end
    return walkableCells[love.math.random(1, #walkableCells)]
end

function generateDungeon()
    generateBiomeCenters(10)
    local map = generateEmptyMap(rows, cols)

    for y = 1, rows do
        for x = 1, cols do
            local biome = getBiomeForCell(x, y)
            local n = love.math.noise(x * 0.1 + currentDepth * 0.07, y * 0.1 - currentDepth * 0.05)
            if n > 0.52 then
                map[y][x] = '0'
            else
                map[y][x] = biomeToWallType(biome)
            end
        end
    end

    normalizeDungeonConnectivity(map)
    return map
end

function assignBiomesToMap()
    biomeMap = {}
    local scale = 0.08 -- чем меньше, тем крупнее области одного биома

    for y = 1, rows do
        biomeMap[y] = {}
        for x = 1, cols do
            if map[y][x] == '0' then
                local n = love.math.noise(x * scale, y * scale)

                if n < 0.2 then
                    biomeMap[y][x] = "cave"
                elseif n < 0.4 then
                    biomeMap[y][x] = "forest"
                elseif n < 0.6 then
                    biomeMap[y][x] = "castle"
                elseif n < 0.8 then
                    biomeMap[y][x] = "ruins"
                else
                    biomeMap[y][x] = "dungeon"
                end
            end
        end
    end
end


---------------------------------------------------------------------------------------

function generateEmptyMap(rows, cols)
    local map = {}
    for i = 1, rows do
        map[i] = {}
        for j = 1, cols do
            map[i][j] = '1'
        end
    end
    return map
end

function generateRoom(map)
    local w = love.math.random(roomMinSize, roomMaxSize)
    local h = love.math.random(roomMinSize, roomMaxSize)
    local x = love.math.random(2, cols - w - 1)
    local y = love.math.random(2, rows - h - 1)

    local newRoom = {x = x, y = y, w = w, h = h}
    for _, otherRoom in ipairs(rooms) do
        if roomsOverlap(newRoom, otherRoom) then
            return nil
        end
    end

    createRoom(map, x, y, w, h)
    return newRoom
end

function roomsOverlap(room1, room2)
    return (room1.x < room2.x + room2.w and room1.x + room1.w > room2.x and
            room1.y < room2.y + room2.h and room1.y + room1.h > room2.y)
end

function createRoom(map, x, y, w, h)
    local wallSymbols = {'1', '2', '3', '4'}
    local wallType = wallSymbols[love.math.random(1, #wallSymbols)]

    for i = y, y + h - 1 do
        for j = x, x + w - 1 do
            map[i][j] = '0'
        end
    end

    for i = y - 1, y + h do
        for j = x - 1, x + w do
            if i == y - 1 or i == y + h or j == x - 1 or j == x + w then
                if map[i] and map[i][j] then
                    map[i][j] = wallType
                end
            end
        end
    end
end


function connectRooms(map, newRoom)
    if #rooms == 0 then return end
    local prevRoom = rooms[#rooms]
    local prevCenter = getRoomCenter(prevRoom)
    local newCenter = getRoomCenter(newRoom)

    if love.math.random(0, 1) == 1 then
        createHorizontalCorridor(map, prevCenter.x, newCenter.x, prevCenter.y)
        createVerticalCorridor(map, prevCenter.y, newCenter.y, newCenter.x)
    else
        createVerticalCorridor(map, prevCenter.y, newCenter.y, prevCenter.x)
        createHorizontalCorridor(map, prevCenter.x, newCenter.x, newCenter.y)
    end
end

function getRoomCenter(room)
    return {x = math.floor(room.x + room.w / 2), y = math.floor(room.y + room.h / 2)}
end

function createHorizontalCorridor(map, x1, x2, y)
    for x = math.min(x1, x2), math.max(x1, x2) do
        if map[y] and map[y][x] then
            map[y][x] = '0'
        end
    end
end

function createVerticalCorridor(map, y1, y2, x)
    for y = math.min(y1, y2), math.max(y1, y2) do
        if map[y] and map[y][x] then
            map[y][x] = '0'
        end
    end
end


-- Обработка ввода и обновление игры
function love.update(dt)
dt = math.min(dt, 0.05)
local rawDt = dt
screenShakeTimer = math.max(0, (screenShakeTimer or 0) - rawDt)
if screenShakeTimer <= 0 then screenShakePower = 0 end
local bx, by = getPlayerCell()
local currentBiome = getBiomeForCell(bx, by)
MusicEngine:updateContext({
  showMenu = showMenu,
  isGameOver = isGameOver,
  isInventoryOpen = isInventoryOpen,
  biome = currentBiome
})
MusicEngine:update(dt)
SFXGenerator:cleanupSources()
footstepTimer = math.max(0, footstepTimer - dt)
updateFloatingTexts(dt)
damageFlash = math.max(0, damageFlash - dt * 2.5)
attackVisualTimer = math.max(0, (attackVisualTimer or 0) - dt * 4.5)
attackBufferTimer = math.max(0, (attackBufferTimer or 0) - dt)
if inventoryMessageTimer > 0 then
    inventoryMessageTimer = inventoryMessageTimer - dt
    if inventoryMessageTimer <= 0 then
        inventoryMessage = ""
    end
end


if isInventoryOpen then
    if selectedInventoryItem ~= inventoryScroll.activeIndex then
        inventoryScroll.activeIndex = selectedInventoryItem
        inventoryScroll.offset = 0
        inventoryScroll.timer = 0
    else
        inventoryScroll.timer = inventoryScroll.timer + dt
        inventoryScroll.offset = inventoryScroll.offset + inventoryScroll.speed * dt
    end
end

    local worldDt = dt
    if (hitStopTimer or 0) > 0 then
        hitStopTimer = math.max(0, hitStopTimer - rawDt)
        worldDt = dt * 0.12
    end

	
	flashTimer = flashTimer + dt
if flashTimer > flashInterval then
    flashVisible = not flashVisible
    flashTimer = 0
end


    if isGameOver then
        return
    end

    if isInventoryOpen then
    handleInventoryInput(dt)
elseif isInSettingsMenu then
    handleSettingsInput(dt)
elseif showMenu then
        handleMenuInput(dt)
    else
        handleGameInput(worldDt)
		pushBackFromEnemy()
        updateEnemies(worldDt)
        updateParticles(worldDt)
        local nearObj = getNearestInteractiveObject()
        lastInteractObject = nearObj
        objectInteractHint = nearObj and ("E - " .. (nearObj.kind == "chest" and "открыть сундук" or nearObj.kind == "altar" and "использовать алтарь" or nearObj.kind == "exit" and "следующая глубина" or "взаимодействовать")) or ""
    end
end

function handleInventoryInput(dt)
    lastInputTime = lastInputTime - dt
    if lastInputTime > 0 then return end

    -- Взаимодействие с контекстным меню
    if isContextMenuOpen then
        if love.keyboard.isDown('up') then
            selectedContextOption = selectedContextOption - 1
            if selectedContextOption < 1 then selectedContextOption = #contextMenuOptions end
            lastInputTime = inputCooldown

        elseif love.keyboard.isDown('down') then
            selectedContextOption = selectedContextOption + 1
            if selectedContextOption > #contextMenuOptions then selectedContextOption = 1 end
            lastInputTime = inputCooldown

        elseif love.keyboard.isDown('return') then
            local action = contextMenuOptions[selectedContextOption]
            if action == "Отмена" then
                isContextMenuOpen = false
            else
                local actualIndex = selectedInventoryActualIndex()
                local item = actualIndex and Player.inventory[actualIndex]
                if item then
                    performInventoryAction(action, item, actualIndex)
                end
                isContextMenuOpen = false
            end
            lastInputTime = inputCooldown
        end

        return -- только меню, выходим
    end

    -- Навигация по инвентарю
    if love.keyboard.isDown('up') then
        selectedInventoryItem = math.max(1, selectedInventoryItem - 1)
        lastInputTime = inputCooldown

    elseif love.keyboard.isDown('down') then
        selectedInventoryItem = math.max(1, math.min(visibleInventoryCount(), selectedInventoryItem + 1))
        lastInputTime = inputCooldown

    elseif love.keyboard.isDown('return') then
    isContextMenuOpen = true
    selectedContextOption = 1

    local actualIndex = selectedInventoryActualIndex()
    local item = actualIndex and Player.inventory[actualIndex]
    contextMenuOptions = { "Отмена" }

    if item then
        local itemType = item.type or ""

        if itemType:find("weapon") or itemType:find("armor") then
            table.insert(contextMenuOptions, 1, "Одеть")
            table.insert(contextMenuOptions, 2, "Выбросить")
        elseif itemType:find("potion") then
            table.insert(contextMenuOptions, 1, "Применить")
            table.insert(contextMenuOptions, 2, "Выбросить")
        elseif itemType == "tool" or itemType == "material" or itemType == "junk" then
            table.insert(contextMenuOptions, 1, "Выбросить")
        end
    end

    lastInputTime = inputCooldown
end

    end







-- Обработка ввода в игровом режиме
function handleGameInput(dt)
    Player.vx = Player.vx or 0
    Player.vy = Player.vy or 0

    local speed = (Player.baseSpeed + (Player.stats.speed or 0))
    local inputX, inputY = 0, 0

    if love.keyboard.isDown('w') then
        inputX = inputX + math.cos(Player.angle)
        inputY = inputY + math.sin(Player.angle)
    end
    if love.keyboard.isDown('s') then
        inputX = inputX - math.cos(Player.angle)
        inputY = inputY - math.sin(Player.angle)
    end
    if love.keyboard.isDown('a') then
        inputX = inputX + math.cos(Player.angle - math.pi / 2)
        inputY = inputY + math.sin(Player.angle - math.pi / 2)
    end
    if love.keyboard.isDown('d') then
        inputX = inputX + math.cos(Player.angle + math.pi / 2)
        inputY = inputY + math.sin(Player.angle + math.pi / 2)
    end

    local moving = (inputX * inputX + inputY * inputY) > 0
    local targetVX, targetVY = 0, 0
    if moving then
        local len = math.sqrt(inputX * inputX + inputY * inputY)
        inputX, inputY = inputX / len, inputY / len
        targetVX = inputX * speed
        targetVY = inputY * speed
    end

    local response = moving and playerMoveResponsiveness or playerFrictionResponsiveness
    Player.vx = approach(Player.vx, targetVX, dt * response)
    Player.vy = approach(Player.vy, targetVY, dt * response)

    local moved = math.abs(Player.vx) + math.abs(Player.vy) > 0.25
    if moved then
        movePlayer(Player.vx * dt, Player.vy * dt)
        if footstepTimer <= 0 and moving then
            SFXGenerator:generate(footstepSfx)
            footstepTimer = clamp(0.30 - speed / 1600, 0.14, 0.26)
        end
    end

    -- v19: атака должна ощущаться мгновенной: длиннее буфер, удержание Space/ЛКМ,
    -- плюс кулдаун теперь короче и зависит от профиля оружия.
    if love.keyboard.isDown('space') or love.mouse.isDown(1) then
        attackBufferTimer = math.max(attackBufferTimer or 0, attackHoldWindow)
    end
    if (attackBufferTimer or 0) > 0 then
        if handleAttack() then
            attackBufferTimer = 0
        end
    end
end

-- Обработка движения мыши
function love.mousemoved(x, y, dx, dy)
    if not showMenu and not isGameOver and not isInventoryOpen and not isInSettingsMenu then
        Player.angle = Player.angle + dx * mouseSensitivity
    end
end

function love.mousepressed(x, y, button)
    if button == 1 and not showMenu and not isGameOver and not isInventoryOpen and not isInSettingsMenu then
        attackBufferTimer = attackBufferWindow
    elseif button == 2 and not showMenu and not isGameOver and not isInventoryOpen and not isInSettingsMenu then
        handleInteractOrWall()
    end
end

-- Обработка нажатия клавиш
function love.keypressed(key)
    if key == 'f3' then
        showDebugOverlay = not showDebugOverlay
        return
    elseif key == 'f4' then
        fullMapVisible = not fullMapVisible
        return
    elseif key == 'f5' then
        restartCurrentRun()
        return
    elseif key == 'f6' then
        showDepthOverlay = not showDepthOverlay
        return
    elseif key == 'f7' then
        showSpriteOverlay = not showSpriteOverlay
        return
    elseif key == 'f11' then
        local fullscreen = love.window.getFullscreen()
        love.window.setFullscreen(not fullscreen, 'desktop')
        return
    elseif isGameOver and key == 'r' then
        restartCurrentRun()
        return
    elseif isGameOver and key == 'escape' then
        showMenu = true
        isGameOver = false
        love.mouse.setRelativeMode(false)
        return
    end

if key == 'space' and not isInventoryOpen and not showMenu and not isInSettingsMenu and not isGameOver then
        attackBufferTimer = attackBufferWindow
        return
    end

    if isInventoryOpen then
        if not isContextMenuOpen then
            if key == 'tab' then
                inventoryFilterIndex = inventoryFilterIndex % #inventoryFilters + 1
                selectedInventoryItem = 1
                return
            elseif key == 's' then
                sortInventory()
                selectedInventoryItem = 1
                return
            elseif key == 'x' then
                dropJunkItems()
                return
            end
        end
        if isContextMenuOpen then
            if key == 'escape' then
                isContextMenuOpen = false -- только закрываем контекстное меню
                return
            end
        elseif key == 'i' or key == 'escape' then
            isInventoryOpen = false
            love.mouse.setRelativeMode(true)
            return
        end
    end
	
    if key == 'e' and not showMenu and not isInSettingsMenu and not isInventoryOpen and not isGameOver then
        handleInteractOrWall()
        return
    end

	if key == "l" then  -- нажатие L генерирует предмет
        generateTestItemToInventory()
    end

    if key == 'i' then
        if not showMenu and not isInSettingsMenu then
            isInventoryOpen = not isInventoryOpen
            love.mouse.setRelativeMode(not isInventoryOpen)
        end
    elseif key == 'escape' then
        if showMenu then
            love.event.quit()
        elseif isInSettingsMenu then
            isInSettingsMenu = false
            showMenu = true
            love.mouse.setRelativeMode(false)
        else
            showMenu = true
            love.mouse.setRelativeMode(false)
        end
    end
end

-- Перемещение игрока с проверкой коллизий
function movePlayer(dx, dy)
    local radius = Player.radius or 10
    local oldX, oldY = Player.x, Player.y
    Player.x, Player.y = moveWithCollision(Player.x, Player.y, dx, dy, radius)
    if math.abs(Player.x - oldX) < math.abs(dx) * 0.35 then Player.vx = (Player.vx or 0) * 0.25 end
    if math.abs(Player.y - oldY) < math.abs(dy) * 0.35 then Player.vy = (Player.vy or 0) * 0.25 end
end




-- Обработка ввода в меню с использованием debounce
function handleMenuInput(dt)
    lastInputTime = lastInputTime - dt
    if lastInputTime > 0 then return end

    if love.keyboard.isDown('up') then
        selectedMenuItem = math.max(1, selectedMenuItem - 1)
        lastInputTime = inputCooldown
    elseif love.keyboard.isDown('down') then
        selectedMenuItem = math.min(#ansiMenuOptions, selectedMenuItem + 1)
        lastInputTime = inputCooldown
    elseif love.keyboard.isDown('return') then
        handleMenuSelection(selectedMenuItem)
        lastInputTime = inputCooldown
    end
end

function handleMenuSelection(index)
    if index == 1 then
        showMenu = false
        love.mouse.setRelativeMode(true)
    elseif index == 2 then
        isInSettingsMenu = true
        showMenu = false
        love.mouse.setRelativeMode(false)
    elseif index == 3 then
        love.event.quit()
    end
end

function handleSettingsInput(dt)
    lastInputTime = lastInputTime - dt
    if lastInputTime > 0 then return end

    if love.keyboard.isDown('up') then
        selectedSetting = math.max(1, selectedSetting - 1)
        lastInputTime = inputCooldown
    elseif love.keyboard.isDown('down') then
        selectedSetting = math.min(#settingsMenu, selectedSetting + 1)
        lastInputTime = inputCooldown
    elseif love.keyboard.isDown('left') then
        adjustSettingValue(-1)
        lastInputTime = inputCooldown
    elseif love.keyboard.isDown('right') then
        adjustSettingValue(1)
        lastInputTime = inputCooldown
    elseif love.keyboard.isDown('escape') then
        isInSettingsMenu = false
        showMenu = true
        love.mouse.setRelativeMode(false)
    end
end

function adjustSettingValue(direction)
    local setting = settingsMenu[selectedSetting]
    setting.value = clamp(setting.value + setting.step * direction, setting.min, setting.max)
    applySettings()
    saveSettings()
end


-- Рендеринг и отрисовка
function love.draw()
    love.graphics.setCanvas(canvas)
    love.graphics.clear()
    love.graphics.push()
    --love.graphics.translate(offsetX, offsetY)
    --love.graphics.scale(scale, scale)

    
if isInSettingsMenu then
    drawSettingsMenu()
elseif showMenu then
        drawMenu()
    elseif isGameOver then
        drawGameOver()
    else
        castRays()
        collectVisibleSprites()
        renderScene()
        drawMiniMap()
        drawHUD()
        drawCrosshair()
        if showDebugOverlay then
            drawDebugOverlay()
        end
    end

     love.graphics.pop()
    love.graphics.setCanvas()

    -- Теперь рисуем канвас на экран
    love.graphics.setColor(1, 1, 1)
    local shakeX, shakeY = 0, 0
    if (screenShakeTimer or 0) > 0 and (screenShakePower or 0) > 0 then
        local p = screenShakePower * (screenShakeTimer / 0.16)
        shakeX = love.math.random(-100, 100) / 100 * p * scale
        shakeY = love.math.random(-100, 100) / 100 * p * scale
    end
    love.graphics.draw(canvas, offsetX + shakeX, offsetY + shakeY, 0, scale, scale)

    if damageFlash and damageFlash > 0 then
        love.graphics.setColor(1, 0, 0, damageFlash * 0.28)
        love.graphics.rectangle("fill", offsetX, offsetY, baseWidth * scale, baseHeight * scale)
    end


    -- 🎯 РИСУЕМ МЕНЮ ИНВЕНТАРЯ поверх ВСЕГО
    if isInventoryOpen then
        love.graphics.push()
    love.graphics.translate(offsetX, offsetY)
    love.graphics.scale(scale)
    drawInventoryMenu()
    love.graphics.pop()
    end
	
if inventoryMessage ~= "" then
    love.graphics.push()
    love.graphics.translate(offsetX, offsetY)
    love.graphics.scale(scale)
    drawToastMessage()
    love.graphics.pop()
end


end


-- ===== ANSI/ASCII UI layer (v16) =====
local UI = {
    bg0 = {0.025, 0.028, 0.040},
    bg1 = {0.055, 0.060, 0.085},
    panel = {0.045, 0.050, 0.070},
    panel2 = {0.065, 0.072, 0.100},
    glass = {0.020, 0.024, 0.036},
    stroke = {0.240, 0.290, 0.360},
    strokeSoft = {0.140, 0.170, 0.220},
    text = {0.900, 0.930, 0.980},
    muted = {0.560, 0.610, 0.700},
    faint = {0.350, 0.390, 0.470},
    accent = {0.350, 0.780, 1.000},
    accent2 = {0.760, 0.430, 1.000},
    good = {0.280, 0.950, 0.560},
    bad = {1.000, 0.300, 0.300},
    warn = {1.000, 0.800, 0.250},
    dark = {0.000, 0.000, 0.000}
}

local function uiColor(c, a)
    if not c then love.graphics.setColor(1, 1, 1, a or 1); return end
    love.graphics.setColor(c[1] or 1, c[2] or 1, c[3] or 1, a or c[4] or 1)
end

local function uiFontOf(font)
    return font or uiFont or defaultFont
end

local function uiCell(font)
    font = uiFontOf(font)
    return math.max(4, font:getWidth("M")), math.max(8, font:getHeight())
end

local function textLen(s)
    s = tostring(s or "")
    return (utf8 and utf8.len and utf8.len(s)) or #s
end

local function fitAsciiText(s, maxChars)
    s = tostring(s or "")
    maxChars = math.max(0, maxChars or #s)
    if textLen(s) <= maxChars then return s end
    local out = ""
    local count = 0
    for _, code in utf8.codes(s) do
        if count >= math.max(0, maxChars - 1) then break end
        out = out .. utf8.char(code)
        count = count + 1
    end
    return out .. "…"
end

local function uiPrintRaw(text, x, y, color, font, alpha)
    love.graphics.setFont(uiFontOf(font))
    uiColor(color or UI.text, alpha)
    love.graphics.print(text or "", math.floor(x), math.floor(y))
end

local function uiText(text, x, y, color, font, alpha)
    uiPrintRaw(text, x, y, color or UI.text, font or uiFont or defaultFont, alpha)
end

local function uiPrintf(text, x, y, w, align, color, font, alpha)
    love.graphics.setFont(uiFontOf(font))
    uiColor(color or UI.text, alpha)
    love.graphics.printf(text or "", math.floor(x), math.floor(y), w, align or "left")
end

local function asciiFill(x, y, w, h, color, alpha, glyph, font)
    font = uiFontOf(font or smallFont or defaultFont)
    local cw, ch = uiCell(font)
    local cols = math.max(1, math.floor(w / cw))
    local rows = math.max(1, math.floor(h / ch))
    glyph = glyph or "░"
    local line = string.rep(glyph, cols)
    love.graphics.setFont(font)
    uiColor(color or UI.panel, alpha or 0.25)
    for r = 0, rows - 1 do
        love.graphics.print(line, math.floor(x), math.floor(y + r * ch))
    end
end

local function asciiHLine(x, y, w, color, alpha, glyph, font)
    font = uiFontOf(font or smallFont or defaultFont)
    local cw = math.max(4, font:getWidth("M"))
    local cols = math.max(1, math.floor(w / cw))
    love.graphics.setFont(font)
    uiColor(color or UI.stroke, alpha or 1)
    love.graphics.print(string.rep(glyph or "─", cols), math.floor(x), math.floor(y))
end

local function asciiVLine(x, y, h, color, alpha, glyph, font)
    font = uiFontOf(font or smallFont or defaultFont)
    local _, ch = uiCell(font)
    local rows = math.max(1, math.floor(h / ch))
    love.graphics.setFont(font)
    uiColor(color or UI.stroke, alpha or 1)
    for r = 0, rows - 1 do
        love.graphics.print(glyph or "│", math.floor(x), math.floor(y + r * ch))
    end
end

local function asciiBoxInternal(x, y, w, h, title, accent, font, shaded)
    font = uiFontOf(font or smallFont or defaultFont)
    local cw, ch = uiCell(font)
    x, y = math.floor(x), math.floor(y)
    local cols = math.max(6, math.floor(w / cw))
    local rows = math.max(3, math.floor(h / ch))
    local inner = cols - 2
    love.graphics.setFont(font)

    if shaded then
        local shade = string.rep("░", inner)
        uiColor(UI.dark, 0.13)
        for r = 1, rows - 2 do
            love.graphics.print(shade, x + cw, y + r * ch)
        end
    end

    accent = accent or UI.accent
    uiColor(accent, 0.95)
    local top
    if title and title ~= "" then
        local label = " " .. fitAsciiText(title, inner - 2) .. " "
        local rest = math.max(0, inner - textLen(label))
        top = "┌" .. label .. string.rep("─", rest) .. "┐"
    else
        top = "┌" .. string.rep("─", inner) .. "┐"
    end
    love.graphics.print(top, x, y)

    uiColor(UI.stroke, shaded and 0.78 or 0.88)
    local mid = "│" .. string.rep(" ", inner) .. "│"
    for r = 1, rows - 2 do
        love.graphics.print(mid, x, y + r * ch)
    end
    love.graphics.print("└" .. string.rep("─", inner) .. "┘", x, y + (rows - 1) * ch)
end

local function asciiBox(x, y, w, h, title, accent, font)
    asciiBoxInternal(x, y, w, h, title, accent, font, true)
end

local function asciiOutline(x, y, w, h, title, accent, font)
    asciiBoxInternal(x, y, w, h, title, accent, font, false)
end

local function uiRect(mode, x, y, w, h, color, alpha, radius)
    -- ANSI UI: fills are text dithering, outlines are pure box-drawing symbols.
    if mode == "line" then
        asciiOutline(x, y, w, h, "", color or UI.stroke, smallFont or defaultFont)
    else
        local glyph = alpha and alpha > 0.55 and "▒" or "░"
        asciiFill(x, y, w, h, color or UI.panel, alpha or 0.25, glyph, smallFont or defaultFont)
    end
end

local function uiLine(x1, y1, x2, y2, color, alpha, width)
    if math.abs(y2 - y1) < 2 then
        asciiHLine(x1, y1, math.abs(x2 - x1), color or UI.stroke, alpha or 1, "─", smallFont or defaultFont)
    elseif math.abs(x2 - x1) < 2 then
        asciiVLine(x1, y1, math.abs(y2 - y1), color or UI.stroke, alpha or 1, "│", smallFont or defaultFont)
    else
        -- Rare fallback: draw a dotted diagonal using text glyphs.
        love.graphics.setFont(smallFont or defaultFont)
        uiColor(color or UI.stroke, alpha or 1)
        local steps = math.max(1, math.floor(math.sqrt((x2-x1)^2 + (y2-y1)^2) / 10))
        for i = 0, steps do
            local t = i / steps
            love.graphics.print("·", x1 + (x2-x1)*t, y1 + (y2-y1)*t)
        end
    end
end

local function uiPanel(x, y, w, h, title, accent)
    asciiBox(x, y, w, h, title, accent or UI.accent, smallFont or defaultFont)
end

local function uiChip(text, x, y, w, active, color)
    color = color or UI.accent
    local font = smallFont or defaultFont
    local cw = math.max(4, font:getWidth("M"))
    local chars = math.max(4, math.floor(w / cw) - 4)
    local label = fitAsciiText(text, chars)
    local left = active and "▶[" or " ["
    local right = active and "]◀" or "] "
    uiPrintRaw(left .. label .. right, x, y + 4, active and color or UI.muted, font, active and 1 or 0.82)
end

local function uiBar(x, y, w, h, value, fill, back, label, labelColor)
    value = clamp(value or 0, 0, 1)
    local font = smallFont or defaultFont
    local cw = math.max(4, font:getWidth("M"))
    local cells = math.max(6, math.floor(w / cw) - 2)
    local filled = math.floor(cells * value + 0.5)
    local bar = "[" .. string.rep("█", filled) .. string.rep("░", cells - filled) .. "]"
    if label then
        bar = bar .. " " .. tostring(label)
    end
    uiPrintRaw(bar, x, y, fill or UI.accent, font, 0.95)
end


local function uiKeyLine(parts, x, y, w, color)
    local out = {}
    for _, p in ipairs(parts) do
        table.insert(out, "[" .. tostring(p[1]) .. "] " .. tostring(p[2]))
    end
    uiPrintf(table.concat(out, "  |  "), x, y, w, "left", color or UI.muted, smallFont or defaultFont, 0.90)
end

local function uiAsciiRule(x, y, w, color, alpha)
    asciiHLine(x, y, w, color or UI.strokeSoft, alpha or 0.75, "─", smallFont or defaultFont)
end

local function uiTruncate(text, font, maxWidth)
    text = tostring(text or "")
    font = font or uiFont or defaultFont
    if font:getWidth(text) <= maxWidth then return text end
    local suffix = "…"
    local len = utf8.len(text) or #text
    for i = len, 1, -1 do
        local byte = utf8.offset(text, i + 1)
        local candidate
        if byte then candidate = text:sub(1, byte - 1) .. suffix else candidate = text:sub(1, i) .. suffix end
        if font:getWidth(candidate) <= maxWidth then return candidate end
    end
    return suffix
end

local function uiTypeLabel(item)
    local t = item and item.type or ""
    if t:find("weapon") then return "WEAPON", UI.bad end
    if t:find("armor") then return "ARMOR", UI.accent end
    if t:find("potion") then return "POTION", UI.good end
    if t:find("tool") then return "TOOL", UI.warn end
    if t:find("material") then return "MAT", UI.accent2 end
    if t:find("junk") then return "JUNK", UI.faint end
    return "ITEM", UI.muted
end

local function uiFilterTitle(filter)
    local names = {
        all = "ВСЁ", weapon = "ОРУЖИЕ", armor = "БРОНЯ", potion = "ЗЕЛЬЯ",
        tool = "КЛЮЧИ", material = "МАТ", junk = "МУСОР"
    }
    return names[filter] or tostring(filter or "?")
end

local function uiEquipSlotLabel(slot)
    local names = {head = "Голова", torso = "Корпус", legs = "Ноги"}
    return names[slot] or tostring(slot)
end

function drawToastMessage()
    if inventoryMessage == "" then return end
    love.graphics.setFont(smallFont or defaultFont)
    local item = Player.inventory[#Player.inventory]
    local color = item and item.rarityColor or UI.warn
    local t = clamp(inventoryMessageTimer / 3, 0, 1)
    local alpha = clamp(t * 1.4, 0, 1)
    local text = ":: " .. inventoryMessage .. " ::"
    local w = math.min(760, (smallFont or defaultFont):getWidth(text) + 28)
    local h = 44
    local x = baseWidth / 2 - w / 2
    local y = 48
    uiPanel(x, y, w, h, "СООБЩЕНИЕ", color)
    uiPrintf(uiTruncate(text, smallFont or defaultFont, w - 32), x + 16, y + 20, w - 32, "center", color, smallFont or defaultFont, alpha)
end

local function drawModernSceneBackdrop()
    -- v15: background is also a terminal field, not a smooth card UI.
    love.graphics.setFont(smallFont or defaultFont)
    local time = love.timer.getTime()
    local glyphs = {".", ":", "'", "`"}
    for i = 1, 95 do
        local x = (i * 149 + math.floor(time * 5)) % baseWidth
        local y = (i * 71 + math.floor(time * 2)) % baseHeight
        local a = 0.035 + ((i % 4) * 0.008)
        uiColor(i % 2 == 0 and UI.accent or UI.accent2, a)
        love.graphics.print(glyphs[(i % #glyphs) + 1], x, y)
    end
end

function getVisibleInventoryIndices()
    local filter = inventoryFilters[inventoryFilterIndex] or "all"
    local result = {}
    for i, item in ipairs(Player.inventory) do
        local t = item.type or ""
        if filter == "all" or t:find(filter) or t == filter then
            table.insert(result, i)
        end
    end
    return result
end

function visibleInventoryCount()
    local indices = getVisibleInventoryIndices()
    return #indices
end

function selectedInventoryActualIndex()
    local indices = getVisibleInventoryIndices()
    if #indices == 0 then return nil end
    selectedInventoryItem = clamp(selectedInventoryItem, 1, #indices)
    return indices[selectedInventoryItem]
end

function sortInventory()
    local order = {weapon = 1, armor = 2, potion = 3, tool = 4, material = 5, junk = 6}
    local function rank(item)
        local t = item.type or ""
        for k, v in pairs(order) do if t:find(k) then return v end end
        return 99
    end
    table.sort(Player.inventory, function(a, b)
        local ra, rb = rank(a), rank(b)
        if ra ~= rb then return ra < rb end
        return tostring(a.displayName or a.name) < tostring(b.displayName or b.name)
    end)
    inventoryMessage = "Инвентарь отсортирован"
    inventoryMessageTimer = 1.5
end

function dropJunkItems()
    local removed = 0
    for i = #Player.inventory, 1, -1 do
        local t = Player.inventory[i].type or ""
        if t == "junk" or t:find("junk") then
            table.remove(Player.inventory, i)
            removed = removed + 1
        end
    end
    selectedInventoryItem = 1
    inventoryMessage = removed > 0 and ("Мусор выброшен: " .. removed) or "Мусора нет"
    inventoryMessageTimer = 1.5
end

function compareWithEquipped(item)
    local result = {}
    if not item or not item.stats then return result end
    local equipped = nil
    if item.type and item.type:find("weapon") then
        equipped = Player.equipped.weapon
    elseif item.type and item.type:find("armor") then
        local slot = item.type:match("%((.-)%)") or "torso"
        equipped = Player.equipped.armor and Player.equipped.armor[slot]
    end
    local oldStats = equipped and equipped.stats or {}
    for stat, value in pairs(item.stats) do
        local newValue = normalizedStatValue(stat, value)
        local oldValue = normalizedStatValue(stat, oldStats[stat] or 0)
        result[stat] = newValue - oldValue
    end
    return result
end

function drawInventoryMenu()
    love.graphics.setFont(uiFont or defaultFont)
    local visibleIndices = getVisibleInventoryIndices()
    selectedInventoryItem = #visibleIndices > 0 and clamp(selectedInventoryItem, 1, #visibleIndices) or 1

    uiRect("fill", 0, 0, baseWidth, baseHeight, UI.dark, 0.70, 0)

    local margin = 44
    local panelX, panelY = margin, 42
    local panelW, panelH = baseWidth - margin * 2, baseHeight - 84
    uiPanel(panelX, panelY, panelW, panelH, "INVENTORY", UI.accent2)

    local headerY = panelY + 34
    uiText("ПРЕДМЕТЫ", panelX + 22, headerY, UI.text, uiLargeFont or uiFont)
    uiKeyLine({{"TAB", "фильтр"}, {"S", "сорт"}, {"X", "мусор"}, {"ENTER", "действие"}, {"ESC", "назад"}}, panelX + 22, headerY + 27, panelW - 44, UI.muted)

    local chipX = panelX + 22
    local chipY = headerY + 52
    for i, filter in ipairs(inventoryFilters) do
        local w = filter == "material" and 70 or 78
        uiChip(uiFilterTitle(filter), chipX, chipY, w, i == inventoryFilterIndex, i == inventoryFilterIndex and UI.accent2 or UI.accent)
        chipX = chipX + w + 8
    end

    local bodyY = panelY + 122
    local footerH = 44
    local bodyH = panelH - 154 - footerH
    local gap = 24
    local leftW = math.floor(panelW * 0.50) - gap
    local rightW = panelW - leftW - gap - 44
    local leftX, leftY = panelX + 22, bodyY
    local rightX, rightY = leftX + leftW + gap, bodyY

    uiPanel(leftX, leftY, leftW, bodyH, "LIST", UI.strokeSoft)
    local selectedActualIndex = visibleIndices[selectedInventoryItem]
    local selected = selectedActualIndex and Player.inventory[selectedActualIndex]
    uiPanel(rightX, rightY, rightW, bodyH, "DETAILS", selected and (selected.rarityColor or UI.accent) or UI.accent)

    local rowH = 28
    local maxRows = math.max(1, math.floor((bodyH - 38) / rowH))
    local startIndex = math.max(1, selectedInventoryItem - math.floor(maxRows / 2))
    if startIndex + maxRows - 1 > #visibleIndices then
        startIndex = math.max(1, #visibleIndices - maxRows + 1)
    end

    if #visibleIndices == 0 then
        uiPrintf("< пусто в текущем фильтре >", leftX, leftY + bodyH / 2 - 8, leftW, "center", UI.muted, uiFont or defaultFont)
    else
        for row = 1, maxRows do
            local invIndex = startIndex + row - 1
            local actualIndex = visibleIndices[invIndex]
            if actualIndex then
                local item = Player.inventory[actualIndex]
                local y = leftY + 28 + (row - 1) * rowH
                local active = invIndex == selectedInventoryItem
                local rarity = item.rarityColor or UI.text
                local tag, tagColor = uiTypeLabel(item)
                local marker = active and ">" or " "
                local lvl = item.itemLevel and (" L" .. tostring(item.itemLevel)) or ""
                local nameWidth = leftW - 172
                uiText(marker, leftX + 14, y + 3, active and UI.accent2 or UI.faint, uiFont or defaultFont)
                uiChip(tag, leftX + 34, y - 1, 68, active, tagColor)
                uiText(uiTruncate(item.displayName or item.name or "???", uiFont or defaultFont, nameWidth), leftX + 112, y + 3, active and UI.text or rarity, uiFont or defaultFont)
                uiPrintf(lvl, leftX + leftW - 62, y + 4, 44, "right", UI.muted, smallFont or defaultFont)
            end
        end
    end

    if #visibleIndices > maxRows then
        local scrollPct = (selectedInventoryItem - 1) / math.max(1, #visibleIndices - 1)
        local barCells = math.max(4, maxRows - 1)
        local knob = math.floor(scrollPct * (barCells - 1)) + 1
        for i = 1, barCells do
            uiText(i == knob and "█" or "░", leftX + leftW - 18, leftY + 34 + (i - 1) * 12, i == knob and UI.accent2 or UI.faint, smallFont or defaultFont)
        end
    end

    if selected then
        local rarity = selected.rarityColor or UI.text
        uiPrintf(uiTruncate(selected.displayName or selected.name or "???", uiLargeFont or uiFont, rightW - 42), rightX + 20, rightY + 34, rightW - 40, "left", rarity, uiLargeFont or uiFont)
        local tag, tagColor = uiTypeLabel(selected)
        uiChip(tag, rightX + 20, rightY + 68, 88, true, tagColor)
        uiText(uiTruncate(selected.type or "unknown", smallFont or defaultFont, rightW - 140), rightX + 122, rightY + 76, UI.muted, smallFont or defaultFont)
        uiAsciiRule(rightX + 20, rightY + 104, rightW - 40, UI.strokeSoft, 0.70)

        local infoY = rightY + 122
        if selected.powerScore then
            uiBar(rightX + 20, infoY, rightW - 40, 18, clamp((selected.powerScore or 0) / 80, 0, 1), rarity, UI.panel, string.format("PWR %.1f", selected.powerScore), UI.text)
            infoY = infoY + 28
        end
        if selected.itemLevel then
            uiText("ITEM LEVEL: " .. tostring(selected.itemLevel), rightX + 20, infoY, UI.muted, smallFont or defaultFont)
            infoY = infoY + 22
        end
        if selected.buildHint then
            uiText("BUILD: " .. tostring(selected.buildHint), rightX + 20, infoY, UI.accent, smallFont or defaultFont)
            infoY = infoY + 22
        end

        if selected.stats and next(selected.stats) then
            uiText("СТАТЫ", rightX + 20, infoY, UI.text, uiFont or defaultFont)
            infoY = infoY + 24
            local comparison = compareWithEquipped(selected)
            local row = 0
            for stat, value in pairs(selected.stats) do
                if row >= 9 then break end
                local diff = comparison[stat]
                local color = diff and diff > 0 and UI.good or diff and diff < 0 and UI.bad or UI.text
                local cmp = diff and diff ~= 0 and ("  (" .. formatStatValue(stat, diff) .. ")") or ""
                uiText(statLabel(stat), rightX + 26, infoY + row * 20, UI.muted, smallFont or defaultFont)
                uiPrintf(formatStatValue(stat, value) .. cmp, rightX + 170, infoY + row * 20, rightW - 200, "right", color, smallFont or defaultFont)
                row = row + 1
            end
            infoY = infoY + row * 20 + 8
        else
            uiText("нет боевых статов", rightX + 20, infoY, UI.muted, smallFont or defaultFont)
        end

        if selected.flavor then
            uiAsciiRule(rightX + 20, rightY + bodyH - 66, rightW - 40, UI.strokeSoft, 0.55)
            uiPrintf(uiTruncate(selected.flavor, smallFont or defaultFont, rightW - 40), rightX + 20, rightY + bodyH - 46, rightW - 40, "left", UI.faint, smallFont or defaultFont)
        end
    else
        uiPrintf("< выбери предмет слева >", rightX, rightY + bodyH / 2 - 10, rightW, "center", UI.muted, uiFont or defaultFont)
    end

    local statY = panelY + panelH - 36
    local hpPct = clamp((Player.health or 0) / math.max(1, Player.stats.maxHealth or 100), 0, 1)
    uiBar(panelX + 22, statY, 230, 18, hpPct, UI.good, UI.panel, string.format("HP %d/%d", Player.health or 0, Player.stats.maxHealth or 100), UI.text)
    uiText(string.format("DMG %.0f", Player.stats.damage or 0), panelX + 278, statY + 2, UI.text, smallFont or defaultFont)
    uiText(string.format("ARM %.0f", Player.stats.armor or 0), panelX + 358, statY + 2, UI.text, smallFont or defaultFont)
    uiText(string.format("CR %.0f%%", (Player.stats.critChance or 0) * 100), panelX + 438, statY + 2, UI.text, smallFont or defaultFont)
    uiText(string.format("LUCK %.2f", Player.stats.luck or 0), panelX + 520, statY + 2, UI.text, smallFont or defaultFont)

    if isContextMenuOpen and selected then
        local menuW = 174
        local menuH = #contextMenuOptions * 28 + 20
        local cx = rightX + rightW - menuW - 18
        local cy = rightY + 94
        uiPanel(cx, cy, menuW, menuH, "ACTION", UI.warn)
        for i, opt in ipairs(contextMenuOptions) do
            local y = cy + 30 + (i - 1) * 27
            local active = i == selectedContextOption
            uiPrintf((active and "> " or "  ") .. opt, cx + 14, y, menuW - 28, "left", active and UI.warn or UI.text, smallFont or defaultFont)
        end
    end

    love.graphics.setFont(defaultFont)
end


function drawSettingsMenu()
    drawModernSceneBackdrop()
    local w, h = 780, 470
    local x, y = baseWidth / 2 - w / 2, baseHeight / 2 - h / 2
    uiPanel(x, y, w, h, "SETTINGS", UI.accent)

    uiPrintf("ASCII DUNGEON 3D", x, y + 44, w, "center", UI.text, titleFont or uiLargeFont)
    uiPrintf("render / control / audio", x, y + 76, w, "center", UI.muted, smallFont or defaultFont)
    uiAsciiRule(x + 34, y + 106, w - 68, UI.strokeSoft, 0.65)

    local listX, listY = x + 50, y + 130
    local rowH = 37
    for i, setting in ipairs(settingsMenu) do
        local yy = listY + (i - 1) * rowH
        local active = i == selectedSetting
        local fmt = setting.fmt or "%.2f"
        local valueText = string.format(fmt, setting.value)
        local pct = (setting.value - setting.min) / math.max(0.0001, setting.max - setting.min)
        uiText(active and ">" or " ", listX - 24, yy, active and UI.accent or UI.faint, uiFont or defaultFont)
        uiText(setting.name, listX, yy, active and UI.text or UI.muted, uiFont or defaultFont)
        uiPrintf(valueText, x + w - 150, yy, 96, "right", active and UI.accent or UI.text, uiFont or defaultFont)
        uiBar(listX, yy + 20, w - 208, 8, pct, active and UI.accent or UI.faint, UI.panel, nil)
    end

    uiKeyLine({{"UP/DOWN", "выбор"}, {"LEFT/RIGHT", "изменить"}, {"ESC", "назад"}}, x + 34, y + h - 42, w - 68, UI.muted)
    love.graphics.setFont(defaultFont)
end

-- Отрисовка меню
function drawMenu()
    drawModernSceneBackdrop()
    local t = love.timer.getTime()
    local panelW, panelH = 650, 430
    local panelX, panelY = baseWidth / 2 - panelW / 2, baseHeight / 2 - panelH / 2
    uiPanel(panelX, panelY, panelW, panelH, "MAIN MENU", UI.accent2)

    local logo = {
        "  █████  ██████  ██████ ██ ██ ",
        " ██   ██ ██      ██     ██ ██ ",
        " ███████ ███████ ██     ██ ██ ",
        " ██   ██     ██  ██     ██ ██ ",
        " ██   ██ ██████  ██████ ██ ██ "
    }
    for i, line in ipairs(logo) do
        uiPrintf(line, panelX, panelY + 44 + (i - 1) * 16, panelW, "center", i <= 2 and UI.accent or UI.text, smallFont or defaultFont, 0.95)
    end
    uiPrintf("DUNGEON 3D // raycast roguelite", panelX, panelY + 150, panelW, "center", UI.muted, smallFont or defaultFont, 0.9)
    uiAsciiRule(panelX + 70, panelY + 182, panelW - 140, UI.strokeSoft, 0.75)

    local itemY = panelY + 206
    for i, text in ipairs(ansiMenuOptions) do
        local active = i == selectedMenuItem
        local y = itemY + (i - 1) * 46
        local color = i == 1 and UI.good or i == 2 and UI.accent or UI.bad
        local label = active and (">> [ " .. text .. " ] <<") or ("   [ " .. text .. " ]")
        uiPrintf(label, panelX + 120, y, panelW - 240, "left", active and color or UI.muted, uiFont or defaultFont, active and (0.78 + 0.22 * math.sin(t * 5)) or 0.75)
    end

    uiAsciiRule(panelX + 70, panelY + panelH - 74, panelW - 140, UI.strokeSoft, 0.55)
    uiKeyLine({{"ENTER", "выбор"}, {"W/S", "меню"}, {"F11", "fullscreen"}, {"F3", "debug"}}, panelX + 90, panelY + panelH - 48, panelW - 180, UI.muted)
    love.graphics.setFont(defaultFont)
end

function drawGameOver()
    drawModernSceneBackdrop()
    uiRect("fill", 0, 0, baseWidth, baseHeight, UI.dark, 0.52, 0)
    local w, h = 720, 430
    local x, y = baseWidth / 2 - w / 2, baseHeight / 2 - h / 2
    uiPanel(x, y, w, h, "RUN SUMMARY", UI.bad)
    uiPrintf("!!! GAME OVER !!!", x, y + 42, w, "center", UI.bad, titleFont or defaultFont, 1)
    uiPrintf("причина: " .. tostring(runStats.deathReason or "погиб"), x, y + 78, w, "center", UI.muted, smallFont or defaultFont, 0.95)
    uiAsciiRule(x + 60, y + 108, w - 120, UI.strokeSoft, 0.65)

    local leftX, rightX = x + 68, x + 390
    local yy = y + 132
    local rows = {
        {"Глубина", tostring(runStats.maxDepth or currentDepth or 1)},
        {"Зачищено", tostring(runStats.depthsCleared or 0)},
        {"Уровень", tostring(Player.level or 1)},
        {"Время", formatTime(runElapsed())},
        {"Убито", tostring(runStats.enemiesKilled or 0)},
        {"Предметов", tostring(runStats.itemsFound or 0)},
        {"Сундуков", tostring(runStats.chestsOpened or 0)},
        {"Алтарей", tostring(runStats.altarsUsed or 0)},
        {"Урон нанесён", tostring(math.floor(runStats.damageDealt or 0))},
        {"Урон получен", tostring(math.floor(runStats.damageTaken or 0))},
        {"Лучший удар", tostring(math.floor(runStats.bestHit or 0))},
    }
    for i, r in ipairs(rows) do
        local colX = i <= 6 and leftX or rightX
        local rowY = yy + ((i - 1) % 6) * 28
        uiText(r[1], colX, rowY, UI.muted, smallFont or defaultFont)
        uiPrintf(r[2], colX + 130, rowY, 130, "right", UI.text, smallFont or defaultFont)
    end

    uiAsciiRule(x + 60, y + 306, w - 120, UI.strokeSoft, 0.50)
    uiPrintf("Лучший предмет: " .. uiTruncate(runStats.bestItemName or "-", smallFont or defaultFont, w - 200), x + 70, y + 326, w - 140, "left", UI.warn, smallFont or defaultFont)
    uiPrintf(string.format("Рекорды: depth %d | kills %d | level %d", highScore.depth or 1, highScore.kills or 0, highScore.level or 1), x + 70, y + 354, w - 140, "left", UI.accent, smallFont or defaultFont)
    uiKeyLine({{"R", "новый забег"}, {"ESC", "в меню"}}, x + 190, y + h - 44, w - 380, UI.muted)
    love.graphics.setFont(defaultFont)
end

function drawMiniMap()
    local mapScale = fullMapVisible and miniMapScale or miniMapScale / 4
    local x0, y0 = 10, 10
    local miniMapWidth = cols * mapScale
    local miniMapHeight = rows * mapScale
    local playerMapX, playerMapY = Player.x / TILE_SIZE * mapScale, Player.y / TILE_SIZE * mapScale

    love.graphics.setColor(0, 0, 0, fullMapVisible and 0.78 or 0.6)
    love.graphics.rectangle("fill", x0, y0, miniMapWidth, miniMapHeight)
    love.graphics.setColor(1, 1, 1, 0.8)
    love.graphics.rectangle("line", x0, y0, miniMapWidth, miniMapHeight)

    for i = 1, #map do
        for j = 1, #map[i] do
            local wallInfo = getWallInfo(map[i][j])
            if map[i][j] == '0' then
                love.graphics.setColor(0.06, 0.06, 0.06, fullMapVisible and 0.85 or 0.35)
            else
                love.graphics.setColor(wallInfo.color[1]/255, wallInfo.color[2]/255, wallInfo.color[3]/255, fullMapVisible and 0.7 or 0.55)
            end
            love.graphics.rectangle("fill", x0 + (j - 1) * mapScale, y0 + (i - 1) * mapScale, mapScale, mapScale)
        end
    end

    for _, obj in ipairs(interactiveObjects) do
        local c = obj.kind == "chest" and {1.0, 0.78, 0.25}
            or obj.kind == "altar" and {0.45, 0.85, 1.0}
            or obj.kind == "exit" and {0.35, 1.0, 0.55}
            or {1, 1, 1}
        love.graphics.setColor(c[1], c[2], c[3], 1)
        love.graphics.rectangle("fill", x0 + (obj.cellX - 1) * mapScale, y0 + (obj.cellY - 1) * mapScale, math.max(2, mapScale), math.max(2, mapScale))
    end

    love.graphics.setColor(0, 0, 0, 1)
    for _, enemy in ipairs(enemies) do
        local enemyMapX = enemy.x / TILE_SIZE * mapScale
        local enemyMapY = enemy.y / TILE_SIZE * mapScale
        love.graphics.circle("fill", x0 + enemyMapX, y0 + enemyMapY, math.max(2, mapScale / 2))
    end

    love.graphics.setColor(1, 0, 0, 1)
    love.graphics.circle("fill", x0 + playerMapX, y0 + playerMapY, math.max(3, mapScale / 2))

    local angleLength = 5 * miniMapScale
    local lookX = math.cos(Player.angle) * angleLength
    local lookY = math.sin(Player.angle) * angleLength
    local endX = (Player.x + lookX) / TILE_SIZE * mapScale
    local endY = (Player.y + lookY) / TILE_SIZE * mapScale
    love.graphics.setColor(0, 1, 0, 1)
    love.graphics.line(x0 + playerMapX, y0 + playerMapY, x0 + endX, y0 + endY)

    love.graphics.setFont(smallFont or defaultFont)
    love.graphics.setColor(1, 1, 1, 0.8)
    love.graphics.print(fullMapVisible and "F4 map: full" or "F4 map", x0, y0 + miniMapHeight + 4)
    love.graphics.setFont(defaultFont)
end

-- Функция получения информации о стенах
function getWallInfo(symbol)
    return wallTextures[symbol] or wallTextures['1']
end


-- Рендеринг лучей
function castRays()
    clearArray(wallDistances)

    for i = 1, numRays do
        local rayAngle = (Player.angle - FOV / 2) + ((i - 0.5) / numRays) * FOV
        local distance, wallType, hitX, hitY, hitSide, hitMapX, hitMapY = raycast(Player.x, Player.y, rayAngle)
        local correctedDistance = math.max(1, distance * math.cos(Player.angle - rayAngle))
        local wallU = hitSide == 0 and ((hitY / TILE_SIZE) % 1) or ((hitX / TILE_SIZE) % 1)

        wallDistances[i] = {
            distance = correctedDistance,
            rawDistance = distance,
            wallType = wallType,
            hitX = hitX,
            hitY = hitY,
            hitSide = hitSide,
            hitMapX = hitMapX,
            hitMapY = hitMapY,
            wallU = wallU,
            rayAngle = rayAngle,
            rayIndex = i
        }
    end
end



-- Применяем освещение на основе расстояния до объекта
function applyLighting(distance)
    local maxLightDistance = 600
    local lightIntensity = math.max(0.2, 1 - (distance / maxLightDistance))
    return lightIntensity
end

-- DDA raycast: быстрее и стабильнее, чем шагать по 2 пикселя.
function raycast(x, y, angle)
    local rayDirX = math.cos(angle)
    local rayDirY = math.sin(angle)

    local mapX = toCell(x)
    local mapY = toCell(y)

    local deltaDistX = rayDirX == 0 and math.huge or math.abs(TILE_SIZE / rayDirX)
    local deltaDistY = rayDirY == 0 and math.huge or math.abs(TILE_SIZE / rayDirY)

    local stepX, stepY, sideDistX, sideDistY

    if rayDirX == 0 then
        stepX = 0
        sideDistX = math.huge
    elseif rayDirX < 0 then
        stepX = -1
        sideDistX = (x - mapX * TILE_SIZE) / math.abs(rayDirX)
    else
        stepX = 1
        sideDistX = ((mapX + 1) * TILE_SIZE - x) / math.abs(rayDirX)
    end

    if rayDirY == 0 then
        stepY = 0
        sideDistY = math.huge
    elseif rayDirY < 0 then
        stepY = -1
        sideDistY = (y - mapY * TILE_SIZE) / math.abs(rayDirY)
    else
        stepY = 1
        sideDistY = ((mapY + 1) * TILE_SIZE - y) / math.abs(rayDirY)
    end

    local distance = 0
    local side = 0

    while distance < MAX_RAY_DISTANCE do
        if sideDistX < sideDistY then
            mapX = mapX + stepX
            distance = sideDistX
            sideDistX = sideDistX + deltaDistX
            side = 0
        else
            mapY = mapY + stepY
            distance = sideDistY
            sideDistY = sideDistY + deltaDistY
            side = 1
        end

        if not map[mapY] or not map[mapY][mapX] then
            break
        end

        local cell = map[mapY][mapX]
        if cell ~= '0' then
            local hitX = x + rayDirX * distance
            local hitY = y + rayDirY * distance
            return distance, cell, hitX, hitY, side, mapX, mapY
        end
    end

    return MAX_RAY_DISTANCE, '0', x + rayDirX * MAX_RAY_DISTANCE, y + rayDirY * MAX_RAY_DISTANCE, side, mapX, mapY
end

-- Обновление врагов
function updateEnemies(dt)
    local now = love.timer.getTime()
    for _, enemy in ipairs(enemies) do
        if enemy.hitFlash and enemy.hitFlash > 0 then
            enemy.hitFlash = math.max(0, enemy.hitFlash - dt * 5)
        end
        enemy.stagger = math.max(0, (enemy.stagger or 0) - dt)

        local dx = Player.x - enemy.x
        local dy = Player.y - enemy.y
        local distance = math.sqrt(dx * dx + dy * dy)
        local aggro = enemy.aggroRange or 210
        local role = enemy.role or Balance.enemyRoles.default
        local los = distance < aggro and hasLineOfSightTo(enemy.x, enemy.y, distance)

        enemy.vx = enemy.vx or 0
        enemy.vy = enemy.vy or 0
        if distance > 0 and distance < aggro and enemy.stagger <= 0 then
            local dirX = dx / distance
            local dirY = dy / distance
            local moveX, moveY = 0, 0
            local preferred = enemy.preferredRange or role.preferredRange or enemy.attackRange or 18

            if role.kind == "ranged" then
                if distance < (role.retreatDistance or preferred * 0.55) then
                    moveX, moveY = -dirX, -dirY
                elseif distance > preferred then
                    moveX, moveY = dirX, dirY
                elseif role.orbit then
                    local side = enemy.orbitSide or 1
                    moveX, moveY = -dirY * side * 0.62, dirX * side * 0.62
                end
            elseif role.kind == "skirmisher" then
                if distance > preferred then
                    moveX, moveY = dirX, dirY
                elseif distance < preferred * 0.72 then
                    moveX, moveY = -dirX, -dirY
                else
                    local side = enemy.orbitSide or 1
                    moveX, moveY = -dirY * side * 0.45, dirX * side * 0.45
                end
            else
                if distance > preferred * 0.85 then
                    moveX, moveY = dirX, dirY
                end
            end

            -- v19: мягкое steering-движение + разлипание врагов.
            local sepX, sepY = 0, 0
            for _, other in ipairs(enemies) do
                if other ~= enemy then
                    local odx, ody = enemy.x - other.x, enemy.y - other.y
                    local od = math.sqrt(odx * odx + ody * ody)
                    local wanted = (enemy.radius or 9) + (other.radius or 9) + 10
                    if od > 0.01 and od < wanted then
                        local f = (1 - od / wanted)
                        sepX = sepX + (odx / od) * f
                        sepY = sepY + (ody / od) * f
                    end
                end
            end
            moveX, moveY = moveX + sepX * 1.25, moveY + sepY * 1.25

            local targetVX, targetVY = 0, 0
            if (moveX * moveX + moveY * moveY) > 0 then
                local len = math.sqrt(moveX * moveX + moveY * moveY)
                moveX, moveY = moveX / len, moveY / len
                local speed = enemy.speed * (role.moveMul or 1)
                targetVX, targetVY = moveX * speed, moveY * speed
            end
            enemy.vx = approach(enemy.vx, targetVX, dt * 7.5)
            enemy.vy = approach(enemy.vy, targetVY, dt * 7.5)
        else
            enemy.vx = approach(enemy.vx or 0, 0, dt * 8.5)
            enemy.vy = approach(enemy.vy or 0, 0, dt * 8.5)
        end

        if math.abs(enemy.vx or 0) + math.abs(enemy.vy or 0) > 0.1 then
            local radius = enemy.radius or 8
            local nextX = enemy.x + enemy.vx * dt
            local nextY = enemy.y + enemy.vy * dt
            if not checkWallCircleCollision(nextX, enemy.y, radius) and not enemyCollidesWithOthers(enemy, nextX, enemy.y) then
                enemy.x = nextX
            else
                enemy.vx = -(enemy.vx or 0) * 0.18
            end
            if not checkWallCircleCollision(enemy.x, nextY, radius) and not enemyCollidesWithOthers(enemy, enemy.x, nextY) then
                enemy.y = nextY
            else
                enemy.vy = -(enemy.vy or 0) * 0.18
            end
        end

        enemy.lastAttackTime = enemy.lastAttackTime or 0
        local attackDelay = 1 / math.max(0.25, (enemy.attackSpeed or 1) * (role.attackSpeedMul or 1))
        local attackRadius = role.kind == "ranged" and (enemy.rangedAttackRange or role.attackRange or 150) or (Player.radius + (enemy.attackRange or 14))
        local canAttack = distance < attackRadius and (role.kind ~= "ranged" or los)

        if canAttack and (now - enemy.lastAttackTime > attackDelay) then
            enemy.lastAttackTime = now
            if love.math.random() < clamp(Player.stats.dodge or 0, 0, 0.45) then
                addFloatingText(Player.x, Player.y, "MISS", {0.65, 0.85, 1})
            else
                local damage, crit = rollDamage(getEnemyStats(enemy), Player.stats.armor or 0, role.damageMul or 1)
                damage = math.floor(damage + 0.5)
                Player.health = math.max(Player.health - damage, 0)
                recordDamageTaken(damage)
                damageFlash = math.min(0.9, 0.35 + damage / math.max(1, Player.stats.maxHealth))
                applyKnockbackToPlayer(enemy.x, enemy.y, role.kind == "ranged" and 80 or 145)
                triggerScreenShake(role.kind == "ranged" and 3.0 or 4.8, 0.14)
                local verb = role.kind == "ranged" and "заклятье" or "удар"
                addFloatingText(Player.x, Player.y, (crit and "CRIT -" or "-") .. tostring(damage), crit and {1, 0.15, 0.05} or {1, 0.2, 0.2})
                lastCombatEvent = enemyDisplayName(enemy) .. " " .. verb .. ": " .. tostring(damage)
                SFXGenerator:generate({layers = {{waveform = role.kind == "ranged" and {"sine", "saw"} or {"saw", "noise"}, frequency = role.kind == "ranged" and {260, 540} or {120, 250}, duration = {0.08, 0.16}, volume = {0.35, 0.62}, effects = {tremolo = 0.2, pitchbend = role.kind == "ranged" and 0.25 or -0.3}}}})
            end
            if Player.health <= 0 then
                endRun(enemyDisplayName(enemy))
            end
        end
    end
end

function enemyCollidesWithOthers(currentEnemy, newX, newY)
    for _, enemy in ipairs(enemies) do
        if enemy ~= currentEnemy then
            local dx = enemy.x - newX
            local dy = enemy.y - newY
            local distance = math.sqrt(dx * dx + dy * dy)
            local minDist = (currentEnemy.radius or 8) + (enemy.radius or 8) + 2
            if distance < minDist then
                return true
            end
        end
    end
    return false
end



-- Обновление частиц
function updateParticles(dt)
    for i = #particles, 1, -1 do
        local p = particles[i]
        p.x = p.x + p.vx * dt
        p.y = p.y + p.vy * dt
        p.life = p.life - dt

        if p.life <= 0 then
            table.remove(particles, i)
        end
    end
end

function handleAttack()
    Player.lastAttackTime = Player.lastAttackTime or 0
    local currentTime = love.timer.getTime()
    local profile = getWeaponProfile()
    local attackDelay = (profile.cooldown or 0.52) / math.max(0.25, Player.stats.attackSpeed or 1)
    if currentTime - Player.lastAttackTime < attackDelay then return false end

    Player.lastAttackTime = currentTime
    attackVisualTimer = 1
    local candidates = {}

    for i = #enemies, 1, -1 do
        local enemy = enemies[i]
        local dx = enemy.x - Player.x
        local dy = enemy.y - Player.y
        local distance = math.sqrt(dx * dx + dy * dy)
        local angleToEnemy = math.atan2(dy, dx) - Player.angle
        while angleToEnemy > math.pi do angleToEnemy = angleToEnemy - 2 * math.pi end
        while angleToEnemy < -math.pi do angleToEnemy = angleToEnemy + 2 * math.pi end
        if distance < profile.range and math.abs(angleToEnemy) < profile.angle / 2 and hasLineOfSightTo(enemy.x, enemy.y, distance) then
            table.insert(candidates, {index = i, enemy = enemy, distance = distance, angle = math.abs(angleToEnemy)})
        end
    end

    table.sort(candidates, function(a, b)
        if math.abs(a.distance - b.distance) < 0.01 then return a.angle < b.angle end
        return a.distance < b.distance
    end)

    local hitCount = 0
    for _, c in ipairs(candidates) do
        if hitCount >= profile.maxTargets then break end
        local enemy = c.enemy
        if enemy and enemy.health and enemy.health > 0 then
            if love.math.random() < clamp(enemy.dodge or 0, 0, 0.35) then
                addFloatingText(enemy.x, enemy.y, "MISS", {0.7, 0.8, 1})
            else
                local distanceFalloff = profile.kind == "ranged" and 1 or clamp(1.08 - (c.distance / profile.range) * 0.25, 0.78, 1.08)
                local damage, isCrit = rollDamage(Player.stats, enemy.defense or 0, profile.damageScale * distanceFalloff)
                damage = math.floor(damage + 0.5)
                enemy.health = enemy.health - damage
                recordDamageDealt(damage)
                enemy.hitFlash = 1
                enemy.stagger = profile.kind == "melee" and 0.14 or 0.08
                applyKnockbackToEnemy(enemy, Player.x, Player.y, (profile.knockback or 110) * (isCrit and 1.25 or 1.0))
                triggerHitStop(profile.hitStop or 0.035)
                triggerScreenShake((profile.shake or 3.2) * (isCrit and 1.25 or 1.0), 0.11)
                addFloatingText(enemy.x, enemy.y, (isCrit and "CRIT " or "-") .. tostring(damage), isCrit and {1, 0.85, 0.2} or {1, 0.35, 0.25})
                lastCombatEvent = "Удар по " .. enemyDisplayName(enemy) .. ": " .. tostring(damage)
                local lifesteal = clamp(Player.stats.lifesteal or 0, 0, 0.25)
                if lifesteal > 0 then
                    local heal = math.floor(damage * lifesteal)
                    if heal > 0 then Player.health = math.min(Player.stats.maxHealth, Player.health + heal) end
                end
                SFXGenerator:generate({layers = {{waveform = {"sine", "square"}, frequency = {200, 420}, duration = {0.08, 0.16}, volume = {0.35, 0.55}, effects = {bitcrush = 0.25, vibrato = 7}}}})
                if enemy.health <= 0 then handleEnemyDeath(c.index, enemy) end
            end
            hitCount = hitCount + 1
        end
    end

    if hitCount == 0 then
        SFXGenerator:generate({layers = {{waveform = {"triangle"}, frequency = {300, 500}, duration = {0.08, 0.14}, volume = {0.22, 0.35}, effects = {pitchbend = -0.2}}}})
    end
    return true
end

function handleEnemyDeath(index, enemy)
    if enemies[index] == enemy then
        table.remove(enemies, index)
    else
        for j = #enemies, 1, -1 do
            if enemies[j] == enemy then table.remove(enemies, j); break end
        end
    end
    enemiesKilledThisDepth = (enemiesKilledThisDepth or 0) + 1
    if runStats then runStats.enemiesKilled = (runStats.enemiesKilled or 0) + 1 end
    local expGain = enemy.xpValue or math.floor(18 + (enemy.level or 1) * 8 + (currentDepth or 1) * 4)
    gainExperience(expGain)
    addFloatingText(enemy.x, enemy.y, "+" .. tostring(expGain) .. " XP", {0.55, 1, 0.55})
    SFXGenerator:generate({layers = {{waveform = {"noise"}, frequency = {100, 400}, duration = {0.22, 0.42}, volume = {0.42, 0.65}, effects = {tremolo = 0.3}}}})

    local luck = Player.stats.luck or 0
    local dropChance = clamp((enemy.dropChance or 0.2) + luck * 0.16 + (currentDepth or 1) * 0.008, 0.05, 0.88)
    if love.math.random() < dropChance then
        local item = LootGenerator.generateCombatItem({
            location = enemy.location or "dungeon",
            enemyType = enemy.type or "skeleton",
            difficulty = getDifficultyMultiplier(),
            playerLuck = luck,
            itemLevel = math.max(1, enemy.level or Player.level or 1),
            depth = currentDepth or 1,
            playerLevel = Player.level or 1,
            playerStats = { lowHP = Player.health < (Player.stats.maxHealth or 100) * 0.3 }
        })
        addInventoryItem(item, "Добыча: ")
        addFloatingText(enemy.x, enemy.y, "+loot", item.rarityColor or {1, 0.85, 0.2})
    end
end

function handleWallDestruction()
    if love.keyboard.isDown('e') then
        local rayAngle = Player.angle
        local attackRange = 150
        local distance, wallType, hitX, hitY = raycast(Player.x, Player.y, rayAngle)
        if wallType ~= '0' and distance < attackRange then
            destroyWall(hitX + math.cos(rayAngle), hitY + math.sin(rayAngle))
            -- Добавьте звук разрушения стены, если требуется
        end
    end
end

-- Разрушение стены
function destroyWall(x, y)
    local gridX, gridY = toCell(x), toCell(y)
    if gridY >= 1 and gridY <= #map and gridX >= 1 and gridX <= #map[gridY] then
        map[gridY][gridX] = '0'
        local wallInfo = getWallInfo('1')
        spawnParticlesAtPosition(x, y, wallInfo.color)
    end
end

-- Спавн частиц при разрушении стены
function spawnParticlesAtPosition(x, y, color)
    for _ = 1, 20 do -- Ограничиваем количество частиц
        createParticle(x + love.math.random(-5, 5), y + love.math.random(-5, 5), color)
    end
end

-- Создание частицы
function createParticle(x, y, color)
    table.insert(particles, {
        x = x,
        y = y,
        vx = love.math.random(-100, 100),
        vy = love.math.random(-100, 100),
        life = 0.5,
        symbol = particleSymbols[love.math.random(1, #particleSymbols)],
        color = color
    })
end

-- Сбор видимых спрайтов
function collectVisibleSprites()
    clearArray(visibleSprites)

    local function tryAddSprite(worldX, worldY, maxDistance, builder)
        local dx = worldX - Player.x
        local dy = worldY - Player.y
        local distance = math.sqrt(dx * dx + dy * dy)
        if distance <= 0 or distance > maxDistance then return end

        local angleTo = math.atan2(dy, dx) - Player.angle
        while angleTo > math.pi do angleTo = angleTo - 2 * math.pi end
        while angleTo < -math.pi do angleTo = angleTo + 2 * math.pi end
        if math.abs(angleTo) >= FOV / 2 then return end

        local screenX = (angleTo + FOV / 2) / FOV * baseWidth
        local rayIndex = clamp(math.floor((screenX / baseWidth) * numRays) + 1, 1, numRays)
        local wallDepth = wallDistances[rayIndex] and wallDistances[rayIndex].distance or math.huge
        local correctedDistance = distance * math.cos(angleTo)
        if correctedDistance >= wallDepth - 2 then return end

        local sprite = builder(distance, correctedDistance, angleTo, screenX, rayIndex)
        table.insert(visibleSprites, sprite)
    end

    for _, obj in ipairs(interactiveObjects) do
        if not obj.hidden then
            tryAddSprite(obj.x, obj.y, maxRenderDistance, function(distance, correctedDistance, angle, screenX, rayIndex)
                local near = distance < (obj.interactRadius or 52)
                return {
                    kind = "object",
                    type = obj.kind,
                    label = obj.label,
                    color = obj.color,
                    x = obj.x,
                    y = obj.y,
                    distance = distance,
                    correctedDistance = correctedDistance,
                    angle = angle,
                    screenX = screenX,
                    rayIndex = rayIndex,
                    highlight = near,
                    reference = obj
                }
            end)
        end
    end

    for _, enemy in ipairs(enemies) do
        tryAddSprite(enemy.x, enemy.y, maxRenderDistance, function(distance, correctedDistance, angle, screenX, rayIndex)
            local highlight = distance <= (Player.stats.range or 1) * TILE_SIZE and math.abs(angle) < 0.05
            return {
                kind = "enemy",
                type = enemy.type or 'E',
                x = enemy.x,
                y = enemy.y,
                distance = distance,
                correctedDistance = correctedDistance,
                angle = angle,
                screenX = screenX,
                rayIndex = rayIndex,
                parts = (enemy.spriteTemplate and enemy.spriteTemplate.parts) or enemySprites.slime.parts,
                highlight = highlight,
                reference = enemy
            }
        end)
    end
end

local objectReadableVisuals = {
    chest = {
        marker = "C",
        title = "СУНДУК",
        usedTitle = "ПУСТО",
        hint = "сундук",
        color = {1.0, 0.78, 0.25}
    },
    altar = {
        marker = "A",
        title = "АЛТАРЬ",
        usedTitle = "АЛТАРЬ",
        hint = "алтарь",
        color = {0.45, 0.85, 1.0}
    },
    exit = {
        marker = ">",
        title = "ВЫХОД",
        usedTitle = "ВЫХОД",
        hint = "выход",
        color = {0.35, 1.0, 0.55}
    }
}

local function getObjectReadableVisual(sprite)
    local v = objectReadableVisuals[sprite.type or ""] or objectReadableVisuals.chest
    local obj = sprite.reference or {}
    local title = v.title
    if obj.state == "opened" or obj.used then
        title = v.usedTitle or title
    end
    return v, title
end

function drawObjectSprite(sprite)
    local d = math.max(1, sprite.correctedDistance or sprite.distance or 1)
    local rawD = math.max(24, sprite.distance or d)
    local screenX = sprite.screenX or ((sprite.angle + FOV / 2) / FOV * baseWidth)

    -- Мягкое появление: объект плавно входит в FOV, но больше не меняет LOD слишком резко.
    local distanceFade = 1 - smoothstep(maxRenderDistance * 0.76, maxRenderDistance, d)
    local edgeFade = 1 - smoothstep(FOV * 0.40, FOV * 0.50, math.abs(sprite.angle or 0))
    local fade = clamp(distanceFade * edgeFade, 0, 1)
    if fade <= 0.02 then return end

    local visual, title = getObjectReadableVisual(sprite)
    local color = visual.color or sprite.color or {1, 1, 1}
    local nearBoost = sprite.highlight and 0.18 or 0
    local light = clamp(applyLighting(d) + nearBoost, 0.14, 1.0)
    local alpha = clamp(0.14 + fade * 0.86, 0, 1)
    local r, g, b = color[1] * light, color[2] * light, color[3] * light

    -- Размер считаем по реальной дистанции, а не по fisheye-correctedDistance.
    -- Это фиксит эффект, когда объект у края экрана мог странно "сжиматься" при приближении.
    local projected = (baseHeight / rawD) * (TILE_SIZE * 1.18)
    if rawD < 55 then
        projected = math.max(projected, 88 + (55 - rawD) * 1.45)
    end
    projected = clamp(projected, 16, 205)

    local w = projected * (sprite.type == "exit" and 1.10 or 1.02)
    local h = projected * (sprite.type == "altar" and 1.22 or sprite.type == "exit" and 1.30 or 0.84)

    -- Ноги/основание объекта ставим туда же, где на этой дистанции заканчивается стена.
    local floorY = baseHeight / 2 + (baseHeight / math.max(26, d)) * 25
    floorY = clamp(floorY, baseHeight / 2 + 18, baseHeight - 18)
    local x = screenX - w / 2
    local y = floorY - h

    -- Дальний LOD: теперь переключается позже и не проваливается в маленькую точку при приближении.
    if d > 220 then
        local marker = visual.marker or "?"
        local size = clamp(projected * 0.72, 12, 32)
        love.graphics.setFont(titleFont or defaultFont)
        love.graphics.setColor(0, 0, 0, alpha * 0.55)
        love.graphics.ellipse("fill", screenX, floorY + 3, size * 0.65, size * 0.18)
        love.graphics.setColor(0, 0, 0, alpha * 0.75)
        love.graphics.printf(marker, screenX - size, floorY - size - 1, size * 2, "center")
        love.graphics.setColor(r, g, b, alpha)
        love.graphics.printf(marker, screenX - size, floorY - size - 3, size * 2, "center")
        love.graphics.setFont(defaultFont)
        return
    end

    -- Контактная тень и мягкий grounding. Чем ближе объект, тем сильнее тень.
    love.graphics.setColor(0, 0, 0, alpha * clamp(0.62 - d / 760, 0.20, 0.62))
    love.graphics.ellipse("fill", screenX, floorY + 2, w * 0.48, math.max(3, h * 0.075))

    -- Лёгкое локальное затемнение стены/пола за объектом, чтобы он сидел в сцене.
    love.graphics.setColor(0, 0, 0, alpha * 0.13)
    love.graphics.ellipse("fill", screenX, y + h * 0.58, w * 0.58, h * 0.60)

    local obj = sprite.reference or {}
    local outlineAlpha = alpha * (sprite.highlight and 0.96 or 0.70)

    if sprite.type == "chest" then
        local bodyX = x + w * 0.13
        local bodyY = floorY - h * 0.48
        local bodyW = w * 0.74
        local bodyH = h * 0.34
        local lidY = bodyY - h * 0.18
        local lidH = h * 0.24

        love.graphics.setColor(0, 0, 0, outlineAlpha)
        love.graphics.rectangle("fill", bodyX - 2, lidY - 2, bodyW + 4, lidH + bodyH + 4, 4, 4)

        if obj.state == "opened" then
            love.graphics.setColor(r * 0.70, g * 0.58, b * 0.38, alpha * 0.95)
            love.graphics.rectangle("fill", bodyX, bodyY, bodyW, bodyH, 4, 4)
            love.graphics.setColor(0, 0, 0, alpha * 0.82)
            love.graphics.rectangle("fill", bodyX + bodyW * 0.10, bodyY + bodyH * 0.10, bodyW * 0.80, bodyH * 0.22, 3, 3)
            love.graphics.setColor(r * 0.95, g * 0.82, b * 0.55, alpha * 0.68)
            love.graphics.line(bodyX + bodyW * 0.12, bodyY - h * 0.13, bodyX + bodyW * 0.88, bodyY - h * 0.05)
        else
            love.graphics.setColor(r * 0.92, g * 0.74, b * 0.42, alpha)
            love.graphics.rectangle("fill", bodyX, bodyY, bodyW, bodyH, 4, 4)
            love.graphics.setColor(r, g * 0.85, b * 0.50, alpha)
            love.graphics.rectangle("fill", bodyX, lidY, bodyW, lidH, 5, 5)
            love.graphics.setColor(0, 0, 0, alpha * 0.55)
            love.graphics.line(bodyX, bodyY, bodyX + bodyW, bodyY)
            love.graphics.setColor(1, 0.92, 0.48, alpha)
            love.graphics.rectangle("fill", bodyX + bodyW * 0.46, bodyY + bodyH * 0.06, bodyW * 0.08, bodyH * 0.28, 2, 2)
        end

    elseif sprite.type == "altar" then
        local baseX = x + w * 0.24
        local baseY = floorY - h * 0.38
        local baseW = w * 0.52
        local baseH = h * 0.28
        local runeY = baseY - h * 0.24
        local runeR = math.max(5, h * 0.12)

        love.graphics.setColor(0, 0, 0, outlineAlpha)
        love.graphics.rectangle("fill", baseX - 2, baseY - 2, baseW + 4, baseH + 4, 4, 4)
        love.graphics.circle("fill", screenX, runeY, runeR + 2)

        love.graphics.setColor(r * 0.55, g * 0.66, b * 0.86, alpha * 0.96)
        love.graphics.rectangle("fill", baseX, baseY, baseW, baseH, 4, 4)
        love.graphics.setColor(r, g, b, alpha * 0.75)
        love.graphics.circle("line", screenX, runeY, runeR)
        love.graphics.line(screenX - runeR * 0.9, runeY, screenX + runeR * 0.9, runeY)
        love.graphics.line(screenX, runeY - runeR * 0.9, screenX, runeY + runeR * 0.9)
        love.graphics.setColor(r, g, b, alpha * 0.16)
        love.graphics.circle("fill", screenX, runeY, runeR * 2.1)

    elseif sprite.type == "exit" then
        local portalH = h * 0.92
        local portalW = w * 0.58
        local px = screenX
        local py = floorY - portalH * 0.50

        love.graphics.setColor(0, 0, 0, outlineAlpha)
        love.graphics.setLineWidth(math.max(3, projected * 0.055))
        love.graphics.ellipse("line", px, py, portalW * 0.54, portalH * 0.48)
        love.graphics.setColor(r, g, b, alpha * 0.88)
        love.graphics.ellipse("line", px, py, portalW * 0.50, portalH * 0.45)
        love.graphics.setColor(r, g, b, alpha * 0.18)
        love.graphics.ellipse("fill", px, py, portalW * 0.42, portalH * 0.36)
        love.graphics.setColor(0.02, 0.03, 0.025, alpha * 0.72)
        love.graphics.ellipse("fill", px, py, portalW * 0.28, portalH * 0.25)
        love.graphics.setColor(r, g, b, alpha)
        love.graphics.line(px - portalW * 0.18, py - portalH * 0.08, px, py + portalH * 0.06, px - portalW * 0.18, py + portalH * 0.20)
        love.graphics.line(px + portalW * 0.02, py - portalH * 0.08, px + portalW * 0.20, py + portalH * 0.06, px + portalW * 0.02, py + portalH * 0.20)
        love.graphics.setLineWidth(1)
    end

    if sprite.highlight then
        love.graphics.setFont(smallFont or defaultFont)
        love.graphics.setColor(0, 0, 0, 0.72)
        love.graphics.rectangle("fill", screenX - 50, y - 28, 100, 20, 5, 5)
        love.graphics.setColor(1, 1, 1, 0.94)
        love.graphics.printf("E - " .. title, screenX - 85, y - 25, 170, "center")
        love.graphics.setFont(defaultFont)
    end
end

local function enemyMarkerFor(spriteType)
    return spriteType == "wizard" and "W" or spriteType == "skeleton" and "S" or spriteType == "goblin" and "g" or spriteType == "beast" and "B" or spriteType == "boss" and "!" or "o"
end

local function setEnemyPartColor(part, light, alpha, hitFlash)
    local r = (part.color[1] or 255) / 255 * light
    local g = (part.color[2] or 255) / 255 * light
    local b = (part.color[3] or 255) / 255 * light
    if hitFlash and hitFlash > 0 then
        r = r + (1 - r) * hitFlash
        g = g + (0.20 - g) * hitFlash
        b = b + (0.20 - b) * hitFlash
    end
    love.graphics.setColor(r, g, b, alpha or 1)
end

local function drawEnemyPartShape(part, px, py, s, outline)
    local extra = outline and math.max(1.5, s * 0.55) or 0
    if part.shape == "circle" then
        love.graphics.circle("fill", px, py, math.max(1, part.radius * s + extra))
    elseif part.shape == "rectangle" then
        love.graphics.rectangle("fill", px - (part.width/2) * s - extra, py - (part.height/2) * s - extra, part.width * s + extra * 2, part.height * s + extra * 2, 2, 2)
    elseif part.shape == "line" then
        local oldWidth = love.graphics.getLineWidth()
        love.graphics.setLineWidth(math.max(1, (part.thickness or 1.2) * s + extra))
        love.graphics.line(px, py, px + (part.x2 - part.offsetX) * s, py + (part.y2 - part.offsetY) * s)
        love.graphics.setLineWidth(oldWidth)
    elseif part.shape == "triangle" then
        local hw = (part.width or 8) * s * 0.5 + extra
        local hh = (part.height or 8) * s * 0.5 + extra
        love.graphics.polygon("fill", px, py - hh, px - hw, py + hh, px + hw, py + hh)
    end
end

local function enemyVisualProfile(kind)
    -- v9: размер врагов теперь монотонно растёт при приближении.
    -- lift оставлен только как запасной коэффициент; фактическая привязка идёт по нижней границе модели.
    if kind == "boss" then
        return { mass = 1.35, maxSize = 265, minSize = 18, lift = 0.48, closeBoost = 1.0, shadow = 0.56, lod = 255 }
    elseif kind == "beast" then
        return { mass = 1.18, maxSize = 215, minSize = 15, lift = 0.46, closeBoost = 1.0, shadow = 0.52, lod = 240 }
    elseif kind == "slime" then
        return { mass = 0.92, maxSize = 165, minSize = 12, lift = 0.38, closeBoost = 1.0, shadow = 0.60, lod = 225 }
    elseif kind == "goblin" then
        return { mass = 1.05, maxSize = 195, minSize = 14, lift = 0.44, closeBoost = 1.0, shadow = 0.50, lod = 235 }
    elseif kind == "wizard" then
        return { mass = 1.12, maxSize = 210, minSize = 15, lift = 0.50, closeBoost = 1.0, shadow = 0.48, lod = 245 }
    else
        return { mass = 1.08, maxSize = 205, minSize = 14, lift = 0.46, closeBoost = 1.0, shadow = 0.50, lod = 235 }
    end
end

local function drawEnemyGroundAura(screenX, floorY, projected, light, alpha, hitFlash)
    local pulse = 0.5 + 0.5 * math.sin(love.timer.getTime() * 5.0)
    local hit = hitFlash and hitFlash > 0 and hitFlash or 0
    love.graphics.setColor(0.85, 0.08 + hit * 0.30, 0.06 + hit * 0.18, alpha * (0.055 + pulse * 0.025 + hit * 0.16))
    love.graphics.ellipse("fill", screenX, floorY - projected * 0.06, projected * 0.48, projected * 0.17)
end

local function enemyLocalBounds(parts)
    local minY, maxY = math.huge, -math.huge
    for _, part in ipairs(parts or {}) do
        if part.shape == "circle" then
            minY = math.min(minY, part.offsetY - (part.radius or 0))
            maxY = math.max(maxY, part.offsetY + (part.radius or 0))
        elseif part.shape == "rectangle" then
            minY = math.min(minY, part.offsetY - (part.height or 0) * 0.5)
            maxY = math.max(maxY, part.offsetY + (part.height or 0) * 0.5)
        elseif part.shape == "triangle" then
            minY = math.min(minY, part.offsetY - (part.height or 0) * 0.5)
            maxY = math.max(maxY, part.offsetY + (part.height or 0) * 0.5)
        elseif part.shape == "line" then
            minY = math.min(minY, part.offsetY, part.y2 or part.offsetY)
            maxY = math.max(maxY, part.offsetY, part.y2 or part.offsetY)
        else
            minY = math.min(minY, part.offsetY or 0)
            maxY = math.max(maxY, part.offsetY or 0)
        end
    end
    if minY == math.huge then return -12, 12 end
    return minY, maxY
end


local ENEMY_SIZE_BOOST = 2.25

function drawCompositeSprite(sprite)
    local correctedDistance = math.max(1, sprite.correctedDistance or (sprite.distance * math.cos(sprite.angle)))
    local rawD = math.max(24, sprite.distance or correctedDistance)
    local screenX = sprite.screenX or ((sprite.angle + FOV / 2) / FOV * baseWidth)
    local highlight = sprite.highlight
    local enemy = sprite.reference
    local hitFlash = enemy and enemy.hitFlash or 0
    local profile = enemyVisualProfile(sprite.type)

    local distanceFade = 1 - smoothstep(maxRenderDistance * 0.80, maxRenderDistance, correctedDistance)
    local edgeFade = 1 - smoothstep(FOV * 0.40, FOV * 0.50, math.abs(sprite.angle or 0))
    local alpha = clamp(0.18 + distanceFade * edgeFade * 0.82, 0, 1)
    if alpha <= 0.03 then return end

    -- v9: строго монотонный размер. Чем меньше rawD, тем ближе nearT к 1, тем крупнее враг.
    -- Это убирает эффект "приблизился — враг уменьшился" из-за смешивания corrected/raw дистанций.
    local nearT = 1 - clamp((rawD - 26) / (maxRenderDistance - 26), 0, 1)
    nearT = nearT ^ 1.35
    local projected = profile.minSize + (profile.maxSize - profile.minSize) * nearT
    -- v10: враги намеренно увеличены примерно в 2.25 раза.
    -- Масштаб всё ещё монотонный: далеко маленький силуэт, вблизи крупная модель.
    projected = projected * profile.mass * ENEMY_SIZE_BOOST
    projected = clamp(projected, profile.minSize * ENEMY_SIZE_BOOST, math.min(profile.maxSize * ENEMY_SIZE_BOOST, 560))

    local minLocalY, maxLocalY = enemyLocalBounds(sprite.parts)
    local localHeight = math.max(18, maxLocalY - minLocalY)
    local scaleFactor = projected / localHeight
    local floorY = baseHeight / 2 + (baseHeight / math.max(26, correctedDistance)) * 25
    floorY = clamp(floorY, baseHeight / 2 + 16, baseHeight - 16)

    -- Привязка модели к полу через нижнюю границу силуэта + небольшой подъём.
    -- Тень остаётся на полу, сама модель стоит выше и не выглядит прибитой к земле.
    local groundGap = projected * 0.13
    local modelBaseY = floorY - maxLocalY * scaleFactor - groundGap
    local light = clamp(applyLighting(correctedDistance) + (highlight and 0.12 or 0), 0.15, 1.0)

    -- Дальний LOD: маркер тоже сидит на полу, но визуально чуть приподнят.
    if correctedDistance > profile.lod then
        local marker = enemyMarkerFor(sprite.type)
        local size = clamp(projected * 0.72, 12, 34)
        love.graphics.setFont(titleFont or defaultFont)
        love.graphics.setColor(0, 0, 0, alpha * 0.55)
        love.graphics.ellipse("fill", screenX, floorY + 2, size * 0.66, size * 0.18)
        love.graphics.setColor(0, 0, 0, alpha * 0.86)
        love.graphics.printf(marker, screenX - size, floorY - size * 1.20, size * 2, "center")
        love.graphics.setColor(1 * light, 0.30 * light, 0.24 * light, alpha)
        love.graphics.printf(marker, screenX - size, floorY - size * 1.32, size * 2, "center")
        love.graphics.setFont(defaultFont)
        return
    end

    -- Контактная тень отдельно от модели, чтобы враг читался как объект в пространстве.
    love.graphics.setColor(0, 0, 0, alpha * clamp(profile.shadow - correctedDistance / 760, 0.18, profile.shadow))
    love.graphics.ellipse("fill", screenX, floorY + 2, projected * 0.40, math.max(3, projected * 0.065))
    drawEnemyGroundAura(screenX, floorY, projected, light, alpha, hitFlash)

    local breathe = 1 + math.sin(love.timer.getTime() * ((enemy and enemy.speed or 50) / 28)) * 0.035
    for _, part in ipairs(sprite.parts) do
        local px = screenX + part.offsetX * scaleFactor
        local py = modelBaseY + part.offsetY * scaleFactor * breathe

        -- Более плотная обводка: враги меньше сливаются со стеной, но не превращаются в UI-плашку.
        love.graphics.setColor(0, 0, 0, alpha * 0.82)
        drawEnemyPartShape(part, px, py, scaleFactor, true)
        setEnemyPartColor(part, light, alpha, hitFlash)
        drawEnemyPartShape(part, px, py, scaleFactor, false)

        if highlight then
            love.graphics.setColor(1, 0.08, 0.06, alpha * 0.85)
            love.graphics.setLineWidth(1.4)
            if part.shape == "circle" then
                love.graphics.circle("line", px, py, math.max(1, part.radius * scaleFactor + 1.5))
            elseif part.shape == "rectangle" then
                love.graphics.rectangle("line", px - (part.width/2) * scaleFactor, py - (part.height/2) * scaleFactor, part.width * scaleFactor, part.height * scaleFactor)
            elseif part.shape == "triangle" then
                local hw = (part.width or 8) * scaleFactor * 0.5
                local hh = (part.height or 8) * scaleFactor * 0.5
                love.graphics.polygon("line", px, py - hh, px - hw, py + hh, px + hw, py + hh)
            elseif part.shape == "line" then
                love.graphics.setColor(1, 0.08, 0.06, alpha * 0.52)
                drawEnemyPartShape(part, px, py, scaleFactor, false)
            end
            love.graphics.setLineWidth(1)
        end
    end

    if highlight and enemy then
        local name = enemy.name or "???"
        local maxHealth = enemy.maxHealth or 100
        local health = math.max(0, math.min(enemy.health or 0, maxHealth))
        local hpPercent = health / maxHealth
        local barWidth = clamp(projected * 0.95, 70, 130)
        local barHeight = 9
        local barX = screenX - barWidth / 2
        local barY = modelBaseY - projected - 26

        love.graphics.setFont(smallFont or defaultFont)
        love.graphics.setColor(0, 0, 0, 0.68)
        love.graphics.rectangle("fill", barX - 4, barY - 19, barWidth + 8, 33, 5, 5)
        love.graphics.setColor(1, 1, 1, 0.95)
        love.graphics.printf(name, barX, barY - 17, barWidth, "center")
        love.graphics.setColor(0.08, 0.08, 0.08, 0.92)
        love.graphics.rectangle("fill", barX, barY, barWidth, barHeight)
        love.graphics.setColor(1 - hpPercent, hpPercent, 0.08, 0.95)
        love.graphics.rectangle("fill", barX, barY, barWidth * hpPercent, barHeight)
        love.graphics.setColor(1, 1, 1, 0.85)
        love.graphics.rectangle("line", barX, barY, barWidth, barHeight)
        love.graphics.setFont(defaultFont)
    end
end

-- Проверка видимости спрайта через уже рассчитанную глубину стен.
function isSpriteVisible(sprite)
    local idx = sprite.rayIndex or 1
    local wallDepth = wallDistances[idx] and wallDistances[idx].distance or math.huge
    local d = sprite.correctedDistance or sprite.distance or math.huge
    return d < wallDepth - 2
end

local function noise(x, y)
    return love.math.noise(x * 0.1, y * 0.1)
end

local function stableNoise(x, y, salt)
    return love.math.noise((math.floor(x) + (salt or 0)) * 0.073, math.floor(y) * 0.091)
end

local function wallSeed(rayData, salt)
    local mx = rayData and rayData.hitMapX or 0
    local my = rayData and rayData.hitMapY or 0
    return stableNoise(mx * 17 + (rayData and rayData.wallU or 0) * 64, my * 19, salt or 0)
end

local function wallShadeColor(baseColor, factor, alpha)
    love.graphics.setColor(baseColor[1] / 255 * factor, baseColor[2] / 255 * factor, baseColor[3] / 255 * factor, alpha or 1)
end


local wallAsciiGlyphs = {
    stone = {"#", "%", "#", "+", "*", ":", "."},
    tile = {"#", "=", "+", "#", ":", "."},
    flesh = {"w", "v", "o", "~", ":", "."},
    circuit = {"0", "1", "+", "-", "|", ":", "."}
}

local function pickWallGlyph(style, rayData, row, col)
    local set = wallAsciiGlyphs[style] or wallAsciiGlyphs.stone
    local salt = 900 + row * 41 + ((col or 0) * 23) + ((rayData and rayData.hitMapX or 0) * 5)
    local n = wallSeed(rayData, salt)
    -- v13: больше плотных символов на ближней/средней дистанции, меньше пустых точек.
    local idx = clamp(math.floor(n * #set) + 1, 1, #set)
    return set[idx], n
end

local function drawAsciiWallSymbols(x, y, width, height, baseColor, rayData, style, alphaMul)
    if height < 9 or not rayData then return end

    local dist = rayData.distance or 180
    local sideDark = rayData.hitSide == 1 and 0.82 or 1.0
    local distLight = clamp(1 - dist / maxRenderDistance, 0.22, 1.0)

    -- Грид символов: достаточно плотный, чтобы стена читалась как поверхность,
    -- но без графических заливок/линий.
    local cellW = dist < 80 and 7 or (dist < 170 and 8 or 9)
    local cellH = dist < 80 and 10 or (dist < 170 and 11 or 12)
    local sliceW = math.max(1, width)
    local stepRays = math.max(1, math.floor(cellW / sliceW))
    local rayIndex = rayData.rayIndex or 1
    if (rayIndex - 1) % stepRays ~= 0 then return end

    local groupIndex = math.floor((rayIndex - 1) / stepRays)
    local left = x + (sliceW * stepRays - cellW) * 0.5
    local top = math.max(y, math.ceil(y / cellH) * cellH)
    local bottom = y + height - cellH * 0.55

    local br, bg, bb = baseColor[1] / 255, baseColor[2] / 255, baseColor[3] / 255
    local light = sideDark * (0.70 + distLight * 0.62)
    local baseAlpha = clamp((0.50 + distLight * 0.46) * (alphaMul or 1.0), 0.40, 0.98)

    love.graphics.setFont(wallFont or smallFont or defaultFont)
    for yy = top, bottom, cellH do
        local row = math.floor((yy - y) / cellH)
        local glyph, seed = pickWallGlyph(style, rayData, row, groupIndex)

        -- Вдали чуть прореживаем только самые слабые точки, иначе снова получаем стену-призрак.
        if not (dist > 255 and seed < 0.18) then
            local jitterY = (wallSeed(rayData, 1200 + row * 13 + groupIndex * 7) - 0.5) * 0.55
            local a = baseAlpha * (0.96 - math.min(row * 0.003, 0.20))

            -- Текстовая тень, а не заливка: отделяет символы от пола/потолка.
            love.graphics.setColor(0, 0, 0, a * 0.62)
            love.graphics.print(glyph, left + 1, yy + 1 + jitterY)

            -- Основной символ.
            local rr = clamp(br * light * 1.72, 0, 1)
            local gg = clamp(bg * light * 1.72, 0, 1)
            local bb2 = clamp(bb * light * 1.72, 0, 1)
            love.graphics.setColor(rr, gg, bb2, a)
            love.graphics.print(glyph, left, yy + jitterY)
        end
    end
    love.graphics.setFont(defaultFont)
end

local function textureV(y, top, height, steps)
    if height <= 0 then return 0 end
    return math.floor(((y - top) / height) * (steps or 64))
end

local function drawWallDepthTint(x, y, width, height, baseColor, rayData, baseFactor)
    local sideDark = rayData and rayData.hitSide == 1 and 0.86 or 1.0
    local d = rayData and rayData.distance or 120
    local fog = clamp(1 - d / maxRenderDistance, 0.18, 1.0)
    wallShadeColor(baseColor, (baseFactor or 0.55) * sideDark * (0.72 + fog * 0.36))
    love.graphics.rectangle("fill", x, y, width, height)
    return sideDark, fog
end

local function drawVerticalTextureSeam(x, y, width, height, u, alpha)
    local seam = math.abs((u * 8) - math.floor(u * 8) - 0.5)
    if seam < 0.035 then
        love.graphics.setColor(0, 0, 0, alpha or 0.25)
        love.graphics.rectangle("fill", x, y, math.max(1, width), height)
    end
end

function drawWallBrokenStone(x, y, width, height, baseColor, rayData)
    -- v10: стены рисуются только текстовыми ASCII-глифами, без графических заливок, линий и плиточных прямоугольников.
    drawAsciiWallSymbols(x, y, width, height, baseColor, rayData, "stone", 1.05)
end

function drawWallAncientTiles(x, y, width, height, baseColor, rayData)
    -- v10: чистый ASCII-паттерн, чтобы стена не выглядела как обычная залитая поверхность.
    drawAsciiWallSymbols(x, y, width, height, baseColor, rayData, "tile", 1.08)
end

function drawWallFleshWall(x, y, width, height, baseColor, rayData)
    -- v10: органика теперь тоже только символами.
    drawAsciiWallSymbols(x, y, width, height, baseColor, rayData, "flesh", 1.04)
end

function drawWallVoidCircuit(x, y, width, height, baseColor, rayData)
    -- v10: circuit-wall без линий, только 0/1/+/-/|/= символы.
    drawAsciiWallSymbols(x, y, width, height, baseColor, rayData, "circuit", 1.10)
end

-- Определение стен
local wallRenderers = {
    ['1'] = drawWallBrokenStone,
    ['2'] = drawWallAncientTiles,
    ['3'] = drawWallFleshWall,
    ['4'] = drawWallVoidCircuit
}


function renderScene()
    love.graphics.setFont(defaultFont)

    drawCeiling()
	drawFloor()

    -- Стены
    for i = 1, numRays do
	
        local rayData = wallDistances[i]
        if rayData and rayData.wallType ~= '0' and rayData.wallType ~= "sprite" then
            local correctedDistance = rayData.distance
            local wallInfo = getWallInfo(rayData.wallType)
            local color = wallInfo.color
            

            local lightFactor = applyLighting(correctedDistance)
            love.graphics.setColor(
                color[1] * lightFactor / 255,
                color[2] * lightFactor / 255,
                color[3] * lightFactor / 255,
                1
            )

            local baseWallHeight = 50
local wallHeightScaled = (baseHeight / correctedDistance) * baseWallHeight

            local xPosition = (i - 1) * (baseWidth / numRays)
            local wallTop = baseHeight / 2 - wallHeightScaled / 2
            local sliceWidth = baseWidth / numRays

local renderer = wallRenderers[tostring(rayData.wallType)]
if renderer then
    renderer(xPosition, wallTop, sliceWidth, wallHeightScaled, wallInfo.color, rayData)
else
    love.graphics.rectangle("fill", xPosition, wallTop, sliceWidth, wallHeightScaled)
end




			
			-- 👉 Рисуем градиентную тень под стеной
local shadowSteps = 2 -- v13: почти незаметная тень, чтобы не получалась черная полоса
local baseShadowAlpha = math.max(0, 42 - correctedDistance / 8) / 255

for s = 1, shadowSteps do
    local alphaFactor = (1 - (s - 1) / shadowSteps) * baseShadowAlpha
    love.graphics.setColor(0, 0, 0, alphaFactor)
    love.graphics.rectangle(
        "fill",
        xPosition,
        wallTop + wallHeightScaled + (s - 1) * 2,
        sliceWidth,
        2
    )
end

        end
    end
	
	table.sort(visibleSprites, function(a, b)
    return a.distance > b.distance
end)


    -- Спрайты (объекты и враги)
    for _, sprite in ipairs(visibleSprites) do
        if sprite.kind == "object" then
            drawObjectSprite(sprite)
        else
            drawCompositeSprite(sprite)
        end
    end

    drawFloatingTexts()
    if showDepthOverlay then drawDepthOverlay() end
    if showSpriteOverlay then drawSpriteDebugOverlay() end
end



-- Спавн врагов
function spawnEnemies()
    enemies = {}
    enemiesKilledThisDepth = 0
    local depth = currentDepth or 1
    local playerLevel = Player and Player.level or 1
    local count = math.min((Balance.spawn.baseEnemies or 7) + math.floor(depth * (Balance.spawn.depthEnemies or 1.45)) + math.floor(playerLevel * (Balance.spawn.levelEnemies or 0.35)), Balance.spawn.maxEnemies or 28)
    if depth % (Balance.spawn.bossEvery or 5) == 0 then count = math.max(1, count - 2) end

    for i = 1, count do
        local c = randomWalkableCell(190)
        local x, y = c.x, c.y
        local biome = biomeMap and biomeMap[y] and biomeMap[y][x] or getBiomeForCell(x, y)
        local possible = {}
        for name, data in pairs(enemyTypes) do
            if data.locations and tableContains(data.locations, biome) and name ~= "boss" then table.insert(possible, name) end
        end
        if #possible == 0 then possible = {"slime"} end
        local enemyName = possible[love.math.random(1, #possible)]
        if depth % (Balance.spawn.bossEvery or 5) == 0 and i == 1 then enemyName = "boss" end
        local template = enemyTypes[enemyName] or enemyTypes.slime
        local role = Balance.enemyRoles[enemyName] or Balance.enemyRoles.default
        local enemyLevel = math.max(1, depth + math.floor(playerLevel * 0.35) + love.math.random(-1, 2))
        local diff = 1 + (enemyLevel - 1) * (Balance.enemyScaling.levelHp or 0.15) + (depth - 1) * (Balance.enemyScaling.depthHp or 0.06)
        local health = math.floor((template.health or 25) * diff * (role.hpMul or 1))
        local strength = math.floor((template.strength or 5) * (0.85 + diff * (Balance.enemyScaling.damageMul or 0.65)) * (role.damageMul or 1))
        local defense = math.floor(((template.defense or 0) + enemyLevel * 0.45 + depth * 0.15) * (role.defenseMul or 1))
        local speed = (template.speed or 45) * clamp(1 + (enemyLevel - playerLevel) * 0.025, 0.85, 1.22) * (role.speedMul or 1)
        table.insert(enemies, {
            x = (x + 0.5) * TILE_SIZE, y = (y + 0.5) * TILE_SIZE,
            type = enemyName, location = biome, name = enemyName, level = enemyLevel,
            maxHealth = health, health = health, speed = speed, strength = strength, defense = defense,
            role = role, roleName = role.name or enemyName, orbitSide = love.math.random() < 0.5 and -1 or 1,
            attackSpeed = clamp((template.attackSpeed or 0.9) + enemyLevel * 0.015, 0.35, 2.4),
            attackRange = role.meleeRange or template.attackRange or 15,
            rangedAttackRange = role.attackRange or 160,
            preferredRange = role.preferredRange or template.attackRange or 18,
            aggroRange = (role.aggroRange or 175) + enemyLevel * 5,
            radius = template.radius or 8, dropChance = template.dropChance or 0.2,
            critChance = clamp((role.critBase or 0.02) + enemyLevel * 0.003, 0, 0.24), critMultiplier = role.critMultiplier or 1.35,
            dodge = role.dodge or (enemyName == "slime" and 0.08 or enemyName == "goblin" and 0.06 or 0.02),
            xpValue = math.floor(12 + enemyLevel * 8 + health * 0.12 + strength * 1.4),
            spriteTemplate = enemySprites[enemyName], hitFlash = 0, stagger = 0, vx = 0, vy = 0
        })
    end
end

function spawnInteractiveObjects()
    interactiveObjects = {}

    local function addObject(kind, cell, label, color)
        table.insert(interactiveObjects, {
            kind = kind,
            x = (cell.x + 0.5) * TILE_SIZE,
            y = (cell.y + 0.5) * TILE_SIZE,
            cellX = cell.x,
            cellY = cell.y,
            label = label,
            color = color,
            state = kind == "chest" and "closed" or "idle",
            radius = 12,
            interactRadius = 52,
            used = false
        })
    end

    local chestCount = math.min(3 + math.floor(currentDepth / 2), 8)
    for _ = 1, chestCount do
        local c = randomWalkableCell(160)
        addObject("chest", c, "СУНДУК", {1.0, 0.78, 0.25})
    end

    local altarCell = randomWalkableCell(220)
    addObject("altar", altarCell, "АЛТАРЬ", {0.45, 0.85, 1.0})

    if exitCell then
        addObject("exit", exitCell, "ВЫХОД", {0.35, 1.0, 0.55})
    end
end

function getNearestInteractiveObject()
    local best, bestDist = nil, math.huge
    for _, obj in ipairs(interactiveObjects) do
        if not obj.hidden then
            local dx, dy = obj.x - Player.x, obj.y - Player.y
            local d = math.sqrt(dx * dx + dy * dy)
            if d < (obj.interactRadius or 50) and d < bestDist then
                best, bestDist = obj, d
            end
        end
    end
    return best, bestDist
end

function interactWithObject(obj)
    if not obj then return false end

    if obj.kind == "chest" then
        if obj.state == "opened" then
            inventoryMessage = "Сундук уже пуст"
            inventoryMessageTimer = 1.5
            return true
        end
        obj.state = "opened"
        obj.label = "ПУСТО"
        if runStats then runStats.chestsOpened = (runStats.chestsOpened or 0) + 1 end
        local item = LootGenerator.generateCombatItem({
            location = getBiomeForCell(obj.cellX, obj.cellY),
            enemyType = "skeleton",
            difficulty = getDifficultyMultiplier() + currentDepth * 0.15,
            playerLuck = Player.stats.luck,
            itemLevel = math.max(1, (Player.level or 1) + math.floor((currentDepth or 1) * 0.6)),
            depth = currentDepth or 1,
            playerLevel = Player.level or 1,
            playerStats = { lowHP = Player.health < Player.stats.maxHealth * 0.3 }
        })
        addInventoryItem(item, "Сундук: ")
        addFloatingText(obj.x, obj.y, "+loot", {1, 0.85, 0.2})
        SFXGenerator:generate({layers={{waveform={"triangle","sine"}, frequency={440,660}, duration={0.08,0.14}, volume={0.35,0.55}, effects={bitcrush=0.1}}}})
        return true
    elseif obj.kind == "altar" then
        if obj.used then
            inventoryMessage = "Алтарь уже молчит"
            inventoryMessageTimer = 1.5
            return true
        end
        obj.used = true
        obj.label = "ТИШИНА"
        if runStats then runStats.altarsUsed = (runStats.altarsUsed or 0) + 1 end
        local effect = rollAltarEffect(obj)
        applyAltarEffect(effect, obj)
        SFXGenerator:generate({layers={{waveform={"sine","triangle"}, frequency={280,620}, duration={0.18,0.32}, volume={0.35,0.55}, effects={tremolo=0.18, vibrato=3}}}})
        return true
    elseif obj.kind == "exit" then
        advanceToNextDepth()
        return true
    end

    return false
end


function rollAltarEffect(obj)
    local hpPct = (Player.health or 0) / math.max(1, Player.stats.maxHealth or 100)
    local roll = love.math.random()
    if hpPct < 0.35 and roll < 0.55 then return "heal" end
    if roll < 0.32 then return "blood_loot" end
    if roll < 0.56 then return "blessing" end
    if roll < 0.78 then return "trial" end
    return "xp_bargain"
end

function applyAltarEffect(effect, obj)
    Player.baseStats = Player.baseStats or Player.stats
    local maxHp = Player.stats.maxHealth or 100
    if effect == "heal" then
        local heal = math.floor(maxHp * 0.48)
        Player.health = math.min(maxHp, Player.health + heal)
        inventoryMessage = "Алтарь: +" .. heal .. " HP"
        addFloatingText(obj.x, obj.y, "+" .. heal .. " HP", {0.5, 1, 1})
    elseif effect == "blood_loot" then
        local cost = math.max(1, math.floor(maxHp * 0.18))
        Player.health = math.max(1, Player.health - cost)
        recordDamageTaken(cost)
        local item = LootGenerator.generateCombatItem({
            location = getBiomeForCell(obj.cellX, obj.cellY), enemyType = "boss",
            difficulty = getDifficultyMultiplier() + 0.75, playerLuck = (Player.stats.luck or 0) + 0.35,
            itemLevel = math.max(1, (Player.level or 1) + (currentDepth or 1) + 1),
            depth = currentDepth or 1, playerLevel = Player.level or 1
        })
        addInventoryItem(item, "Кровавый дар: ")
        inventoryMessage = "Алтарь взял " .. cost .. " HP и дал предмет"
        addFloatingText(obj.x, obj.y, "-" .. cost .. " HP / +loot", {1, 0.45, 0.45})
    elseif effect == "blessing" then
        local pool = Balance.altarBlessings or {{stat="damage", value=1}}
        local b = pool[love.math.random(1, #pool)]
        Player.baseStats[b.stat] = (Player.baseStats[b.stat] or 0) + b.value
        recalculatePlayerStats()
        inventoryMessage = "Благословение: " .. statLabel(b.stat) .. " " .. formatStatValue(b.stat, b.value)
        addFloatingText(obj.x, obj.y, "+" .. statLabel(b.stat), {0.55, 1, 0.65})
    elseif effect == "trial" then
        local spawned = 0
        for _ = 1, 2 + math.floor((currentDepth or 1) / 3) do
            local c = randomWalkableCell(120)
            local biome = biomeMap and biomeMap[c.y] and biomeMap[c.y][c.x] or getBiomeForCell(c.x, c.y)
            local enemyName = love.math.random() < 0.5 and "goblin" or "skeleton"
            local template = enemyTypes[enemyName] or enemyTypes.skeleton
            local role = Balance.enemyRoles[enemyName] or Balance.enemyRoles.default
            local lvl = math.max(1, (Player.level or 1) + math.floor((currentDepth or 1) * 0.5))
            local hp = math.floor((template.health or 30) * (1 + lvl * 0.12))
            table.insert(enemies, {
                x=(c.x+0.5)*TILE_SIZE, y=(c.y+0.5)*TILE_SIZE, type=enemyName, location=biome, name=enemyName,
                level=lvl, maxHealth=hp, health=hp, speed=(template.speed or 50)*(role.speedMul or 1), strength=(template.strength or 6)+lvl,
                defense=(template.defense or 1)+math.floor(lvl*0.4), role=role, roleName=role.name or enemyName, orbitSide=love.math.random()<0.5 and -1 or 1,
                attackSpeed=template.attackSpeed or 1, attackRange=role.meleeRange or 15, rangedAttackRange=role.attackRange or 160,
                preferredRange=role.preferredRange or 18, aggroRange=260, radius=template.radius or 8, dropChance=(template.dropChance or 0.2)+0.15,
                critChance=0.04, critMultiplier=1.35, dodge=role.dodge or 0.02, xpValue=math.floor(16+lvl*9), spriteTemplate=enemySprites[enemyName], hitFlash=0, stagger=0, vx=0, vy=0
            })
            spawned = spawned + 1
        end
        inventoryMessage = "Испытание алтаря: врагов " .. spawned
        addFloatingText(obj.x, obj.y, "TRIAL", {1, 0.75, 0.25})
    elseif effect == "xp_bargain" then
        local xp = math.floor((Player.experienceToNextLevel or 100) * 0.34)
        gainExperience(xp)
        inventoryMessage = "Алтарь дал опыт: +" .. xp
        addFloatingText(obj.x, obj.y, "+" .. xp .. " XP", {0.65, 1, 0.65})
    end
    inventoryMessageTimer = 2.6
end

function handleInteractOrWall()
    local obj = getNearestInteractiveObject()
    if obj and interactWithObject(obj) then return end

    local rayAngle = Player.angle
    local attackRange = 90
    local distance, wallType, hitX, hitY = raycast(Player.x, Player.y, rayAngle)
    if wallType ~= '0' and distance < attackRange then
        destroyWall(hitX + math.cos(rayAngle), hitY + math.sin(rayAngle))
        inventoryMessage = "Стена разрушена"
        inventoryMessageTimer = 1
    end
end

function advanceToNextDepth()
    local old = Player
    if runStats then
        runStats.depthsCleared = (runStats.depthsCleared or 0) + 1
    end
    currentDepth = currentDepth + 1
    if runStats then runStats.maxDepth = math.max(runStats.maxDepth or 1, currentDepth) end
    gameDifficulty = 1 + (currentDepth - 1) * 0.18
    currentSeed = os.time() + love.math.random(1, 100000) + currentDepth * 1000
    love.math.setRandomSeed(currentSeed)

    map = generateDungeon()
    assignBiomesToMap()
    local c = spawnCell or randomWalkableCell(0)
    Player = old
    Player.x = (c.x + 0.5) * TILE_SIZE
    Player.y = (c.y + 0.5) * TILE_SIZE
    Player.angle = math.pi / 2
    Player.health = math.min(Player.stats.maxHealth or 100, Player.health + math.floor((Player.stats.maxHealth or 100) * 0.2))
    spawnEnemies()
    spawnInteractiveObjects()
    floatingTexts = {}
    inventoryMessage = "Глубина " .. currentDepth
    inventoryMessageTimer = 2.5
end

function restartCurrentRun()
    initGame()
end

function addFloatingText(x, y, text, color)
    table.insert(floatingTexts, {
        x = x,
        y = y,
        text = text,
        color = color or {1, 1, 1},
        life = 0.9,
        maxLife = 0.9,
        vy = -28
    })
end

function updateFloatingTexts(dt)
damageFlash = math.max(0, damageFlash - dt * 2.5)
    for i = #floatingTexts, 1, -1 do
        local f = floatingTexts[i]
        f.life = f.life - dt
        f.y = f.y + f.vy * dt
        if f.life <= 0 then table.remove(floatingTexts, i) end
    end
end

function drawFloatingTexts()
    love.graphics.setFont(smallFont or defaultFont)
    for _, f in ipairs(floatingTexts) do
        local dx, dy = f.x - Player.x, f.y - Player.y
        local dist = math.sqrt(dx * dx + dy * dy)
        if dist > 0 and dist < maxRenderDistance then
            local angle = math.atan2(dy, dx) - Player.angle
            while angle > math.pi do angle = angle - 2 * math.pi end
            while angle < -math.pi do angle = angle + 2 * math.pi end
            if math.abs(angle) < FOV / 2 then
                local sx = (angle + FOV / 2) / FOV * baseWidth
                local sy = baseHeight / 2 - (baseHeight / math.max(1, dist)) * 34
                local alpha = math.max(0, f.life / f.maxLife)
                love.graphics.setColor(f.color[1], f.color[2], f.color[3], alpha)
                love.graphics.printf(f.text, sx - 60, sy, 120, "center")
            end
        end
    end
    love.graphics.setFont(defaultFont)
end


-- Загрузка звуков
function loadSounds()
    if love.filesystem.getInfo("sounds/collect.mp3") then
        sounds.collect = love.audio.newSource("sounds/collect.mp3", "static")
    end
    if love.filesystem.getInfo("sounds/attack.mp3") then
        sounds.attack = love.audio.newSource("sounds/attack.mp3", "static")
    end
    if love.filesystem.getInfo("sounds/enemy_death.mp3") then
        sounds.enemyDeath = love.audio.newSource("sounds/enemy_death.mp3", "static")
    end
    if love.filesystem.getInfo("sounds/game_over.mp3") then
        sounds.gameOver = love.audio.newSource("sounds/game_over.mp3", "static")
    end
end

-- Загрузка музыки
function loadMusic()
    if love.filesystem.getInfo("sounds/background_music.mp3") then
        music = love.audio.newSource("sounds/background_music.mp3", "stream")
    end
end

function drawHUD()
    love.graphics.setFont(uiFont or defaultFont)
    local gridX = toCell(Player.x)
    local gridY = toCell(Player.y)
    local biome = getBiomeForCell(gridX, gridY)

    -- Top terminal location tag
    local biomeText = "Глубина " .. tostring(currentDepth) .. "  |  " .. tostring(biome)
    local font = uiFont or defaultFont
    local pillW = math.min(360, font:getWidth(biomeText) + 48)
    local pillX = baseWidth / 2 - pillW / 2
    uiPanel(pillX, 10, pillW, 30, "", UI.strokeSoft)
    uiPrintf(biomeText, pillX, 18, pillW, "center", UI.text, uiFont or defaultFont)

    local hpPct = clamp((Player.health or 0) / math.max(1, Player.stats.maxHealth or 100), 0, 1)
    local xpPct = clamp((Player.experience or 0) / math.max(1, Player.experienceToNextLevel or 100), 0, 1)
    local cd = 1
    if Player.lastAttackTime then
        local delay = 1 / math.max(0.01, Player.stats.attackSpeed or 1)
        cd = clamp((love.timer.getTime() - Player.lastAttackTime) / delay, 0, 1)
    end

    -- Left compact status panel
    local cardX, cardY = 12, baseHeight - 126
    local cardW, cardH = 380, 104
    uiPanel(cardX, cardY, cardW, cardH, "STATUS", UI.good)
    uiText("LV " .. tostring(Player.level or 1), cardX + 18, cardY + 35, UI.warn, uiLargeFont or uiFont)
    uiBar(cardX + 84, cardY + 35, 270, 14, hpPct, UI.good, UI.panel, string.format("HP %d/%d", Player.health or 0, Player.stats.maxHealth or 100), UI.text)
    uiBar(cardX + 84, cardY + 56, 270, 12, xpPct, UI.accent2, UI.panel, string.format("XP %d/%d", Player.experience or 0, Player.experienceToNextLevel or 100), UI.text)
    uiText(string.format("DMG %.0f | ARM %.0f | AS %.2f | CR %.0f%%", Player.stats.damage or 0, Player.stats.armor or 0, Player.stats.attackSpeed or 0, (Player.stats.critChance or 0) * 100), cardX + 18, cardY + 80, UI.muted, smallFont or defaultFont)
    uiText("ATK", cardX + 274, cardY + 80, UI.faint, smallFont or defaultFont)
    uiBar(cardX + 306, cardY + 78, 54, 8, cd, UI.bad, UI.panel, nil)

    if lastCombatEvent ~= "" then
        local w = 520
        uiPanel(12, cardY - 38, w, 30, "LOG", UI.strokeSoft)
        uiPrintf(uiTruncate(lastCombatEvent, smallFont or defaultFont, w - 28), 26, cardY - 29, w - 28, "left", UI.text, smallFont or defaultFont, 0.84)
    end

    uiPrintf(string.format("RUN %s | KILLS %d | LOOT %d", formatTime(runElapsed()), runStats.enemiesKilled or 0, runStats.itemsFound or 0), 12, cardY - 62, 360, "left", UI.faint, smallFont or defaultFont, 0.82)

    -- Right equipment panel
    local equipW, equipH = 338, 118
    local equipX, equipY = baseWidth - equipW - 12, baseHeight - equipH - 44
    uiPanel(equipX, equipY, equipW, equipH, "EQUIPPED", UI.warn)
    local ey = equipY + 34
    local weaponName = Player.equipped.weapon and (Player.equipped.weapon.name or Player.equipped.weapon.displayName) or "-"
    uiText("WEAPON", equipX + 16, ey, UI.muted, smallFont or defaultFont)
    uiPrintf(uiTruncate(weaponName, smallFont or defaultFont, equipW - 104), equipX + 92, ey, equipW - 104, "left", UI.text, smallFont or defaultFont)
    ey = ey + 20
    local slots = {"head", "torso", "legs"}
    for _, slot in ipairs(slots) do
        local item = Player.equipped.armor and Player.equipped.armor[slot]
        uiText(string.upper(uiEquipSlotLabel(slot)), equipX + 16, ey, UI.muted, smallFont or defaultFont)
        uiPrintf(uiTruncate(item and (item.name or item.displayName) or "-", smallFont or defaultFont, equipW - 104), equipX + 92, ey, equipW - 104, "left", item and UI.text or UI.faint, smallFont or defaultFont)
        ey = ey + 18
    end

    -- Controls strip, clamped to bottom
    local controls = "WASD move | SPACE attack | E object/wall | I inventory | L test-loot | F4 map | F5 restart"
    uiAsciiRule(10, baseHeight - 22, baseWidth - 20, UI.strokeSoft, 0.35)
    uiPrintf(controls, 12, baseHeight - 16, baseWidth - 24, "left", UI.muted, smallFont or defaultFont, 0.82)

    if objectInteractHint ~= "" then
        local hintW = math.min(560, (uiFont or defaultFont):getWidth(objectInteractHint) + 54)
        local hintX = baseWidth / 2 - hintW / 2
        local hintY = baseHeight / 2 + 76
        uiPanel(hintX, hintY, hintW, 34, "E", UI.warn)
        uiPrintf(objectInteractHint, hintX, hintY + 10, hintW, "center", UI.warn, uiFont or defaultFont)
    end

    love.graphics.setFont(defaultFont)
end


function drawCeiling()
    local gx, gy = getPlayerCell()
    local biome = getBiomeForCell(gx, gy)
    local bg = backgroundCanvases[biome] or backgroundCanvases.dungeon
    if bg and bg.ceiling then
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.draw(bg.ceiling, 0, 0)
        -- Мягкая дымка у горизонта, чтобы стены не висели в пустоте.
        love.graphics.setColor(0.10, 0.11, 0.14, 0.18)
        love.graphics.rectangle("fill", 0, baseHeight / 2 - 26, baseWidth, 26)
    end
end

function drawFloor()
    local gx, gy = getPlayerCell()
    local biome = getBiomeForCell(gx, gy)
    local bg = backgroundCanvases[biome] or backgroundCanvases.dungeon
    if bg and bg.floor then
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.draw(bg.floor, 0, baseHeight / 2)
        love.graphics.setColor(0, 0, 0, 0.10)
        love.graphics.rectangle("fill", 0, baseHeight / 2, baseWidth, 18)
    end
end




function drawAnsiBlock(block, x, y)
    local lineHeight = 16 -- Высота строки, зависит от шрифта!

    for i, line in ipairs(block) do
        love.graphics.setColor(
            line.color[1]/255,
            line.color[2]/255,
            line.color[3]/255
        )
        love.graphics.print(line.text, x, y + (i-1) * lineHeight)
    end

    love.graphics.setColor(1, 1, 1) -- Сброс цвета
end

function useInventoryItem(index)
    local item = Player.inventory[index]
    if not item then return end
    performInventoryAction("Одеть", item, index)
end

function recalculatePlayerStats()
    local sourceBase = Player.baseStats or {
        maxHealth = 100, damage = 10, armor = 5, attackSpeed = 1.0,
        critChance = 0.1, critMultiplier = 1.5, range = 2.5,
        luck = 0.2, speed = 0, dodge = 0.03
    }
    local baseStats = {}
    for stat, value in pairs(sourceBase) do baseStats[stat] = value end
    local function addStats(item)
        if item and item.stats then
            for stat, value in pairs(item.stats) do addStatValue(baseStats, stat, value) end
        end
    end
    addStats(Player.equipped.weapon)
    for _, armor in pairs(Player.equipped.armor or {}) do addStats(armor) end
    baseStats.maxHealth = math.max(1, baseStats.maxHealth or 100)
    baseStats.damage = math.max(1, baseStats.damage or 1)
    baseStats.armor = math.max(0, baseStats.armor or 0)
    baseStats.attackSpeed = clamp(baseStats.attackSpeed or 1, 0.25, 4.0)
    baseStats.critChance = clamp(baseStats.critChance or 0, 0, 0.75)
    baseStats.critMultiplier = clamp(baseStats.critMultiplier or 1.5, 1, 4.0)
    baseStats.range = clamp(baseStats.range or 2.5, 0.7, 7.0)
    baseStats.luck = clamp(baseStats.luck or 0, -0.5, 1.5)
    baseStats.speed = clamp(baseStats.speed or 0, -90, 140)
    baseStats.dodge = clamp(baseStats.dodge or 0, 0, 0.45)
    local oldMax = Player.stats and Player.stats.maxHealth or baseStats.maxHealth
    local delta = baseStats.maxHealth - oldMax
    Player.health = math.min((Player.health or baseStats.maxHealth) + delta, baseStats.maxHealth)
    Player.stats = baseStats
end

function generateTestItemToInventory()
    local gridX, gridY = getPlayerCell()
    local item = LootGenerator.generateCombatItem({
        location = getBiomeForCell(gridX, gridY), enemyType = "skeleton",
        difficulty = getDifficultyMultiplier(), playerLuck = Player.stats.luck or 0,
        itemLevel = math.max(1, (Player.level or 1) + (currentDepth or 1)),
        depth = currentDepth or 1, playerLevel = Player.level or 1,
        playerStats = { lowHP = Player.health < (Player.stats.maxHealth or 100) * 0.3 }
    })
    addInventoryItem(item, "Тест-предмет: ")
    print("Добавлен предмет:", item.displayName or item.name)
end

function performInventoryAction(action, item, actualIndex)
    if not item then return end
    actualIndex = actualIndex or selectedInventoryActualIndex()

    if action == "Одеть" then
        if item.type and item.type:find("weapon") then
            if Player.equipped.weapon then
                table.insert(Player.inventory, Player.equipped.weapon)
            end
            Player.equipped.weapon = item
            if actualIndex then table.remove(Player.inventory, actualIndex) end
            inventoryMessage = "Вы экипировали оружие: " .. (item.displayName or item.name or "???")
            inventoryMessageTimer = 3

        elseif item.type and item.type:find("armor") then
            local slot = item.type:match("%((.-)%)") or "torso"
            if Player.equipped.armor[slot] then
                table.insert(Player.inventory, Player.equipped.armor[slot])
            end
            Player.equipped.armor[slot] = item
            if actualIndex then table.remove(Player.inventory, actualIndex) end
            inventoryMessage = "Вы экипировали броню: " .. (item.displayName or item.name or "???")
            inventoryMessageTimer = 3
        end

        selectedInventoryItem = math.max(1, math.min(selectedInventoryItem, visibleInventoryCount()))
        recalculatePlayerStats()

    elseif action == "Выбросить" then
        if actualIndex then table.remove(Player.inventory, actualIndex) end
        selectedInventoryItem = math.max(1, math.min(selectedInventoryItem, visibleInventoryCount()))
        inventoryMessage = "Предмет выброшен"
        inventoryMessageTimer = 2

    elseif action == "Применить" then
        if item.type and item.type:find("potion") then
            local healAmount = math.floor((Player.stats.maxHealth or 100) * (item.healFraction or 0.42))
            Player.health = math.min(Player.stats.maxHealth or 100, Player.health + healAmount)
            if actualIndex then table.remove(Player.inventory, actualIndex) end
            selectedInventoryItem = math.max(1, math.min(selectedInventoryItem, visibleInventoryCount()))
            inventoryMessage = "Зелье применено: +" .. healAmount .. " HP"
            inventoryMessageTimer = 2
        end
    end
end

function tableContains(t, value)
    for _, v in ipairs(t) do
        if v == value then
            return true
        end
    end
    return false
end

function gainExperience(amount)
    amount = math.max(0, math.floor(amount or 0))
    Player.experience = (Player.experience or 0) + amount
    while Player.experience >= Player.experienceToNextLevel do
        Player.experience = Player.experience - Player.experienceToNextLevel
        Player.level = (Player.level or 1) + 1
        Player.experienceToNextLevel = getExpForLevel(Player.level)
        increasePlayerStatsOnLevelUp()
        inventoryMessage = "Новый уровень! Уровень: " .. Player.level
        inventoryMessageTimer = 3
        addFloatingText(Player.x, Player.y, "LEVEL " .. tostring(Player.level), {0.4, 1, 0.4})
    end
end

function increasePlayerStatsOnLevelUp()
    Player.baseStats = Player.baseStats or Player.stats
    local lvl = Player.level or 1
    local inc = Balance.leveling.statGain or {}
    for stat, value in pairs(inc) do
        Player.baseStats[stat] = (Player.baseStats[stat] or 0) + value
    end
    if lvl % 2 == 0 then Player.baseStats.critChance = (Player.baseStats.critChance or 0.1) + (Balance.leveling.evenCrit or 0.008) end
    if lvl % 3 == 0 then Player.baseStats.attackSpeed = (Player.baseStats.attackSpeed or 1.0) + (Balance.leveling.thirdAttackSpeed or 0.04) end
    if lvl % 4 == 0 then Player.baseStats.dodge = (Player.baseStats.dodge or 0) + (Balance.leveling.fourthDodge or 0.01) end
    recalculatePlayerStats()
    Player.health = math.min((Player.health or 0) + math.floor((Player.stats.maxHealth or 100) * (Balance.leveling.healOnLevel or 0.25)), Player.stats.maxHealth)
end


function checkWallCircleCollision(x, y, radius)
    local samples = {
        {x = x - radius, y = y},
        {x = x + radius, y = y},
        {x = x, y = y - radius},
        {x = x, y = y + radius},
        {x = x - radius * 0.7, y = y - radius * 0.7},
        {x = x + radius * 0.7, y = y - radius * 0.7},
        {x = x - radius * 0.7, y = y + radius * 0.7},
        {x = x + radius * 0.7, y = y + radius * 0.7},
    }

    for _, sample in ipairs(samples) do
        local gridX = toCell(sample.x)
        local gridY = toCell(sample.y)
        if not map[gridY] or not map[gridY][gridX] then
            return true
        end
        if map[gridY][gridX] ~= '0' then
            return true
        end
    end

    return false
end


function checkCircleCollision(x1, y1, r1, x2, y2, r2)
    local dx = x2 - x1
    local dy = y2 - y1
    return dx * dx + dy * dy < (r1 + r2)^2
end

function checkEnemyCircleCollision(x, y, radius)
    for _, enemy in ipairs(enemies) do
        if checkCircleCollision(x, y, radius, enemy.x, enemy.y, enemy.radius or 8) then
            return true
        end
    end
    return false
end

function pushBackFromEnemy()
    for _, enemy in ipairs(enemies) do
        if checkCircleCollision(Player.x, Player.y, Player.radius, enemy.x, enemy.y, enemy.radius or 8) then
            local dx = Player.x - enemy.x
            local dy = Player.y - enemy.y
            local dist = math.sqrt(dx * dx + dy * dy)
            if dist > 0 then
                local overlap = Player.radius + (enemy.radius or 8) - dist
                local pushX = (dx / dist) * overlap
                local pushY = (dy / dist) * overlap
                local newX = Player.x + pushX
                local newY = Player.y + pushY
                if not checkWallCircleCollision(newX, Player.y, Player.radius) then
                    Player.x = newX
                end
                if not checkWallCircleCollision(Player.x, newY, Player.radius) then
                    Player.y = newY
                end
            end
        end
    end
end

function moveWithCollision(oldX, oldY, dx, dy, radius)
    local newX = oldX + dx
    local newY = oldY + dy

    -- проверка по X
    if not checkWallCircleCollision(newX, oldY, radius) then
        oldX = newX
    end

    -- проверка по Y
    if not checkWallCircleCollision(oldX, newY, radius) then
        oldY = newY
    end

    return oldX, oldY
end

function hasAttackTarget()
    if not Player or showMenu or isGameOver or isInventoryOpen then return false end
    local profile = getWeaponProfile()
    for _, enemy in ipairs(enemies) do
        if enemy.health and enemy.health > 0 then
            local dx, dy = enemy.x - Player.x, enemy.y - Player.y
            local distance = math.sqrt(dx * dx + dy * dy)
            if distance < profile.range then
                local angleToEnemy = math.atan2(dy, dx) - Player.angle
                while angleToEnemy > math.pi do angleToEnemy = angleToEnemy - 2 * math.pi end
                while angleToEnemy < -math.pi do angleToEnemy = angleToEnemy + 2 * math.pi end
                if math.abs(angleToEnemy) < profile.angle / 2 and hasLineOfSightTo(enemy.x, enemy.y, distance) then
                    return true
                end
            end
        end
    end
    return false
end

function drawCrosshair()
    local x = baseWidth / 2
    local y = baseHeight / 2
    local pulse = clamp(attackVisualTimer or 0, 0, 1)
    local size = 5 + pulse * 8
    love.graphics.setLineWidth(1 + pulse)
    local target = hasAttackTarget()
    if target then
        love.graphics.setColor(0.35 + pulse * 0.45, 1, 0.55, 0.98)
    else
        love.graphics.setColor(1, 0.15 + pulse * 0.45, 0.15, 0.95)
    end
    love.graphics.line(x - size, y, x + size, y)
    love.graphics.line(x, y - size, x, y + size)
    if pulse > 0 then
        love.graphics.setColor(target and 0.35 or 1, target and 1 or 0.55, target and 0.55 or 0.22, 0.35 * pulse)
        love.graphics.circle("line", x, y, 8 + pulse * 14)
    end
    love.graphics.setLineWidth(1)
end

function drawDepthOverlay()
    local h = 100
    local y = baseHeight - h - 28
    love.graphics.setColor(0, 0, 0, 0.65)
    love.graphics.rectangle("fill", 0, y, baseWidth, h)
    love.graphics.setColor(0.35, 1, 0.35, 0.8)
    for i = 1, numRays do
        local d = wallDistances[i] and wallDistances[i].distance or MAX_RAY_DISTANCE
        local v = clamp(1 - d / MAX_RAY_DISTANCE, 0, 1)
        local x = (i - 1) * (baseWidth / numRays)
        love.graphics.rectangle("fill", x, y + h - v * h, math.max(1, baseWidth / numRays), v * h)
    end
    love.graphics.setFont(smallFont or defaultFont)
    love.graphics.setColor(1, 1, 1, 0.85)
    love.graphics.print("F6 depth buffer", 8, y + 4)
    love.graphics.setFont(defaultFont)
end

function drawSpriteDebugOverlay()
    love.graphics.setFont(smallFont or defaultFont)
    for _, sprite in ipairs(visibleSprites) do
        local sx = sprite.screenX or ((sprite.angle + FOV / 2) / FOV * baseWidth)
        local sy = sprite.kind == "object" and baseHeight / 2 + 70 or baseHeight / 2 + 55
        love.graphics.setColor(sprite.kind == "object" and 1 or 0.4, sprite.kind == "object" and 0.9 or 1, 0.3, 0.9)
        love.graphics.line(sx, 0, sx, baseHeight)
        love.graphics.printf((sprite.kind or "sprite") .. " " .. math.floor(sprite.distance or 0), sx - 50, sy, 100, "center")
    end
    love.graphics.setFont(defaultFont)
end

function drawDebugOverlay()
    local gx, gy = getPlayerCell()
    local biome = getBiomeForCell(gx, gy)
    local lines = {
        "F3 debug",
        "FPS: " .. tostring(love.timer.getFPS()),
        "rays: " .. tostring(numRays),
        "sprites: " .. tostring(#visibleSprites),
        "enemies: " .. tostring(#enemies) .. "  objects: " .. tostring(#interactiveObjects),
        "audio: sfx " .. tostring(#(SFXGenerator.activeSources or {})) .. " / music " .. tostring(#(MusicEngine.activeSources or {})),
        string.format("pos: %.1f %.1f  cell: %d %d", Player.x, Player.y, gx, gy),
        "biome: " .. tostring(biome),
        "depth: " .. tostring(currentDepth) .. " seed: " .. tostring(currentSeed),
        "run: " .. formatTime(runElapsed()) .. " kills " .. tostring(runStats.enemiesKilled or 0) .. " loot " .. tostring(runStats.itemsFound or 0),
    }

    love.graphics.setFont(smallFont or defaultFont)
    local w = 340
    local h = #lines * 14 + 10
    love.graphics.setColor(0, 0, 0, 0.62)
    love.graphics.rectangle("fill", baseWidth - w - 10, 10, w, h)
    love.graphics.setColor(0.7, 1, 0.7, 0.95)
    for i, line in ipairs(lines) do
        love.graphics.print(line, baseWidth - w, 16 + (i - 1) * 14)
    end
    love.graphics.setFont(defaultFont)
end

function createDefaultPlayer(x, y)
    return {
        x = x, y = y, angle = math.pi / 2, baseSpeed = 205, vx = 0, vy = 0,
        level = 1, experience = 0, experienceToNextLevel = getExpForLevel(1),
        radius = 10, inventory = {},
        baseStats = {
            maxHealth = 100, armor = 5, damage = 10, attackSpeed = 1.0,
            range = 2.5, critChance = 0.1, critMultiplier = 1.5,
            luck = 0.2, speed = 0, dodge = 0.03
        },
        stats = {
            maxHealth = 100, armor = 5, damage = 10, attackSpeed = 1.0,
            range = 2.5, critChance = 0.1, critMultiplier = 1.5,
            luck = 0.2, speed = 0, dodge = 0.03
        },
        health = 100,
        equipped = { weapon = nil, armor = { head = nil, torso = nil, legs = nil } }
    }
end
