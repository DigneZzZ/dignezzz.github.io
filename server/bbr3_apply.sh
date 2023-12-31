#!/bin/bash
# Получаем информацию о системе
os_name=$(lsb_release -is)

# Проверяем, является ли система Ubuntu
if [ "$os_name" != "Ubuntu" ]; then
    echo "Этот скрипт поддерживает только Ubuntu. Вы используете $os_name, которая не поддерживается."
    exit 1
fi

print_message() {
    tput setaf $1
    echo $2
    tput sgr0
}

clear

tput bold
echo '  
                           
BBBB  Y   Y     DDD  III  GGG  N   N EEEE ZZZZZ ZZZZZ ZZZZZ 
B   B  Y Y      D  D  I  G     NN  N E       Z     Z     Z  
BBBB    Y       D  D  I  G  GG N N N EEE    Z     Z     Z   
B   B   Y       D  D  I  G   G N  NN E     Z     Z     Z    
BBBB    Y       DDD  III  GGG  N   N EEEE ZZZZZ ZZZZZ ZZZZZ 
                                                            

'
sleep 2s
print_message 3 "Скрипт активиации BBR3 нового ядра XANMOD"
sleep 1s

# Выполнить команду depmod -a
depmod -a

print_message 3 "Применяем изменения"
sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
echo net.ipv4.tcp_congestion_control=bbr | tee -a /etc/sysctl.conf
echo net.core.default_qdisc=fq | tee -a /etc/sysctl.conf

print_message 3 "Перезагружаем сеть"
# Применить изменения в sysctl
sysctl -p

print_message 3 "Выводим данные модуля BBR"
# Проверить информацию о модуле tcp_bbr
modinfo tcp_bbr
