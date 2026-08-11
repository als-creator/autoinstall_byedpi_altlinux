#!/bin/bash
set -e

# Запрещаем запуск от root
if [ "$EUID" -eq 0 ]; then
    echo "Не запускайте скрипт от root." >&2
    exit 1
fi

echo "Начинаем установку ByeDPI..."

# Установка byedpi из репозитория
echo "Обновление списка пакетов..."
sudo apt-get update -y >/dev/null 2>&1

echo "Попытка установки byedpi..."
sudo apt-get install -y byedpi >/dev/null 2>&1 || {
    echo "Установка не удалась, пробуем снова..."
    sudo apt-get update && sudo apt-get install -y byedpi
}

# Конфигурация byedpi
echo "Создаем конфигурационный файл..."
cat > /tmp/byedpi_config << 'EOF'
# Параметры для byedpi
BYEDPI_ARGS="-i 127.0.0.1 --port 14228 -d1 -d3+s -s6+s -d9+s -s12+s -d15+s -s20+s -d25+s -s30+s -d35+s -r1+s -S -a1 -As -d1 -d3+s -s6+s -d9+s -s12+s -d15+s -s20+s -d25+s -s30+s -d35+s -S -a1"
EOF
sudo bash -c "cat /tmp/byedpi_config > /etc/sysconfig/byedpi"
rm -f /tmp/byedpi_config

# Включение и запуск byedpi
echo "Включаем и запускаем byedpi..."
sudo systemctl enable --now byedpi

echo "ByeDPI успешно установлен и запущен на адресе 127.0.0.1:14228"
echo "Правило и порт можно изменить в /etc/sysconfig/byedpi"
echo "Для настройки прокси браузера можно использовать расширения FoxyProxy, SmartProxy или Proxy SwitchyOmega."
echo "Используйте следующие команды для управления службой:"
echo "sudo systemctl restart byedpi   # Для перезапуска."
echo "sudo systemctl start byedpi     # Для запуска."
echo "sudo systemctl status byedpi     # Для проверки статуса сервиса."
