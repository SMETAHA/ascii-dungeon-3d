-- Balance.lua
-- Centralised gameplay numbers for ASCII Dungeon 3D.
-- Tweak this file first when adjusting pacing, difficulty and run length.

local Balance = {}

Balance.leveling = {
    baseXp = 78,
    levelMul = 40,
    power = 1.52,
    healOnLevel = 0.25,
    evenCrit = 0.008,
    thirdAttackSpeed = 0.035,
    fourthDodge = 0.008,
    statGain = {
        maxHealth = 7,
        damage = 1.25,
        armor = 0.50,
        luck = 0.014
    }
}

Balance.difficulty = {
    base = 1.0,
    depthMul = 0.16,
    levelMul = 0.09
}

Balance.weaponProfiles = {
    melee = { rangeBonus = 58, angleDeg = 112, maxTargets = 3, damageScale = 1.0, cooldown = 0.52, knockback = 145, hitStop = 0.045, shake = 3.7 },
    ranged = { rangeBonus = 125, angleDeg = 34, maxTargets = 1, damageScale = 0.94, cooldown = 0.64, knockback = 82, hitStop = 0.025, shake = 2.3 }
}

Balance.spawn = {
    baseEnemies = 7,
    depthEnemies = 1.35,
    levelEnemies = 0.30,
    maxEnemies = 28,
    bossEvery = 5
}

Balance.enemyScaling = {
    levelHp = 0.15,
    depthHp = 0.06,
    damageMul = 0.62
}

Balance.enemyRoles = {
    default = { name="давящий", kind="melee", hpMul=1.0, damageMul=1.0, defenseMul=1.0, speedMul=1.0, preferredRange=18, meleeRange=16, aggroRange=190, attackSpeedMul=1.0 },
    skeleton = { name="костяной страж", kind="melee", hpMul=1.18, damageMul=0.95, defenseMul=1.25, speedMul=0.82, preferredRange=22, meleeRange=20, aggroRange=185, attackSpeedMul=0.82, dodge=0.01 },
    goblin = { name="налётчик", kind="skirmisher", hpMul=0.82, damageMul=0.88, defenseMul=0.80, speedMul=1.34, preferredRange=52, meleeRange=18, aggroRange=225, attackSpeedMul=1.05, dodge=0.08, critBase=0.06 },
    wizard = { name="дальний кастер", kind="ranged", hpMul=0.78, damageMul=1.12, defenseMul=0.75, speedMul=0.86, preferredRange=170, retreatDistance=88, attackRange=190, meleeRange=12, aggroRange=260, attackSpeedMul=0.62, orbit=true, dodge=0.03, critBase=0.04 },
    slime = { name="вязкий танк", kind="melee", hpMul=1.42, damageMul=0.70, defenseMul=0.65, speedMul=0.62, preferredRange=20, meleeRange=21, aggroRange=165, attackSpeedMul=0.62, dodge=0.07 },
    beast = { name="охотник", kind="skirmisher", hpMul=1.04, damageMul=1.10, defenseMul=1.0, speedMul=1.22, preferredRange=46, meleeRange=23, aggroRange=240, attackSpeedMul=0.92, dodge=0.06, critBase=0.05 },
    boss = { name="узловой босс", kind="melee", hpMul=2.25, damageMul=1.28, defenseMul=1.35, speedMul=0.82, preferredRange=30, meleeRange=28, aggroRange=300, attackSpeedMul=0.72, dodge=0.03, critBase=0.08, critMultiplier=1.65 }
}

Balance.altarBlessings = {
    {stat="damage", value=1.4},
    {stat="armor", value=1.1},
    {stat="maxHealth", value=10},
    {stat="luck", value=0.05},
    {stat="critChance", value=0.018},
    {stat="attackSpeed", value=0.05},
    {stat="dodge", value=0.012},
    {stat="speed", value=7}
}

return Balance
