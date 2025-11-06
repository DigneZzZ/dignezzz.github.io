# Пример сообщения в Telegram

## Обычный бэкап (без разделения)

```text
✅ SHM Backup Complete

🖥 Server: grizzly
📅 Date: 2025-11-06 14:30:15 UTC
⏱ Duration: 02:15

📊 Archive: 23.5M
📁 Files: 1,247

📦 Contents:
📁 Entire SHM folder
📋 db_backup.sql (MySQL)
💾 webdav-volume.tar.gz (shm-data)

💾 Database: shm (145.67 MB, 28 tables)
```

---

## Разделенный бэкап (больше 49MB)

### Часть 1 из 3

```text
✅ SHM Backup Complete

📦 Part: 1 of 3 (49M)

🖥 Server: grizzly
📅 Date: 2025-11-06 14:30:15 UTC
⏱ Duration: 05:43

📊 Archive: 135M
📁 Files: 3,891

📦 Contents:
📁 Entire SHM folder
📋 db_backup.sql (MySQL)
💾 webdav-volume.tar.gz (shm-data)

💾 Database: shm (145.67 MB, 28 tables)
```

### Часть 2 из 3

```text
✅ SHM Backup Complete

📦 Part: 2 of 3 (49M)

🖥 Server: grizzly
📅 Date: 2025-11-06 14:30:15 UTC
⏱ Duration: 05:43

📊 Archive: 135M
📁 Files: 3,891

📦 Contents:
📁 Entire SHM folder
📋 db_backup.sql (MySQL)
💾 webdav-volume.tar.gz (shm-data)

💾 Database: shm (145.67 MB, 28 tables)
```

### Часть 3 из 3

```text
✅ SHM Backup Complete

📦 Part: 3 of 3 (37M)

🖥 Server: grizzly
📅 Date: 2025-11-06 14:30:15 UTC
⏱ Duration: 05:43

📊 Archive: 135M
📁 Files: 3,891

📦 Contents:
📁 Entire SHM folder
📋 db_backup.sql (MySQL)
💾 webdav-volume.tar.gz (shm-data)

💾 Database: shm (145.67 MB, 28 tables)
```

---

## Выборочный бэкап (только файлы)

```text
✅ SHM Backup Complete

🖥 Server: grizzly
📅 Date: 2025-11-06 14:30:15 UTC
⏱ Duration: 01:32

📊 Archive: 2.3M
📁 Files: 4

📦 Contents:
📋 db_backup.sql (MySQL)
💾 webdav-volume.tar.gz (shm-data)
📄 docker-compose.yml
🔑 .env

💾 Database: shm (145.67 MB, 28 tables)
```

---

## Особенности визуала

### ✅ Добавленная статистика

1. **⏱ Duration** - время выполнения бэкапа (MM:SS)
   - Помогает отследить проблемы с производительностью
   - Видно, если бэкап выполняется дольше обычного

2. **📁 Files** - количество файлов в архиве
   - Понимание масштаба бэкапа
   - Быстрая проверка полноты

3. **🗃 Tables** - количество таблиц в БД
   - Валидация целостности базы данных
   - Контроль структуры БД

### 💪 Преимущества

- ✅ **HTML форматирование** - жирный текст для заголовков
- ✅ **Моноширинный шрифт** - для данных (hostname, дата, размеры)
- ✅ **Структурированность** - логические блоки информации
- ✅ **Эмодзи** - визуальные якоря для быстрого сканирования
- ✅ **Статистика** - полная информация о бэкапе
- ✅ **Время выполнения** - мониторинг производительности
- ✅ **Количество файлов** - контроль полноты

### ⚡ Не перегружено

- Только важная информация
- Компактный формат (помещается на экран)
- Легко читается на мобильном
- Быстро понятно, что в бэкапе

### 📊 Информативность: 10/10

- ✅ Когда создан (дата/время)
- ✅ С какого сервера (hostname)
- ✅ Размер архива и БД
- ✅ Что включено (содержимое)
- ✅ Сколько времени заняло
- ✅ Количество файлов
- ✅ Количество таблиц БД
- ✅ Статус (успешно/части)

---

## Разделенный бэкап (больше 49MB)

### Часть 1 из 3:
```
✅ SHM Backup Complete

📦 Part: 1 of 3 (49M)

🖥 Server: grizzly
📅 Date: 2025-11-06 14:30:15 UTC
📊 Archive: 135M

📦 Contents:
📁 Entire SHM folder
📋 db_backup.sql (MySQL)
💾 webdav-volume.tar.gz (shm-data)

💾 Database: shm (145.67 MB)
```

### Часть 2 из 3:
```
✅ SHM Backup Complete

📦 Part: 2 of 3 (49M)

🖥 Server: grizzly
📅 Date: 2025-11-06 14:30:15 UTC
📊 Archive: 135M

📦 Contents:
📁 Entire SHM folder
📋 db_backup.sql (MySQL)
💾 webdav-volume.tar.gz (shm-data)

💾 Database: shm (145.67 MB)
```

### Часть 3 из 3:
```
✅ SHM Backup Complete

📦 Part: 3 of 3 (37M)

🖥 Server: grizzly
📅 Date: 2025-11-06 14:30:15 UTC
📊 Archive: 135M

📦 Contents:
📁 Entire SHM folder
📋 db_backup.sql (MySQL)
💾 webdav-volume.tar.gz (shm-data)

💾 Database: shm (145.67 MB)
```

---

## Выборочный бэкап (только файлы)

```
✅ SHM Backup Complete

🖥 Server: grizzly
📅 Date: 2025-11-06 14:30:15 UTC
📊 Archive: 2.3M

📦 Contents:
📋 db_backup.sql (MySQL)
💾 webdav-volume.tar.gz (shm-data)
📄 docker-compose.yml
🔑 .env

💾 Database: shm (145.67 MB)
```

---

## Особенности визуала

### ✅ Что улучшено:
1. **HTML форматирование** - жирный текст для заголовков
2. **Моноширинный шрифт** - для данных (hostname, дата, размеры)
3. **Структурированность** - логические блоки информации
4. **Эмодзи** - визуальные якоря для быстрого сканирования
5. **Размер базы данных** - понимание объема данных
6. **Hostname** - идентификация сервера
7. **Размер частей** - при разделении видно размер каждой части

### ⚡ Не перегружено:
- Только важная информация
- Компактный формат
- Легко читается на мобильном
- Быстро понятно, что в бэкапе

### 📊 Информативность:
- ✅ Когда создан бэкап
- ✅ С какого сервера
- ✅ Размер архива
- ✅ Что включено
- ✅ Размер базы данных
- ✅ Статус (успешно)
