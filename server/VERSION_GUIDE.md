# Руководство по версионированию GIG MOTD Dashboard

## Формат версий

```
YYYY.MM.DD.MINOR
```

### Компоненты:

- **YYYY** - Год (4 цифры)
- **MM** - Месяц (2 цифры, с ведущим нулём)
- **DD** - День (2 цифры, с ведущим нулём)
- **MINOR** - Минорная версия в течение дня (начинается с 1)

## Примеры версий

| Версия | Описание |
|--------|----------|
| `2025.10.05.1` | Первый релиз 5 октября 2025 |
| `2025.10.05.2` | Второй релиз в тот же день (hotfix) |
| `2025.10.05.3` | Третий релиз в тот же день (minor update) |
| `2025.10.06.1` | Первый релиз следующего дня |

## Когда увеличивать MINOR:

### Увеличивай MINOR (например, .1 → .2) когда:
- ✅ Исправляешь баги в текущем релизе
- ✅ Добавляешь небольшие улучшения
- ✅ Вносишь изменения в документацию
- ✅ Оптимизируешь производительность
- ✅ Исправляешь опечатки или форматирование

### Примеры:
```
2025.10.05.1 → Первоначальный релиз с прогресс-барами
2025.10.05.2 → Исправлен баг с отображением SWAP
2025.10.05.3 → Добавлена опция --quiet
2025.10.05.4 → Оптимизирован вывод температуры CPU
```

## Как релизить новую версию

### 1. Обновить версию в коде (3 места):

**В `dashboard.sh`:**

```bash
# Строка ~8 (в заголовке)
# Version: 2025.10.05.2

# Строка ~18 (в константах)
readonly SCRIPT_VERSION="2025.10.05.2"

# Строка ~320 (внутри heredoc для генерируемого дашборда)
CURRENT_VERSION="2025.10.05.2"
```

### 2. Обновить CHANGELOG.md:

```markdown
## [2025.10.05.2] - 2025-10-05

### 🐛 Исправлено
- Исправлен баг с отображением SWAP на системах без SWAP

### 🔧 Изменено
- Улучшена производительность проверки температуры CPU
```

### 3. Закоммитить и запушить:

```bash
git add dashboard.sh CHANGELOG.md
git commit -m "Release v2025.10.05.2 - Fix SWAP display bug"
git push origin main
```

### 4. Проверить на сервере:

```bash
# Старая версия покажет уведомление
motd

# Вывод:
⚠️ Доступна новая версия MOTD-дашборда: 2025.10.05.2 (текущая: 2025.10.05.1)
💡 Обновление: bash <(wget -qO- https://dignezzz.github.io/server/dashboard.sh) --force
```

### 5. Обновить:

```bash
motd --update
```

## Типы изменений

### 🎨 Добавлено (Added)
Новые функции, возможности

### 🔧 Изменено (Changed)
Изменения существующей функциональности

### 🐛 Исправлено (Fixed)
Исправления багов

### 🗑️ Удалено (Removed)
Удалённые функции

### 🔒 Безопасность (Security)
Исправления уязвимостей

### ⚡ Производительность (Performance)
Оптимизация производительности

## Примеры коммитов

```bash
# Новая функция
git commit -m "feat: Add SSL certificate monitoring (v2025.10.06.1)"

# Исправление бага
git commit -m "fix: Fix SWAP display on systems without SWAP (v2025.10.05.2)"

# Улучшение
git commit -m "chore: Improve CPU temperature detection (v2025.10.05.3)"

# Документация
git commit -m "docs: Update README with new features (v2025.10.05.4)"
```

## Автоматическое обновление версии (опционально)

Можно создать скрипт для автоматического увеличения версии:

```bash
#!/bin/bash
# bump-version.sh

TODAY=$(date +%Y.%m.%d)
CURRENT_MINOR=$(grep 'readonly SCRIPT_VERSION=' dashboard.sh | grep -oP '\d+$')
NEW_MINOR=$((CURRENT_MINOR + 1))
NEW_VERSION="${TODAY}.${NEW_MINOR}"

echo "Bumping version to $NEW_VERSION"

# Обновляем во всех местах
sed -i "s/Version: [0-9.]\+/Version: $NEW_VERSION/" dashboard.sh
sed -i "s/readonly SCRIPT_VERSION=\"[0-9.]\+\"/readonly SCRIPT_VERSION=\"$NEW_VERSION\"/" dashboard.sh
sed -i "s/CURRENT_VERSION=\"[0-9.]\+\"/CURRENT_VERSION=\"$NEW_VERSION\"/" dashboard.sh

echo "✅ Version bumped to $NEW_VERSION"
```

## Проверка перед релизом

- [ ] Версия обновлена во всех 3 местах
- [ ] CHANGELOG.md обновлён
- [ ] Протестировано на тестовом сервере
- [ ] README.md обновлён (если нужно)
- [ ] Коммит с понятным сообщением
- [ ] Push в main ветку

---

**Автор**: DigneZzZ - https://gig.ovh
