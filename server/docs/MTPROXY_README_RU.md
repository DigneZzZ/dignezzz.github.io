# MTProxy - Инструкция на русском

## Что изменилось

Скрипт `mtproxy.sh` был полностью переработан для использования официального Docker-образа от Telegram.

### Основные изменения:

1. **Docker вместо Python** - Теперь используется официальный образ `telegrammessenger/proxy:latest`
2. **Гибкая настройка порта** - По умолчанию 443, но можно использовать любой свободный порт
3. **Интеграция с @MTProxybot** - Четкие инструкции по получению TAG для брендирования канала
4. **Управление TAG** - Команда `update-tag` для добавления/изменения TAG после установки
5. **Простое управление** - Утилита `mtproxy` для всех операций

## Установка

```bash
# Сделать скрипт исполняемым
chmod +x mtproxy.sh

# Установить MTProxy
sudo ./mtproxy.sh install
```

Во время установки вас попросят:
- Указать порт (по умолчанию 443)
- Опционально ввести TAG от @MTProxybot (можно добавить позже)

## Получение TAG для брендирования канала

TAG нужен для продвижения вашего канала пользователям, которые подключаются через ваш прокси.

**Как получить TAG:**

1. Откройте Telegram и найдите бота [@MTProxybot](https://t.me/MTProxybot)
2. Отправьте команду `/newproxy`
3. Зарегистрируйте свой прокси у бота
4. Бот предоставит вам TAG (32 шестнадцатеричных символа)

**Добавить/обновить TAG:**

```bash
sudo ./mtproxy.sh update-tag
```

## Команды управления

### Команды установки

```bash
# Установить MTProxy
sudo ./mtproxy.sh install

# Обновить TAG от @MTProxybot
sudo ./mtproxy.sh update-tag

# Полностью удалить MTProxy
sudo ./mtproxy.sh uninstall

# Показать справку
./mtproxy.sh help
```

### Команды после установки

После установки используйте утилиту `mtproxy`:

```bash
# Показать статус и ссылки для подключения
mtproxy status

# Запустить контейнер
mtproxy start

# Остановить контейнер
mtproxy stop

# Перезапустить контейнер
mtproxy restart

# Просмотреть логи
mtproxy logs

# Обновить TAG
mtproxy update-tag

# Показать детальную информацию
mtproxy info

# Показать справку
mtproxy help
```

## Настройка порта

Если порт 443 занят, можно использовать другой:

1. **Во время установки**: Укажите другой порт при запросе
2. **После установки**: 
   - Отредактируйте `/opt/MTProxy/.env` и измените PORT
   - Перезапустите контейнер: `mtproxy restart`

**Примеры портов:**
- 443 (HTTPS - по умолчанию)
- 8443
- 9443

## Конфигурация Docker Compose

Скрипт создает файл `docker-compose.yml` в `/opt/MTProxy/docker-compose.yml`:

```yaml
version: '3.8'

services:
  mtproto-proxy:
    image: telegrammessenger/proxy:latest
    container_name: mtproto-proxy
    restart: always
    ports:
      - "${PORT}:443"
    environment:
      SECRET: "${SECRET}"
      TAG: "${TAG}"
    volumes:
      - proxy-config:/data

volumes:
  proxy-config:
```

## Переменные окружения

Переменные хранятся в `/opt/MTProxy/.env`:

```
SECRET=<автоматически-сгенерированный-секрет>
PORT=<ваш-порт>
TAG=<ваш-tag-от-mtproxybot>  # Опционально
```

## Ссылки для подключения

После установки вы получите ссылки:

**Telegram ссылка:**
```
tg://proxy?server=ВАШ_IP&port=ПОРТ&secret=СЕКРЕТ
```

**Web ссылка:**
```
https://t.me/proxy?server=ВАШ_IP&port=ПОРТ&secret=СЕКРЕТ
```

Делитесь этими ссылками с пользователями вашего прокси.

## Файлы и директории

- `/opt/MTProxy/` - Директория установки
- `/opt/MTProxy/docker-compose.yml` - Конфигурация Docker Compose
- `/opt/MTProxy/.env` - Переменные окружения (SECRET, PORT, TAG)
- `/opt/MTProxy/info.txt` - Информация о конфигурации
- `/usr/local/bin/mtproxy` - Утилита управления

## Устранение неполадок

### Проверить статус контейнера

```bash
docker ps | grep mtproto-proxy
```

### Просмотреть логи

```bash
mtproxy logs
# или
docker-compose -f /opt/MTProxy/docker-compose.yml logs -f
```

### Проверить доступность порта

```bash
# Проверить, занят ли порт
sudo ss -tlnp | grep :443

# Проверить firewall
sudo ufw status
```

### Перезапустить контейнер

```bash
mtproxy restart
```

### Переустановка

```bash
# Сначала удалить
sudo ./mtproxy.sh uninstall

# Затем установить снова
sudo ./mtproxy.sh install
```

## Сравнение со старой версией

| Функция | Старая версия (Python) | Новая версия (Docker) |
|---------|----------------------|---------------------|
| Установка | Python зависимости | Docker образ |
| Управление | systemd сервис | Docker Compose |
| Обновления | Вручную | Docker pull |
| Настройка порта | При установке | Гибко |
| Поддержка TAG | Ручная настройка | Интеграция с @MTProxybot |
| Откат | systemctl | docker-compose |
| Логи | journalctl | docker logs |

## Безопасность

- Держите ваш SECRET в секрете
- Используйте правила firewall для защиты сервера
- TAG от @MTProxybot позволяет продвигать канал (опционально)
- Контейнер настроен на автоматический перезапуск для высокой доступности

## Поддержка

При возникновении проблем:
- Проверьте статус Docker: `docker ps`
- Проверьте логи: `mtproxy logs`
- Проверьте конфигурацию: `mtproxy info`

Подробная документация на английском: `MTPROXY_README.md`
