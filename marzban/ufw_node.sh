#!/bin/bash
export LC_CTYPE=en_US.UTF-8
# переменные для изменения цвета текста
RED='\e[31m'
GREEN='\e[32m'
YELLOW='\e[33m'
NC='\e[0m'

clear
echo '  

██╗   ██╗███████╗██╗    ██╗        ███████╗██╗██████╗ ███████╗██╗    ██╗ █████╗ ██╗     ██╗     
██║   ██║██╔════╝██║    ██║        ██╔════╝██║██╔══██╗██╔════╝██║    ██║██╔══██╗██║     ██║     
██║   ██║█████╗  ██║ █╗ ██║        █████╗  ██║██████╔╝█████╗  ██║ █╗ ██║███████║██║     ██║     
██║   ██║██╔══╝  ██║███╗██║        ██╔══╝  ██║██╔══██╗██╔══╝  ██║███╗██║██╔══██║██║     ██║     
╚██████╔╝██║     ╚███╔███╔╝        ██║     ██║██║  ██║███████╗╚███╔███╔╝██║  ██║███████╗███████╗
 ╚═════╝ ╚═╝      ╚══╝╚══╝         ╚═╝     ╚═╝╚═╝  ╚═╝╚══════╝ ╚══╝╚══╝ ╚═╝  ╚═╝╚══════╝╚══════╝

███████╗ ██████╗ ██████╗ 
██╔════╝██╔═══██╗██╔══██╗
█████╗  ██║   ██║██████╔╝
██╔══╝  ██║   ██║██╔══██╗
██║     ╚██████╔╝██║  ██║
╚═╝      ╚═════╝ ╚═╝  ╚═╝

███╗   ███╗ █████╗ ██████╗ ███████╗██████╗  █████╗ ███╗   ██╗    ███╗   ██╗ ██████╗ ██████╗ ███████╗
████╗ ████║██╔══██╗██╔══██╗╚══███╔╝██╔══██╗██╔══██╗████╗  ██║    ████╗  ██║██╔═══██╗██╔══██╗██╔════╝
██╔████╔██║███████║██████╔╝  ███╔╝ ██████╔╝███████║██╔██╗ ██║    ██╔██╗ ██║██║   ██║██║  ██║█████╗  
██║╚██╔╝██║██╔══██║██╔══██╗ ███╔╝  ██╔══██╗██╔══██║██║╚██╗██║    ██║╚██╗██║██║   ██║██║  ██║██╔══╝  
██║ ╚═╝ ██║██║  ██║██║  ██║███████╗██████╔╝██║  ██║██║ ╚████║    ██║ ╚████║╚██████╔╝██████╔╝███████╗
╚═╝     ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═══╝    ╚═╝  ╚═══╝ ╚═════╝ ╚═════╝ ╚══════╝
                                                                                                    

BBBB  Y   Y     DDD  III  GGG  N   N EEEE ZZZZZ ZZZZZ ZZZZZ 
B   B  Y Y      D  D  I  G     NN  N E       Z     Z     Z  
BBBB    Y       D  D  I  G  GG N N N EEE    Z     Z     Z   
B   B   Y       D  D  I  G   G N  NN E     Z     Z     Z    
BBBB    Y       DDD  III  GGG  N   N EEEE ZZZZZ ZZZZZ ZZZZZ 
                                                            
Marzban Multi Node Script
Visit: https://openode.ru
'

# Проверяем, установлен ли пакет sudo
if ! command -v sudo &> /dev/null; then
    # Проверяем версию Debian
    if [[ $(lsb_release -rs) == "10" || $(lsb_release -rs) == "11" ]]; then
        printf "${YELLOW}Мы определили что у вас Debian, для скрипта нужен пакет SUDO, он будет установлен.${NC}\n"
        # Устанавливаем пакет sudo
        apt-get update
        apt-get install sudo -y
    printf "${GREEN}***********${NC}\n"
    printf "${GREEN}Sudo установлен. Продолжаем установку.${NC}\n"
    printf "${GREEN}***********${NC}\n"
    else
        # Продолжаем работу скрипта без завершения
        exit 0
    fi
else
    printf "${GREEN}SUDO уже установлен. Пропускаем установку.${NC}\n"
fi

# проверка на запуск от суперпользователя
if [[ $EUID -ne 0 ]]; then
   printf "${RED}Этот скрипт должен быть запущен с правами суперпользователя${NC}\n" 
   exit 1
fi

# проверка на наличие установленного ufw
if dpkg --get-selections | grep -q "^ufw[[:space:]]*install$" >/dev/null; then
    printf "${GREEN}UFW уже установлен. Пропускаем установку.${NC}\n"
else
    # установка ufw
    sudo apt update
    sudo apt install ufw -y
fi
 # Считываем ssh порт из файла sshd_config
SSH_PORT=$(grep -oP '(?<=Port )\d+' /etc/ssh/sshd_config)

# Проверяем, существует ли уже правило для порта SSH
if sudo ufw status | grep -q $SSH_PORT/tcp; then
    printf "${GREEN}Правило для SSH-порта уже существует. Пропускаем добавление.${NC}\n"
else
    # настройка правил фаервола
    sudo ufw default deny incoming # отклонять все входящие соединения
    sudo ufw default allow outgoing # разрешать все исходящие соединения
    sudo ufw allow $SSH_PORT/tcp # разрешать ssh-соединения
    printf "${GREEN}Автоматически был считан из файла sshd_config и добавлен в исключения порт SSH : $SSH_PORT/tcp ${NC}\n"
fi



# Добавляем правило для диапазона портов 5001-5010
#ufw allow proto tcp from $ip_address to any port 5001:5010
ufw allow proto tcp from any to any port 5001:5010

# Добавляем правило для диапазона портов 6001-6010
#ufw allow proto tcp from $ip_address to any port 6001:6010
ufw allow proto tcp from any to any port 6001:6010
# Добавляем правило для стандартных портов
#ufw allow proto tcp from $ip_address to any port 62050:62051
ufw allow proto tcp from any to any port 62050:62051

# Перезагружаем ufw для применения изменений
sudo ufw --force disable

sudo ufw --force enable


echo "Правила добавлены успешно."
echo "если вы используете собственные порты отличные от моих, добавьте их вручную, командой ufw allow XXXXX - где XXXXX ваш порт."
