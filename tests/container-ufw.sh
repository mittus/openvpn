#!/usr/bin/env bash
# Сценарий проверки интеграции с ufw: команда открывает только порт VPN,
# правила NAT/пересылки остаются за ovpnctl-firewall.service и ufw их не ломает.
set -u
export DEBIAN_FRONTEND=noninteractive
PASS=0; FAIL=0; SKIP=0
ok(){ PASS=$((PASS+1)); echo "  [ok]   $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }
skip(){ SKIP=$((SKIP+1)); echo "  [skip] $1"; }
chk(){ if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

echo "=== система: $(. /etc/os-release; echo "$PRETTY_NAME") ==="
mkdir -p /run/systemd/system
printf '#!/bin/sh\nexit 0\n' > /usr/local/bin/systemctl; chmod +x /usr/local/bin/systemctl; hash -r
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq --no-install-recommends iputils-ping procps iproute2 >/dev/null 2>&1

cd /src
bash install.sh >/var/log/install.log 2>&1 </dev/null \
  && ok "установка" || { bad "установка"; tail -20 /var/log/install.log; }
ovpnctl set --endpoint 127.0.0.1 >/dev/null 2>&1
ovpnctl client add tester >/dev/null 2>&1
/etc/ovpnctl/firewall.sh up

echo; echo "=== ovpnctl ufw ==="
chk "ufw изначально отсутствует" "! command -v ufw"
ovpnctl ufw >/var/log/ufw-refuse.log 2>&1 && bad "без --install команда должна отказываться" || ok "без --install команда отказывается"
grep -q "ovpnctl ufw --install" /var/log/ufw-refuse.log && ok "в отказе есть подсказка" || bad "нет подсказки"

ovpnctl ufw --install --ssh >/var/log/ufw-install.log 2>&1 && ok "ovpnctl ufw --install --ssh" \
  || { bad "ovpnctl ufw --install"; tail -20 /var/log/ufw-install.log; }
sed -n '1,12p' /var/log/ufw-install.log | sed 's/^/    /'

echo; echo "=== что именно добавлено (и чего НЕ добавлено) ==="
chk "порт 1194/udp разрешён"          "ufw show added | grep -E 'allow 1194/udp'"
chk "SSH разрешён"                    "ufw show added | grep -E 'allow 22/tcp'"
chk "нет лишних правил на tun0"       "! ufw show added | grep -q 'tun0'"
chk "нет route-правил"                "! ufw show added | grep -q 'route allow'"
chk "before.rules не тронут"          "! grep -q 'OVPNCTL' /etc/ufw/before.rules"
chk "DEFAULT_FORWARD_POLICY не менялся" "grep -q 'DEFAULT_FORWARD_POLICY=\"DROP\"' /etc/default/ufw"
chk "флаг в config.json"              "grep -q '\"ufw_configured\": true' /etc/ovpnctl/config.json"
echo "    --- ufw show added ---"; ufw show added 2>/dev/null | sed 's/^/    /'

echo; echo "=== ufw включён: VPN должен работать ==="
if ufw --force enable >/var/log/ufw-enable.log 2>&1 && ufw status | grep -q "Status: active"; then
    ok "ufw включён"
    NAT_BEFORE=$(iptables -t nat -S POSTROUTING | grep -c MASQUERADE)
    FWD_BEFORE=$(iptables -S FORWARD | grep -c 'tun+')
    ufw reload >/dev/null 2>&1
    NAT_AFTER=$(iptables -t nat -S POSTROUTING | grep -c MASQUERADE)
    FWD_AFTER=$(iptables -S FORWARD | grep -c 'tun+')
    [ "$NAT_AFTER" = "$NAT_BEFORE" ] && [ "$NAT_AFTER" = "1" ] \
      && ok "правило NAT пережило ufw reload и не задвоилось" \
      || bad "NAT: было $NAT_BEFORE, стало $NAT_AFTER (ожидалось 1)"
    [ "$FWD_AFTER" = "$FWD_BEFORE" ] && ok "правила пересылки пережили ufw reload" \
      || bad "пересылка: было $FWD_BEFORE, стало $FWD_AFTER"

    mkdir -p /run/openvpn-server
    openvpn --config /etc/openvpn/server/server.conf --daemon --log /var/log/ovpn-server.log
    sleep 4
    openvpn --config /etc/ovpnctl/profiles/tester.ovpn --route-nopull --daemon --log /var/log/ovpn-client.log
    sleep 10
    grep -q "Initialization Sequence Completed" /var/log/ovpn-client.log \
      && ok "клиент подключился через активный ufw" \
      || { bad "клиент не подключился при активном ufw"; tail -10 /var/log/ovpn-client.log; }
    chk "пинг до 10.8.0.1" "ping -c 2 -W 3 10.8.0.1"

    skip "блокировку порта без правила ufw проверяет tests/network-e2e.sh (здесь клиент ходит через lo, а его ufw пропускает всегда)"
else
    skip "ufw не запускается в контейнере: $(tail -2 /var/log/ufw-enable.log | tr '\n' ' ')"
fi

echo; echo "=== смена порта переоткрывает его в ufw ==="
ovpnctl set --port 443 --proto tcp >/var/log/ufw-set.log 2>&1 && ok "ovpnctl set --port 443 --proto tcp" \
  || { bad "ovpnctl set"; tail -10 /var/log/ufw-set.log; }
chk "новый порт 443/tcp разрешён"    "ufw show added | grep -E 'allow 443/tcp'"
chk "старое правило 1194/udp убрано" "! ufw show added | grep -E 'allow 1194/udp'"

echo; echo "=== откат ==="
ovpnctl ufw --remove >/var/log/ufw-remove.log 2>&1 && ok "ovpnctl ufw --remove" \
  || { bad "ovpnctl ufw --remove"; tail -10 /var/log/ufw-remove.log; }
chk "правило порта снято"     "! ufw show added | grep -E 'allow 443/tcp'"
chk "SSH-правило не тронуто"  "ufw show added | grep -E 'allow 22/tcp'"

echo; echo "============================================================"
echo "ИТОГ: пройдено $PASS, провалено $FAIL, пропущено $SKIP"
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
