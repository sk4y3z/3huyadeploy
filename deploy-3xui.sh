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

# Функция для генерации случайных строк
generate_random_string() {
    local length="$1"
    # Попытка использовать openssl, если доступно, иначе urandom
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c "$length"
    else
        cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w "$length" | head -n 1
    fi
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

# Генерация значений по умолчанию
DEFAULT_USERNAME=$(generate_random_string 8)
DEFAULT_PASSWORD=$(generate_random_string 12)
DEFAULT_BASE_PATH=$(generate_random_string 12)

# Инициализация переменных
DOMAIN=""
EMAIL=""
PORT="2053"
USERNAME=""
PASSWORD=""
BASE_PATH=""
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
    read -p "Введите имя пользователя панели [по умолчанию: $DEFAULT_USERNAME]: " USER_INPUT
    USERNAME="${USER_INPUT:-$DEFAULT_USERNAME}"
else
    USERNAME="${USERNAME:-$DEFAULT_USERNAME}"
fi

# Шаг 5. Ввод пароля
if [ -z "$PASS_ARG_SET" ]; then
    echo -e "\n${YELLOW}Шаг 5/7: Пароль панели${NC}"
    read -p "Введите пароль панели [по умолчанию: $DEFAULT_PASSWORD]: " PASS_INPUT
    PASSWORD="${PASS_INPUT:-$DEFAULT_PASSWORD}"
else
    PASSWORD="${PASSWORD:-$DEFAULT_PASSWORD}"
fi

# Шаг 6. Ввод секретного пути
if [ -z "$BASE_ARG_SET" ]; then
    echo -e "\n${YELLOW}Шаг 6/7: Секретный путь панели (Base Path)${NC}"
    read -p "Введите секретный путь панели (например, secretpath) [по умолчанию: $DEFAULT_BASE_PATH]: " BASE_INPUT
    BASE_PATH="${BASE_INPUT:-$DEFAULT_BASE_PATH}"
else
    BASE_PATH="${BASE_PATH:-$DEFAULT_BASE_PATH}"
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
apt install ufw python3 -y

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

# 8. Установка сайта-заглушки (частный медиасервер)
log_info "Создание сайта-заглушки (Private Media Server)..."
mkdir -p /var/www/html
rm -rf /var/www/html/*

cat > /var/www/html/index.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Aether Private Media Server</title>
    <style>
        body {
            margin: 0;
            padding: 0;
            font-family: 'Segoe UI', Roboto, Helvetica, Arial, sans-serif;
            background: radial-gradient(circle at center, #1b2030 0%, #0a0c10 100%);
            color: #e0e0e0;
            display: flex;
            justify-content: center;
            align-items: center;
            height: 100vh;
            overflow: hidden;
        }

        .login-container {
            background: rgba(15, 20, 30, 0.75);
            backdrop-filter: blur(10px);
            border: 1px solid rgba(255, 255, 255, 0.05);
            padding: 40px;
            border-radius: 16px;
            width: 100%;
            max-width: 380px;
            box-shadow: 0 10px 30px rgba(0,0,0,0.5);
            text-align: center;
        }

        .logo {
            font-size: 32px;
            font-weight: 700;
            color: #00bcd4;
            margin-bottom: 8px;
            letter-spacing: 1px;
            display: flex;
            justify-content: center;
            align-items: center;
            gap: 10px;
        }

        .logo svg {
            width: 36px;
            height: 36px;
            fill: #00bcd4;
        }

        .subtitle {
            font-size: 14px;
            color: #888da0;
            margin-bottom: 30px;
        }

        .input-group {
            position: relative;
            margin-bottom: 20px;
            text-align: left;
        }

        .input-group label {
            display: block;
            font-size: 12px;
            color: #888da0;
            margin-bottom: 6px;
            text-transform: uppercase;
            letter-spacing: 0.5px;
        }

        .input-group input {
            width: 100%;
            box-sizing: border-box;
            background: rgba(255, 255, 255, 0.03);
            border: 1px solid rgba(255, 255, 255, 0.1);
            padding: 12px 16px;
            border-radius: 8px;
            color: #ffffff;
            font-size: 14px;
            transition: all 0.3s ease;
        }

        .input-group input:focus {
            outline: none;
            border-color: #00bcd4;
            background: rgba(255, 255, 255, 0.06);
            box-shadow: 0 0 10px rgba(0, 188, 212, 0.2);
        }

        .btn {
            width: 100%;
            background: #00bcd4;
            color: #0c0e14;
            border: none;
            padding: 14px;
            border-radius: 8px;
            font-size: 16px;
            font-weight: 600;
            cursor: pointer;
            transition: all 0.3s ease;
            margin-top: 10px;
        }

        .btn:hover {
            background: #00e5ff;
            box-shadow: 0 0 15px rgba(0, 229, 255, 0.4);
            transform: translateY(-1px);
        }

        .btn:active {
            transform: translateY(0);
        }

        .footer {
            margin-top: 30px;
            font-size: 11px;
            color: #4a4f66;
        }

        .footer a {
            color: #888da0;
            text-decoration: none;
        }

        .footer a:hover {
            color: #00bcd4;
        }
    </style>
</head>
<body>
    <div class="login-container">
        <div class="logo">
            <svg viewBox="0 0 24 24">
                <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-2 14.5v-9l6 4.5-6 4.5z"/>
            </svg>
            <span>AETHER</span>
        </div>
        <div class="subtitle">Private Home Media Gateway</div>
        
        <form onsubmit="event.preventDefault(); alert('Authentication failed: Access denied from this IP.');">
            <div class="input-group">
                <label for="username">Username</label>
                <input type="text" id="username" autocomplete="off" placeholder="Enter username">
            </div>
            
            <div class="input-group">
                <label for="password">Password</label>
                <input type="password" id="password" autocomplete="off" placeholder="Enter password">
            </div>
            
            <button type="submit" class="btn">Sign In</button>
        </form>
        
        <div class="footer">
            <span>Aether Stream Services &copy; 2026. </span>
            <br>
            <span style="font-size: 9px; margin-top: 5px; display: inline-block;">Node status: <span style="color: #4caf50;">Online</span></span>
        </div>
    </div>
</body>
</html>
EOF

chown -R www-data:www-data /var/www/html
log_success "Сайт-заглушка (маскировка под Aether Media Server) успешно развернут."

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

# 11. Автоматическая запись VLESS Reality Inbound и настроек подписки напрямую в БД
log_info "Генерация скрипта настройки базы данных..."

cat > /usr/local/x-ui/configure_3xui_db.py << 'EOF'
import sqlite3
import uuid
import random
import string
import json
import glob
import subprocess
import re
import sys
import shutil
import os

db_path = "/etc/x-ui/x-ui.db"
domain = sys.argv[1]
port = int(sys.argv[2])
sub_port = int(sys.argv[3])
base_path = sys.argv[4]

def print_err(msg):
    sys.stderr.write(msg + "\n")

conn = sqlite3.connect(db_path)
cursor = conn.cursor()

# Функция установки/обновления параметров в таблице settings
def set_setting(key, value):
    cursor.execute("SELECT id FROM settings WHERE key=?", (key,))
    row = cursor.fetchone()
    if row:
        cursor.execute("UPDATE settings SET value=? WHERE key=?", (value, key))
    else:
        cursor.execute("INSERT INTO settings (key, value) VALUES (?, ?)", (key, value))

# Записываем настройки подписок (Subscription settings)
set_setting("subEnable", "true")
set_setting("subJsonEnable", "true")
set_setting("subClashEnable", "true")
set_setting("subPort", str(sub_port))
set_setting("subURI", f"https://{domain}/sub/")
set_setting("subJsonURI", f"https://{domain}/json/")
set_setting("subClashURI", f"https://{domain}/clash/")
set_setting("subListen", "127.0.0.1")

# Поиск xray бинарника в стандартных местах и переменной PATH
search_paths = [
    "/usr/local/x-ui/bin/xray-linux-*",
    "/usr/local/x-ui/bin/xray",
    "/usr/local/x-ui/xray-linux-*",
    "/usr/local/x-ui/xray",
]
xray_bins = []
for p in search_paths:
    xray_bins.extend(glob.glob(p))

xray_bin = None
if xray_bins:
    xray_bin = xray_bins[0]
else:
    xray_bin = shutil.which("xray")

if not xray_bin:
    print_err("Error: xray binary not found in standard paths (/usr/local/x-ui/bin/) or system PATH.")
    sys.exit(1)

# Убедимся в наличии прав на запуск
try:
    os.chmod(xray_bin, 0o755)
except Exception as e:
    print_err(f"Warning: could not chmod +x {xray_bin}: {e}")

try:
    out = subprocess.check_output([xray_bin, "x25519"], stderr=subprocess.STDOUT).decode('utf-8')
except subprocess.CalledProcessError as e:
    print_err(f"Error running xray x25519: {e.output.decode('utf-8', errors='ignore')}")
    sys.exit(1)
except Exception as e:
    print_err(f"Error executing xray: {e}")
    sys.exit(1)

# Поддержка как старого формата вывода (Private key: / Public key:), так и нового (PrivateKey: / Password:)
priv_match = re.search(r"(?:Private\s*key|PrivateKey):\s*(\S+)", out, re.IGNORECASE)
pub_match = re.search(r"(?:Public\s*key|PublicKey|Password):\s*(\S+)", out, re.IGNORECASE)

if not priv_match or not pub_match:
    print_err(f"Error parsing x25519 output: {out}")
    sys.exit(1)

priv_key = priv_match.group(1)
pub_key = pub_match.group(1)

# Создание параметров клиента
client_uuid = str(uuid.uuid4())
client_sub_id = "".join(random.choices(string.ascii_lowercase + string.digits, k=16))
short_id = "".join(random.choices("0123456789abcdef", k=16))

settings_json = {
  "clients": [
    {
      "id": client_uuid,
      "flow": "xtls-rprx-vision",
      "email": f"admin@{domain}",
      "limitIp": 0,
      "totalGB": 0,
      "expiryTime": 0,
      "enable": True,
      "tgId": "",
      "subId": client_sub_id
    }
  ],
  "decryption": "none",
  "fallbacks": []
}

stream_settings_json = {
  "network": "tcp",
  "security": "reality",
  "realitySettings": {
    "show": True,
    "dest": "/dev/shm/nginx.sock",
    "xver": 1,
    "serverNames": [
      domain
    ],
    "privateKey": priv_key,
    "publicKey": pub_key,
    "minClientVer": "",
    "maxClientVer": "",
    "maxTimeDiff": 0,
    "shortIds": [
      short_id
    ]
  },
  "tcpSettings": {}
}

sniffing_json = {
  "enabled": True,
  "destOverride": [
    "http",
    "tls"
  ],
  "metadataOnly": False,
  "routeOnly": False
}

# Очистка старых инбаундов на порту 443
cursor.execute("DELETE FROM inbounds WHERE port=443")

cursor.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='clients'")
clients_table_exists = cursor.fetchone() is not None

# Вставка нового инбаунда VLESS Reality
cursor.execute("""
INSERT INTO inbounds (user_id, up, down, total, remark, enable, expiry_time, listen, port, protocol, settings, stream_settings, tag, sniffing)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
""", (
    1, 0, 0, 0, "reality", 1, 0, "", 443, "vless",
    json.dumps(settings_json), json.dumps(stream_settings_json), "reality-inbound", json.dumps(sniffing_json)
))
inbound_id = cursor.lastrowid

# Если в этой версии 3x-ui есть выделенная таблица clients, синхронизируем данные туда
if clients_table_exists:
    cursor.execute("PRAGMA table_info(clients)")
    columns = [col[1] for col in cursor.fetchall()]
    
    client_data = {
        "inbound_id": inbound_id,
        "email": f"admin@{domain}",
        "uuid": client_uuid,
        "flow": "xtls-rprx-vision",
        "enable": 1,
        "sub_id": client_sub_id,
        "up": 0,
        "down": 0,
        "total": 0,
        "expiry_time": 0
    }
    
    insert_cols = [col for col in client_data.keys() if col in columns]
    placeholders = ", ".join(["?"] * len(insert_cols))
    query = f"INSERT INTO clients ({', '.join(insert_cols)}) VALUES ({placeholders})"
    values = [client_data[col] for col in insert_cols]
    cursor.execute(query, values)

conn.commit()
conn.close()

# Вывод параметров в stdout для парсинга в Bash
print(f"CLIENT_UUID={client_uuid}")
print(f"CLIENT_SUB_ID={client_sub_id}")
print(f"PUBLIC_KEY={pub_key}")
print(f"SHORT_ID={short_id}")
EOF

log_info "Запуск конфигурации базы данных..."
python3 /usr/local/x-ui/configure_3xui_db.py "$DOMAIN" "$PORT" "$SUB_PORT" "$BASE_PATH" > /tmp/db_config_out.txt 2> /tmp/db_config_err.txt

if [ $? -eq 0 ]; then
    # Считываем переменные, созданные Python скриптом
    CLIENT_UUID=$(grep -Eo 'CLIENT_UUID=.+' /tmp/db_config_out.txt | cut -d'=' -f2)
    CLIENT_SUB_ID=$(grep -Eo 'CLIENT_SUB_ID=.+' /tmp/db_config_out.txt | cut -d'=' -f2)
    PUBLIC_KEY=$(grep -Eo 'PUBLIC_KEY=.+' /tmp/db_config_out.txt | cut -d'=' -f2)
    SHORT_ID=$(grep -Eo 'SHORT_ID=.+' /tmp/db_config_out.txt | cut -d'=' -f2)
    log_success "База данных 3x-ui успешно настроена!"
    
    # Генерация VLESS Reality ссылки подключения
    VLESS_LINK="vless://${CLIENT_UUID}@${DOMAIN}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#reality"
else
    log_error "Не удалось автоматически настроить базу данных 3x-ui."
    if [ -s /tmp/db_config_err.txt ]; then
        log_error "Детали ошибки (stderr):"
        cat /tmp/db_config_err.txt
    fi
    if [ -s /tmp/db_config_out.txt ]; then
        log_error "Лог вывода (stdout):"
        cat /tmp/db_config_out.txt
    fi
fi

# Чистим временные скрипты
rm -f /usr/local/x-ui/configure_3xui_db.py
rm -f /tmp/db_config_out.txt
rm -f /tmp/db_config_err.txt

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
if [ -n "$VLESS_LINK" ]; then
    echo -e "----------------------------------------------------------------"
    echo -e "${PURPLE}Ваша готовая ссылка подключения VLESS + Reality:${NC}"
    echo -e "${CYAN}${VLESS_LINK}${NC}"
fi
echo -e "----------------------------------------------------------------"
echo -e "${CYAN}Инструкция по настройке Reality Inbound в панели:${NC}"
echo -e "Инбаунд на порту 443 (VLESS + Reality) был добавлен автоматически."
echo -e "Вы можете войти в панель и увидеть настройки в разделе ${PURPLE}Inbounds (Подключения)${NC}."
echo -e "Никаких ручных конфигураций делать больше не нужно! Просто импортируйте ссылку выше."
echo -e "${GREEN}================================================================${NC}\n"
