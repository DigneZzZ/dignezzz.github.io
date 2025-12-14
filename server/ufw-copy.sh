#!/bin/bash

# Получаем текущие правила ufw
current_rules=$(sudo ufw status numbered | grep -E '^\[[0-9]+\]' | awk '{print $2}')

# Создаем команду для установки правил на другом сервере
install_command="sudo ufw --force enable && sudo ufw default deny incoming"

# Добавляем каждое правило к команде
for rule in $current_rules; do
    install_command+=" && sudo ufw allow $rule"
done

# Выводим получившуюся команду
echo "$install_command"
