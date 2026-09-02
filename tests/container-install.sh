#!/usr/bin/env bash
# Проверка установки «одной командой»: скрипт запускается через process substitution,
# исходников рядом нет — он должен сам скачать архив репозитория и всё развернуть.
# Роль GitHub играет локальный http.server, отдающий тот же путь archive/refs/heads/<ветка>.tar.gz.
set -u
export DEBIAN_FRONTEND=noninteractive
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  [ok]   $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }
chk(){ if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

echo "=== система: $(. /etc/os-release; echo "$PRETTY_NAME") ==="
mkdir -p /run/systemd/system
printf '#!/bin/sh\nexit 0\n' > /usr/local/bin/systemctl; chmod +x /usr/local/bin/systemctl; hash -r
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq --no-install-recommends python3 tar iproute2 >/dev/null 2>&1

# занимаем 10.8.0.0/24, чтобы проверить автоподбор свободной VPN-подсети
ip link add dummy0 type dummy 2>/dev/null && ip addr add 10.8.0.1/24 dev dummy0 2>/dev/null \
  && ip link set dummy0 up 2>/dev/null && echo "  (подсеть 10.8.0.0/24 занята искусственно)"

# собираем «репозиторий» так же, как его отдаёт GitHub: openvpn-master/<файлы>
mkdir -p /srv/repo/archive/refs/heads /build/openvpn-master
cp -a /src/lib /src/install.sh /src/uninstall.sh /src/VERSION /build/openvpn-master/ 2>/dev/null
tar -czf /srv/repo/archive/refs/heads/master.tar.gz -C /build openvpn-master
( cd /srv && python3 -m http.server 8000 >/dev/null 2>&1 & ) ; sleep 2
chk "локальный «GitHub» отвечает" "python3 -c \"import urllib.request;urllib.request.urlopen('http://127.0.0.1:8000/repo/archive/refs/heads/master.tar.gz')\""

echo; echo "=== запуск: bash <(cat install.sh) из пустого каталога ==="
cd /root
OVPN_REPO_URL=http://127.0.0.1:8000/repo OVPN_REPO_BRANCH=master \
  bash <(cat /src/install.sh) > /var/log/install.log 2>&1 </dev/null \
  && ok "установка одной командой прошла" || { bad "установка"; tail -25 /var/log/install.log; }
grep -E 'Скачиваю исходники|Исходники распакованы' /var/log/install.log | sed 's/^/    /'

chk "исходники скачаны, а не взяты локально" "grep -q 'Скачиваю исходники' /var/log/install.log"
chk "менеджер установлен"        "command -v ovpnctl"
chk "PKI создан"                 "test -f /etc/ovpnctl/pki/ca.crt"
chk "конфиг сервера на месте"    "test -f /etc/openvpn/server/server.conf"
chk "клиенты не создаются сами"  "[ -z \"$(ls -A /etc/ovpnctl/profiles 2>/dev/null)\" ]"
chk "в выводе есть подсказка про клиента" "grep -q 'ovpnctl client add' /var/log/install.log"
ovpnctl client add first >/dev/null 2>&1
chk "клиент создаётся командой"  "test -s /etc/ovpnctl/profiles/first.ovpn"
chk "адрес сервера определён автоматически" \
    "grep -qE 'remote ([0-9]{1,3}\.){3}[0-9]{1,3} 1194' /etc/ovpnctl/profiles/first.ovpn"
chk "протокол udp по умолчанию"    "grep -q '^proto udp' /etc/openvpn/server/server.conf"
chk "EC-ключи по умолчанию"        "openssl x509 -in /etc/ovpnctl/pki/ca.crt -noout -text | grep -q 'id-ecPublicKey'"
chk "DNS Cloudflare по умолчанию"  "grep -q 'dhcp-option DNS 1.1.1.1' /etc/openvpn/server/server.conf"
SUBNET=$(python3 -c "import json;print(json.load(open('/etc/ovpnctl/config.json'))['subnet'])")
[ "$SUBNET" != "10.8.0.0" ] && ok "занятая подсеть 10.8.0.0/24 обойдена, выбрана $SUBNET" \
    || bad "выбрана занятая подсеть 10.8.0.0/24"
chk "конфиг сервера использует выбранную подсеть" "grep -q \"server $SUBNET\" /etc/openvpn/server/server.conf"
chk "код разложен в /opt/ovpnctl" "test -f /opt/ovpnctl/lib/ovpnctl/cli.py"

echo; echo "=== повторный запуск = обновление ==="
CA_BEFORE=$(openssl x509 -in /etc/ovpnctl/pki/ca.crt -noout -fingerprint)
OVPN_REPO_URL=http://127.0.0.1:8000/repo OVPN_REPO_BRANCH=master \
  bash <(cat /src/install.sh) > /var/log/install2.log 2>&1 </dev/null \
  && ok "повторный запуск отработал" || { bad "повторный запуск"; tail -15 /var/log/install2.log; }
chk "сообщение про повторный запуск" "grep -q 'сервер не пересоздавался' /var/log/install2.log"
chk "видно, что код той же сборки"   "grep -q 'Код уже актуален' /var/log/install2.log"

# реальное обновление кода: портим установленный файл и ставим заново
sed -i 's/ovpnctl — управление OpenVPN/ЗАМЕНЁННЫЙ ЗАГОЛОВОК/' /opt/ovpnctl/lib/ovpnctl/cli.py
OVPN_REPO_URL=http://127.0.0.1:8000/repo OVPN_REPO_BRANCH=master \
  bash <(cat /src/install.sh) > /var/log/install-upd.log 2>&1 </dev/null
chk "изменённый файл заменён свежим" \
    "! grep -q 'ЗАМЕНЁННЫЙ ЗАГОЛОВОК' /opt/ovpnctl/lib/ovpnctl/cli.py"
chk "в выводе видно обновление сборки" "grep -q 'Код обновлён: сборка' /var/log/install-upd.log"
chk "ovpnctl работает после обновления" "ovpnctl --version"
[ "$CA_BEFORE" = "$(openssl x509 -in /etc/ovpnctl/pki/ca.crt -noout -fingerprint)" ] \
  && ok "PKI не тронут" || bad "PKI перезаписан"
chk "профиль клиента на месте" "test -s /etc/ovpnctl/profiles/first.ovpn"

echo; echo "=== установка поверх настроенного сервера запрещена ==="
ovpnctl setup >/var/log/setup-again.log 2>&1 && bad "setup согласился поставить поверх" \
    || ok "setup отказывается ставить поверх"
chk "в отказе есть подсказка про uninstall" "grep -q 'ovpnctl uninstall' /var/log/setup-again.log"

echo; echo "=== чистая переустановка: uninstall + установка ==="
CA_OLD=$(openssl x509 -in /etc/ovpnctl/pki/ca.crt -noout -fingerprint)
ovpnctl uninstall -y >/var/log/uninstall.log 2>&1 && ok "uninstall отработал" || bad "uninstall"
chk "состояние сохранено в архив /root" "ls /root/ovpnctl-backup-*.tar.gz"
chk "каталог /etc/ovpnctl удалён"       "! test -d /etc/ovpnctl"
OVPN_REPO_URL=http://127.0.0.1:8000/repo OVPN_REPO_BRANCH=master \
  bash <(cat /src/install.sh) > /var/log/install3.log 2>&1 </dev/null \
  && ok "повторная установка с нуля прошла" || { bad "повторная установка"; tail -15 /var/log/install3.log; }
[ "$CA_OLD" != "$(openssl x509 -in /etc/ovpnctl/pki/ca.crt -noout -fingerprint)" ] \
  && ok "создан новый CA (чистая установка)" || bad "CA остался прежним"

echo; echo "============================================================"
echo "ИТОГ: пройдено $PASS, провалено $FAIL"
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
