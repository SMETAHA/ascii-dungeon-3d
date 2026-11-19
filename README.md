# ASCII Dungeon 3D

**A small experimental pseudo-3D dungeon crawler built with LÖVE and Lua.** Explore procedurally generated dungeons, fight enemies, collect and equip loot, and descend through increasingly dangerous levels in an ASCII-inspired world.

> **Status:** Experimental prototype — actively unfinished. Expect rough edges, balance changes, and incomplete polish.

[Русская версия](#русский) · [English](#english)

## English

## Features

- Pseudo-3D raycast rendering with an ASCII-inspired visual style.
- Procedurally generated, connected dungeons and biome variations.
- Melee and ranged combat, enemy roles, and periodic bosses.
- Loot with rarities, equipment, stat modifiers, and build hints.
- Inventory, character progression, altars, chests, and depth exits.
- Procedural music and sound effects.
- Run summaries, saved records, configurable audio, and debug overlays.

## Requirements

- [LÖVE](https://love2d.org/) 11.5 or compatible.
- `zip` is needed only to create a `.love` archive with `build_love.sh`.

## Run

From the project directory:

```sh
love .
```

On Linux, the included launcher can also be used:

```sh
./run.sh
```

To package the project as a `.love` archive:

```sh
./build_love.sh
```

## Controls

| Input | Action |
| --- | --- |
| `W` `A` `S` `D` | Move |
| Mouse | Look around |
| `Space` or left mouse button | Attack |
| `E` or right mouse button | Interact with an object or break a nearby wall |
| `I` | Open or close inventory |
| `Tab` (inventory) | Cycle item filter |
| `S` (inventory) | Sort inventory |
| `X` (inventory) | Drop junk items |
| `F3` | Toggle debug overlay |
| `F4` | Toggle full map |
| `F5` | Restart run |
| `F6` | Toggle wall-depth visualization |
| `F7` | Toggle visible-sprite visualization |
| `F11` | Toggle fullscreen |
| `R` (game over) | Restart run |
| `Esc` | Open pause menu / close inventory; quit from the main menu |

`L` generates a test item and is intended for development.

## Project layout

- `main.lua` — game loop, rendering, input, and gameplay.
- `Balance.lua` — gameplay tuning.
- `Loot*.lua` — loot generation and item tags.
- `MusicEngine.lua`, `SFXGenerator.lua` — procedural audio.
- `NoiseEngine.lua` — procedural noise and biome visuals.

## License

The project code is provided under the [MIT License](LICENSE). The bundled DejaVu Sans Mono font has its own license; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

---

## Русский

**Небольшой экспериментальный псевдо‑3D dungeon crawler на Lua и LÖVE.** Исследуйте процедурные подземелья, сражайтесь с врагами, собирайте экипировку и спускайтесь на всё более опасные уровни в мире с ASCII-эстетикой.

> **Статус:** экспериментальный прототип, разработка не завершена. Возможны недоработки, изменения баланса и незаконченная полировка.

### Возможности

- Псевдо‑3D-рендеринг с рейкастингом и ASCII-стилистикой.
- Процедурная генерация связанных подземелий и вариантов биомов.
- Ближний и дальний бой, разные роли врагов и периодические боссы.
- Добыча с редкостью, экипировкой, модификаторами характеристик и подсказками для сборки.
- Инвентарь, развитие персонажа, алтари, сундуки и переходы на следующую глубину.
- Процедурно генерируемые музыка и звуковые эффекты.
- Итоги забега, сохранение рекордов, настройки звука и отладочные режимы.

### Требования

- [LÖVE](https://love2d.org/) версии 11.5 или совместимая.
- `zip` нужен только для упаковки `.love` через `build_love.sh`.

### Запуск

В каталоге проекта:

```sh
love .
```

В Linux также можно запустить:

```sh
./run.sh
```

Чтобы собрать архив `.love`:

```sh
./build_love.sh
```

### Управление

| Клавиша / ввод | Действие |
| --- | --- |
| `W` `A` `S` `D` | Движение |
| Мышь | Поворот |
| `Space` или левая кнопка мыши | Атака |
| `E` или правая кнопка мыши | Взаимодействие с объектом или разрушение близкой стены |
| `I` | Открыть или закрыть инвентарь |
| `Tab` (в инвентаре) | Переключить фильтр предметов |
| `S` (в инвентаре) | Сортировать инвентарь |
| `X` (в инвентаре) | Выбросить хлам |
| `F3` | Отладочная панель |
| `F4` | Полная карта |
| `F5` | Начать забег заново |
| `F6` | Визуализация глубины стен |
| `F7` | Визуализация видимых спрайтов |
| `F11` | Полноэкранный режим |
| `R` (после смерти) | Начать забег заново |
| `Esc` | Открыть меню паузы / закрыть инвентарь; выйти из главного меню |

`L` создаёт тестовый предмет и предназначена для разработки.

### Структура проекта

- `main.lua` — игровой цикл, рендеринг, ввод и игровая логика.
- `Balance.lua` — настройки баланса.
- `Loot*.lua` — генерация добычи и теги предметов.
- `MusicEngine.lua`, `SFXGenerator.lua` — процедурный звук.
- `NoiseEngine.lua` — процедурный шум и визуальные эффекты биомов.

### Лицензия

Код проекта распространяется по [лицензии MIT](LICENSE). Встроенный шрифт DejaVu Sans Mono распространяется на собственных условиях; подробности — в файле [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

---

