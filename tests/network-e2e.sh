#!/usr/bin/env bash
# Сетевой e2e: сервер, клиент и «внешняя» цель в РАЗНЫХ контейнерах и сетях.
# Проверяет то, что нельзя проверить внутри одного контейнера:
#   * реальную пересылку трафика клиента в сеть за сервером (FORWARD + NAT);
#   * что активный ufw без разрешения порта блокирует подключение;
#   * что правила ovpnctl-firewall переживают ufw enable/reload и не двоятся.
#
#   bash tests/network-e2e.sh [образ]        # по умолчанию debian:12
set -u
IMAGE="${1:-debian:12}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(dirname "$HERE")"
SHARE="$(mktemp -d)"; chmod 777 "$SHARE"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  [ok]   $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }

cleanup() {
    docker rm -f ovpn-server ovpn-client ovpn-target >/dev/null 2>&1
    docker network rm ovpn-lan ovpn-wan >/dev/null 2>&1
    rm -rf "$SHARE" 2>/dev/null || true
}
trap cleanup EXIT
cleanup

echo "=== образ: $IMAGE ==="
docker network create --subnet 10.77.0.0/24 ovpn-lan >/dev/null \
    || { echo "не создать сеть 10.77.0.0/24 — освободите подсеть (docker network prune)"; exit 2; }
docker network create --subnet 10.88.0.0/24 ovpn-wan >/dev/null \
    || { echo "не создать сеть 10.88.0.0/24 — освободите подсеть (docker network prune)"; exit 2; }
docker run -d --name ovpn-target --network ovpn-wan --ip 10.88.0.12 --entrypoint sleep "$IMAGE" infinity >/dev/null
docker run -d --name ovpn-server --network ovpn-lan --ip 10.77.0.10 \
    --cap-add NET_ADMIN --cap-add NET_RAW --device /dev/net/tun \
    -v "$SRC":/src:ro -v "$SHARE":/share --entrypoint sleep "$IMAGE" infinity >/dev/null
docker network connect ovpn-wan ovpn-server
docker run -d --name ovpn-client --network ovpn-lan --ip 10.77.0.11 \
    --cap-add NET_ADMIN --cap-add NET_RAW --device /dev/net/tun \
    -v "$SHARE":/share --entrypoint sleep "$IMAGE" infinity >/dev/null

srv(){ docker exec ovpn-server bash -c "$1"; }
cli(){ docker exec ovpn-client bash -c "$1"; }
probe(){ cli 'ping -c2 -W3 10.88.0.12 >/dev/null 2>&1 && echo ХОДИТ || echo "НЕ ХОДИТ"'; }

srv 'export DEBIAN_FRONTEND=noninteractive
mkdir -p /run/systemd/system /run/openvpn-server
printf "#!/bin/sh\nexit 0\n" >/usr/local/bin/systemctl; chmod +x /usr/local/bin/systemctl; hash -r
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq --no-install-recommends iproute2 iputils-ping procps ufw >/dev/null 2>&1
cd /src && bash install.sh >/var/log/i.log 2>&1 </dev/null
ovpnctl set --endpoint 10.77.0.10 --nic eth1 >/dev/null 2>&1
ovpnctl client add c1 >/dev/null 2>&1
/etc/ovpnctl/firewall.sh up
cp /etc/ovpnctl/profiles/c1.ovpn /share/c1.ovpn; chmod 644 /share/c1.ovpn
openvpn --config /etc/openvpn/server/server.conf --daemon --log /var/log/s.log; sleep 3' >/dev/null 2>&1
srv 'pgrep -f "openvpn --config /etc/openvpn/server" >/dev/null' && ok "сервер запущен" || bad "сервер не запустился"

cli 'export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq --no-install-recommends openvpn iproute2 iputils-ping procps >/dev/null 2>&1' >/dev/null 2>&1

# до подключения к VPN цель обязана быть недоступна — иначе тест ничего не докажет
cli 'ping -c1 -W2 10.88.0.12 >/dev/null 2>&1' && bad "цель доступна напрямую — тест бессмыслен" \
    || ok "до подключения цель за сервером клиенту недоступна"

cli 'openvpn --config /share/c1.ovpn --daemon --log /var/log/c.log; sleep 8' >/dev/null 2>&1
cli 'grep -q "Initialization Sequence Completed" /var/log/c.log' && ok "клиент подключился" || bad "клиент не подключился"
[ "$(probe)" = "ХОДИТ" ] && ok "трафик клиента идёт в сеть за сервером (FORWARD + NAT)" \
    || bad "пересылка не работает даже без ufw"

echo; echo "--- ufw включён, порт VPN разрешён ---"
srv 'ufw allow 22/tcp >/dev/null 2>&1; ovpnctl ufw --install >/dev/null 2>&1; ufw --force enable >/dev/null 2>&1'
srv 'ufw status | grep -q "Status: active"' && ok "ufw активен" || bad "ufw не включился"
[ "$(probe)" = "ХОДИТ" ] && ok "пересылка работает при активном ufw (правил NAT в ufw не требуется)" \
    || bad "пересылка сломалась после включения ufw"
srv 'ufw reload >/dev/null 2>&1'
NAT=$(srv 'iptables -t nat -S POSTROUTING | grep -c MASQUERADE')
[ "$NAT" = "1" ] && ok "после ufw reload ровно одно правило MASQUERADE" || bad "правил MASQUERADE: $NAT"
[ "$(probe)" = "ХОДИТ" ] && ok "пересылка работает после ufw reload" || bad "пересылка отвалилась после ufw reload"

echo; echo "--- порт VPN закрыт в ufw ---"
srv 'ufw delete allow 1194/udp >/dev/null 2>&1; ufw reload >/dev/null 2>&1'
cli 'pkill openvpn; sleep 2; : > /var/log/c2.log; openvpn --config /share/c1.ovpn --daemon --log /var/log/c2.log; sleep 10' >/dev/null 2>&1
cli 'grep -q "Initialization Sequence Completed" /var/log/c2.log' \
    && bad "клиент подключился без разрешения порта в ufw" \
    || ok "без 'ovpnctl ufw' активный ufw блокирует подключение — команда нужна"

echo; echo "--- порт снова открыт ---"
srv 'ovpnctl ufw >/dev/null 2>&1'
cli 'pkill openvpn; sleep 2; : > /var/log/c3.log; openvpn --config /share/c1.ovpn --daemon --log /var/log/c3.log; sleep 10' >/dev/null 2>&1
cli 'grep -q "Initialization Sequence Completed" /var/log/c3.log' && ok "подключение восстановлено после 'ovpnctl ufw'" \
    || bad "подключение не восстановилось"
[ "$(probe)" = "ХОДИТ" ] && ok "трафик через VPN снова ходит" || bad "трафик не ходит"

echo; echo "============================================================"
echo "ИТОГ: пройдено $PASS, провалено $FAIL"
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
