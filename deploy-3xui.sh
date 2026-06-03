#!/bin/bash

# ==============================================================================
# Скрипт автоматического развертывания 3x-ui с Nginx Reality Fallback и SSL
# Разработано на основе гайда: https://noname-28.gitbook.io/3x-ui-gaid
# ==============================================================================

# Цвета для вывода в консоль
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Функции логирования
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 1. Проверка прав суперпользователя (root)
if [ "$EUID" -ne 0 ]; then
    log_error "Пожалуйста, запустите этот скрипт с правами root (sudo)."
    exit 1
fi

# 2. Проверка операционной системы
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    VERSION_ID=$VERSION_ID
else
    log_error "Не удалось определить операционную систему."
    exit 1
fi

if [[ "$OS" != "ubuntu" && "$OS" != "debian" ]]; then
    log_warning "Данный скрипт протестирован на Ubuntu/Debian. Ваша ОС: $OS. Продолжение на ваш страх и риск."
    read -p "Продолжить? (y/n): " confirm_os
    if [[ "$confirm_os" != "y" && "$confirm_os" != "Y" ]]; then
        exit 1
    fi
fi

# Инициализация переменных по умолчанию
DOMAIN=""
EMAIL=""
PORT="2053"
USERNAME="admin"
PASSWORD="admin"
BASE_PATH="panel"
SUB_PORT="2096"

# Флаги для отслеживания параметров, заданных через аргументы
PORT_ARG_SET=""
USER_ARG_SET=""
PASS_ARG_SET=""
BASE_ARG_SET=""
SUB_PORT_ARG_SET=""

# Парсинг аргументов командной строки
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -d|--domain)
            DOMAIN="$2"
            shift; shift
            ;;
        -e|--email)
            EMAIL="$2"
            shift; shift
            ;;
        -p|--port)
            PORT="$2"
            PORT_ARG_SET="1"
            shift; shift
            ;;
        -u|--username)
            USERNAME="$2"
            USER_ARG_SET="1"
            shift; shift
            ;;
        -w|--password)
            PASSWORD="$2"
            PASS_ARG_SET="1"
            shift; shift
            ;;
        -b|--basepath)
            BASE_PATH="$2"
            BASE_ARG_SET="1"
            shift; shift
            ;;
        -s|--subport)
            SUB_PORT="$2"
            SUB_PORT_ARG_SET="1"
            shift; shift
            ;;
        *)
            log_warning "Неизвестный аргумент: $1"
            shift
            ;;
    esac
done

# Интерактивный ввод, если аргументы не переданы
echo -e "${CYAN}================================================================${NC}"
echo -e "${PURPLE}    Автоматическое развертывание 3x-ui с Nginx Reality Fallback  ${NC}"
echo -e "${CYAN}================================================================${NC}"

# Шаг 1. Ввод домена
if [ -z "$DOMAIN" ]; then
    echo -e "${YELLOW}Шаг 1/7: Ввод доменного имени${NC}"
    echo -e "Для работы SSL сертификата необходим зарегистрированный домен!"
    echo -e "Убедитесь, что ваш домен уже направлен (DNS A-запись) на IP этого сервера."
    read -p "Введите ваш домен (например, yourdomain.com): " DOMAIN
fi

if [ -z "$DOMAIN" ]; then
    log_error "Доменное имя обязательно для продолжения установки."
    exit 1
fi

# Проверка DNS записи перед продолжением
log_info "Проверка разрешения DNS для домена $DOMAIN..."
DOM_IP=$(getent ahosts "$DOMAIN" | awk '{print $1}' | head -n 1)
if [ -z "$DOM_IP" ]; then
    log_warning "Не удалось разрешить домен $DOMAIN в IP адрес."
    log_warning "Убедитесь, что DNS-записи обновились, иначе Certbot не сможет выпустить сертификат!"
    read -p "Всё равно продолжить? (y/n): " confirm_dns
    if [[ "$confirm_dns" != "y" && "$confirm_dns" != "Y" ]]; then
        exit 1
    fi
fi

# Шаг 2. Ввод email
if [ -z "$EMAIL" ]; then
    echo -e "\n${YELLOW}Шаг 2/7: Электронная почта для SSL${NC}"
    read -p "Введите email для Let's Encrypt (опционально, нажмите Enter для пропуска): " EMAIL
fi

# Шаг 3. Ввод порта панели
if [ -z "$PORT_ARG_SET" ]; then
    echo -e "\n${YELLOW}Шаг 3/7: Порт панели управления${NC}"
    read -p "Введите порт для панели 3x-ui [по умолчанию: 2053]: " PORT_INPUT
    PORT="${PORT_INPUT:-2053}"
fi

# Шаг 4. Ввод имени пользователя
if [ -z "$USER_ARG_SET" ]; then
    echo -e "\n${YELLOW}Шаг 4/7: Имя пользователя панели${NC}"
    read -p "Введите имя пользователя панели [по умолчанию: admin]: " USER_INPUT
    USERNAME="${USER_INPUT:-admin}"
fi

# Шаг 5. Ввод пароля
if [ -z "$PASS_ARG_SET" ]; then
    echo -e "\n${YELLOW}Шаг 5/7: Пароль панели${NC}"
    read -p "Введите пароль панели [по умолчанию: admin]: " PASS_INPUT
    PASSWORD="${PASS_INPUT:-admin}"
fi

# Шаг 6. Ввод секретного пути
if [ -z "$BASE_ARG_SET" ]; then
    echo -e "\n${YELLOW}Шаг 6/7: Секретный путь панели (Base Path)${NC}"
    read -p "Введите секретный путь панели (например, secretpath) [по умолчанию: panel]: " BASE_INPUT
    BASE_PATH="${BASE_INPUT:-panel}"
fi

# Шаг 7. Ввод порта подписки
if [ -z "$SUB_PORT_ARG_SET" ]; then
    echo -e "\n${YELLOW}Шаг 7/7: Порт подписок (Subscription Port)${NC}"
    read -p "Введите порт подписки 3x-ui [по умолчанию: 2096]: " SUB_PORT_INPUT
    SUB_PORT="${SUB_PORT_INPUT:-2096}"
fi

# Очистка пути панели от начального слэша
BASE_PATH=$(echo "$BASE_PATH" | sed 's#^/##')

echo -e "\n${CYAN}Настройки приняты. Начинаем установку...${NC}\n"

# 3. Обновление пакетов системы
log_info "Обновление списка пакетов системы..."
apt update && apt upgrade -y
if [ $? -ne 0 ]; then
    log_error "Не удалось обновить пакеты системы."
    exit 1
fi

# 4. Установка UFW и настройка портов
log_info "Установка и настройка файрволла UFW..."
apt install ufw -y

# Разрешаем порты
log_info "Настройка правил файрволла..."
ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP for Certbot/Nginx'
ufw allow 443/tcp comment 'HTTPS for Reality'
ufw allow "$PORT"/tcp comment '3x-ui Panel'
ufw allow "$SUB_PORT"/tcp comment '3x-ui Subscription'

# Включение UFW без интерактивного подтверждения
echo "y" | ufw enable
log_success "Файрволл успешно настроен и включен."

# 5. Установка Certbot и выпуск SSL сертификата
log_info "Установка Certbot..."
apt install certbot -y

# Останавливаем nginx на всякий случай перед выпуском сертификата
systemctl stop nginx 2>/dev/null || true

log_info "Выпуск SSL сертификата для домена $DOMAIN..."
if [ -z "$EMAIL" ]; then
    certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email
else
    certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos --email "$EMAIL"
fi

if [ $? -ne 0 ]; then
    log_error "Не удалось выпустить SSL сертификат через Certbot."
    log_error "Проверьте, направлен ли домен на IP сервера и открыт ли порт 80."
    exit 1
fi
log_success "SSL сертификат успешно выпущен."

# 6. Установка Nginx
log_info "Установка веб-сервера Nginx..."
apt install nginx -y

# 7. Конфигурация Nginx для Reality Fallback c проксированием подписок и панели
NGINX_CONF="/etc/nginx/sites-available/reality-nginx"
log_info "Создание конфигурации Nginx..."

cat > "$NGINX_CONF" << EOF
server {
    listen unix:/dev/shm/nginx.sock ssl proxy_protocol;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    set_real_ip_from unix:;
    real_ip_header proxy_protocol;

    location / {
        root /var/www/html;
        index index.html;
    }

    location ~* ^/(sub|clash|json)/ {
        proxy_pass https://127.0.0.1:$SUB_PORT;

        proxy_http_version 1.1;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$http_host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$http_host;

        proxy_buffering off;
        proxy_read_timeout 120s;
    }

    location /$BASE_PATH/ {
        proxy_pass https://127.0.0.1:$PORT;
        
        proxy_http_version 1.1;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_buffering off;
        proxy_read_timeout 120s;
    }
}

server {
    listen 80;
    server_name $DOMAIN;
 
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF

# Активация конфигурации
log_info "Активация конфигурации Nginx..."
rm -f /etc/nginx/sites-enabled/default
ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/

# Проверка конфигурации Nginx
nginx -t
if [ $? -ne 0 ]; then
    log_error "Конфигурация Nginx содержит ошибки!"
    exit 1
fi

systemctl restart nginx
systemctl enable nginx
log_success "Nginx настроен и успешно перезапущен."

# 8. Установка сайта-заглушки (landing page)
log_info "Установка сайта-заглушки (SaaS Landing Page)..."
apt install git -y
rm -rf /var/www/html/*
git clone https://github.com/bradtraversy/saas-landing-page.git /var/www/html

if [ $? -ne 0 ]; then
    log_warning "Не удалось склонировать сайт-заглушку с GitHub. Создан стандартный index.html."
    echo "<h1>Welcome to $DOMAIN</h1>" > /var/www/html/index.html
fi

chown -R www-data:www-data /var/www/html
log_success "Сайт-заглушка успешно развернут."

# 9. Установка и настройка панели 3x-ui
log_info "Установка 3x-ui панели..."

# Автоматизируем интерактивные ответы установщика:
# 1. Выбор БД: SQLite (1)
# 2. Кастомизировать порт: Да (y)
# 3. Номер порта: $PORT
# 4. Настройка SSL в скрипте установки: Пропустить (4)
# 5. Привязка к localhost (127.0.0.1): Нет (n)
printf "1\ny\n$PORT\n4\nn\n" | bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)

if [ $? -ne 0 ]; then
    log_error "Ошибка при установке панели 3x-ui."
    exit 1
fi

# 10. Применение кастомных настроек через CLI 3x-ui
log_info "Применение настроек панели (пользователь, пароль, порт, путь)..."
/usr/local/x-ui/x-ui setting -username "$USERNAME" -password "$PASSWORD" -port "$PORT" -webBasePath "$BASE_PATH"

log_info "Подключение SSL сертификатов к панели 3x-ui..."
/usr/local/x-ui/x-ui cert -webCert "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" -webCertKey "/etc/letsencrypt/live/$DOMAIN/privkey.pem"

log_info "Перезапуск сервиса 3x-ui..."
systemctl restart x-ui
systemctl enable x-ui

log_success "Панель 3x-ui успешно установлена и настроена!"

# Вывод итоговой информации
echo -e "\n${GREEN}================================================================${NC}"
echo -e "${GREEN}    Установка успешно завершена!                                ${NC}"
echo -e "${GREEN}================================================================${NC}"
echo -e "${BLUE}Домен:${NC} $DOMAIN"
echo -e "${BLUE}Порт панели:${NC} $PORT (проксируется Nginx на порт 443)"
echo -e "${BLUE}Путь панели:${NC} /$BASE_PATH"
echo -e "${BLUE}Порт подписки:${NC} $SUB_PORT (проксируется Nginx на порт 443)"
echo -e "${BLUE}Имя пользователя:${NC} $USERNAME"
echo -e "${BLUE}Пароль:${NC} $PASSWORD"
echo -e "----------------------------------------------------------------"
echo -e "${YELLOW}Ссылка для входа в панель:${NC} https://$DOMAIN/$BASE_PATH/"
echo -e "${YELLOW}Ссылка для подписок (в клиентах):${NC} https://$DOMAIN/sub/"
echo -e "----------------------------------------------------------------"
echo -e "${CYAN}Инструкция по настройке Reality Inbound в панели:${NC}"
echo -e "1. Перейдите в раздел ${PURPLE}Inbounds (Подключения)${NC} -> ${PURPLE}Add Inbound (Добавить)${NC}."
echo -e "2. Выберите протокол: ${BLUE}vless${NC}."
echo -e "3. Порт: ${BLUE}443${NC}."
echo -e "4. Включите Reality: ${BLUE}Reality: Enabled${NC}."
echo -e "5. В поле ${BLUE}Dest${NC} введите: ${YELLOW}unix:/dev/shm/nginx.sock${NC} (или 127.0.0.1:80 в качестве резерва)."
echo -e "6. В поле ${BLUE}Server Names (SNI)${NC} введите ваш домен: ${YELLOW}$DOMAIN${NC}."
echo -e "7. В поле ${BLUE}Fallback${NC} (в самом низу Reality настроек) выберите: ${YELLOW}Dest: unix:/dev/shm/nginx.sock${NC}."
echo -e "8. Сгенерируйте ключи (Get New Keys), добавьте клиента (Flow: xtls-rprx-vision) и сохраните."
echo -e "${GREEN}================================================================${NC}\n"
