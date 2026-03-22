#!/bin/bash
echo '  
                           
BBBB  Y   Y     DDD  III  GGG  N   N EEEE ZZZZZ ZZZZZ ZZZZZ 
B   B  Y Y      D  D  I  G     NN  N E       Z     Z     Z  
BBBB    Y       D  D  I  G  GG N N N EEE    Z     Z     Z   
B   B   Y       D  D  I  G   G N  NN E     Z     Z     Z    
BBBB    Y       DDD  III  GGG  N   N EEEE ZZZZZ ZZZZZ ZZZZZ 
                                                            
'
sleep 2s


# Получаем информацию о системе
os_name=$(lsb_release -is)

# Проверяем, является ли система Ubuntu
if [ "$os_name" != "Ubuntu" ]; then
    echo "Этот скрипт поддерживает только Ubuntu. Вы используете $os_name, которая не поддерживается."
    exit 1
fi


# Пути и стандартные значения
sysctl_path="/etc/sysctl.conf"

# Цвета и форматирование
bold=$(tput bold)
green=$(tput setaf 2)
yellow=$(tput setaf 3)
reset=$(tput sgr0)
clear
echo "${yellow}Данный скрипт оптимизирует сеть, путем выставления параметров SYSCTL${reset}"
echo "${yellow}Делаем бекап файла${reset}"
cp ${sysctl_path} /etc/sysctl.conf.backup
echo "Файл сохранен по пути /etc/sysctl.conf.backup"
sleep 1s
echo "${yellow}Скачиваем новый файл sysctl.conf${reset}"
wget "https://raw.githubusercontent.com/DigneZzZ/dignezzz.github.io/main/server/sysctl.conf" -q -O  ${sysctl_path}
echo "${yellow}Перезапускаем сеть${reset}"
sysctl -p
echo "${yellow}Готово!${reset}"

