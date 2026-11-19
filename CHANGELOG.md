## v15

- Full ANSI/ASCII UI restyle: panels, borders, chips and bars are rendered from symbols.
- Removed rounded modern GUI rectangles from the UI layer.
- Kept v14 layout but made it look like an actual terminal/ASCII interface.

# v14

- Modern UI/GUI rework: меню, HUD, настройки, инвентарь, Game Over.
- Стеклянные панели, чипы, карточки, статус-бары, аккуратные тосты.


## v7 — enemies + wall patterns pass

- Улучшены враги: более детальные силуэты из примитивов, контактные тени, floor-anchor, мягкий LOD и подсветка попаданий.
- Исправлено странное уменьшение объектов при приближении: размер теперь считается по реальной дистанции, а не по fisheye-correctedDistance.
- Объекты сильнее привязаны к перспективе пола и больше не скачут между LOD так резко.
- Паттерны стен переведены в world-space: камень, плитка, плоть и circuit-wall больше не выглядят как экранный шум.
- В DDA raycast добавлены hitSide, hitMapX/hitMapY и wallU для стабильного текстурирования стен.


## v6

- Перерисовал интерактивные объекты как world-billboard вместо UI-карточек.
- Добавил мягкое появление/исчезновение объектов по дистанции и краю FOV.
- Привязал сундуки, алтари и выход к полу через проекционную высоту и контактную тень.
- Убрал постоянные подписи с объектов: теперь текст появляется только рядом/при взаимодействии.
- Добавил освещение и альфу объектов от дистанции, чтобы они меньше выбивались из сцены.

# Changelog

## v5

- Reworked interactive object visuals for readability.
- Replaced cryptic object labels like `[+]` with named readable cards.
- Added distinct chest, altar, and exit silhouettes.
- Added clearer far-distance object LOD markers.
- Made minimap object colors different by type.

## v4

- Added separate interactive object layer.
- Added chests, altars, and depth exit.
- Added connected-map normalization using flood-fill.
- Added current depth progression and seed debug info.
- Added object and enemy visibility through existing wall depth.
- Added enemy LOD markers and outlines.
- Added floating combat/loot/heal text.
- Added inventory filters, sorting, junk cleanup, and stat comparison.
- Added volume settings and simple settings persistence.
- Added dev/debug hotkeys: F4 full map, F5 restart, F6 depth buffer, F7 sprite rays.
- Packaged bundled DejaVuSansMono.ttf.

## v3

- Added bundled font support.
- Added conf.lua.
- Added fullscreen, debug overlay, safer dt clamp, and HUD hints.

## v2

- Fixed biomeTypes scope bug.

## v1

- Initial fixed/optimized build from legacy prototype.

## v8
- Враги теперь масштабируются обычной перспективой: ближе = больше, без обратного сжатия.
- Модели врагов приподняты над полом, тень осталась на земле.
- Улучшены силуэты врагов: плотнее обводка, слабая аура/тень, более читаемый LOD.
- Паттерны стен переписаны: камни, плитка, flesh-wall и circuit-wall стали стабильнее и привязаны к координатам стены.


## v9

- Исправлен размер врагов: теперь они монотонно увеличиваются при приближении и не используют смешанную перспективу.
- Модель врага поднята выше за счёт привязки нижней границы силуэта к полу.
- На стены возвращён настоящий ASCII-слой: символы рисуются поверх паттернов и завязаны на координаты стены.
- В raycast-данные добавлен rayIndex для стабильных текстурных/ASCII-паттернов.


## v11

- Gameplay pass: levels, loot, stats, damage, armor mitigation, enemy scaling, XP curve and HUD stats.


## v13
- Rebalanced visual readability after v12.
- Better ASCII-only walls: denser, brighter, less ghost-like.
- Softer floor/ceiling background and wall shadow.


## v16
- UI scale/polish pass: HUD, menu, inventory, settings, game over.
- Pure ANSI outlines for UI rows/panels, less noisy fill.


## v17
- Gameplay loop and balance pass: run summary, records, enemy roles, altar risk/reward, centralized Balance.lua, item build hints.
