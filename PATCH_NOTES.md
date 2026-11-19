# ASCII Dungeon 3D — fixed/optimized build

Что поправлено без добавления нового крупного контента:

- Убран спам генерации звуков ходьбы каждый кадр: теперь шаги играют по таймеру.
- SFXGenerator переведён на 22050 Hz и получил кэш SoundData.
- MusicEngine переведён на 22050 Hz и получил кэш нот, чтобы не пересобирать одинаковые ноты постоянно.
- Рейкастинг переписан на DDA по сетке вместо шага по 2 пикселя.
- wallDistances и visibleSprites переиспользуются без пересоздания таблиц каждый кадр.
- Видимость спрайтов проверяется через глубину стен, а не отдельной трассировкой до врага.
- Пол и потолок кэшируются в canvas для каждого биома и больше не рисуются тысячами прямоугольников каждый кадр.
- Настройки FOV / скорость / число лучей теперь реально применяются.
- Исправлен размер клетки: используется единый TILE_SIZE = 30 вместо смеси 16 и 30.
- Исправлена музыка ruins-биома.
- Паттерны стен стали детерминированными: убран random внутри draw-функций, меньше мерцания и визуальной каши.
- Исправлены цвета миникарты под LÖVE 11.x, где цвета идут в диапазоне 0..1.
- Добавлен fallback на стандартный шрифт, если DejaVuSansMono.ttf не лежит рядом.
- Исправлен game over sound: больше не падает, если файла звука нет.
- Враги больше не должны свободно проходить сквозь стены при движении.
- Исправлен undefined difficultyMultiplier при дропе/опыте.
- Исправлен undefined itemSpriteTemplate.
- Исправлены lookup'и тегов лута с пробелами/дефисами через нормализацию ключей.
- Исправлена экипировка/пересчёт статов: level-up больше не теряется после recalculatePlayerStats.
- Контекстное меню инвентаря теперь обрабатывает «Выбросить» и «Применить».
- Добавлен ruins-визуал в NoiseEngine, чтобы биом не проваливался в чёрный фон.

Запуск:

```bash
love /path/to/ascii_dungeon_fixed
```

Или напрямую .love:

```bash
love ascii_dungeon_fixed.love
```

## v3 — UI/QoL polish

- Добавлен и упакован `DejaVuSansMono.ttf`; игра теперь использует его как основной моноширинный шрифт.
- Добавлен `conf.lua` с нормальными параметрами окна, vsync, highdpi и identity.
- Добавлены горячие клавиши: `F11` — полноэкранный режим, `F3` — debug overlay, `R` на экране смерти — перезапуск.
- Добавлен debug overlay с FPS, количеством лучей, видимых спрайтов, врагов, предметов и текущим биомом.
- Исправлено масштабирование всплывающего сообщения инвентаря: теперь оно рисуется в той же виртуальной системе координат, что и игра.
- Эмодзи-иконки инвентаря заменены на ASCII-метки `[W]`, `[A]`, `[P]`, `[T]`, `[M]`, `[J]`, чтобы не ловить квадратики в моноширинном шрифте.
- Добавлены подсказки управления в меню, настройках и HUD.
- Ограничен `dt` после лагов/alt-tab, чтобы физика и враги не прыгали рывком.

## v4 — gameplay/polish pass

- Separate interactive object layer: chests, altars, depth exit.
- Connected dungeon normalization via flood-fill.
- Current depth progression with scaling difficulty.
- Enemy/object visibility still respects wall depth.
- Enemy LOD markers, outlines, hit flash, and floating feedback text.
- Inventory filters, sorting, junk cleanup, and stat comparison.
- Master/music/SFX volume settings with simple persistence.
- Developer overlays: full map, depth graph, sprite rays.
- README, CHANGELOG, build_love.sh, run.sh.
