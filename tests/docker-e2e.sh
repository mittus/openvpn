#!/usr/bin/env bash
# Полный end-to-end прогон в контейнере: установка, запуск демона, подключение
# настоящего клиента по .ovpn, отзыв, ротация CA, а затем сценарий с ufw.
#
#   bash tests/docker-e2e.sh debian:12 ubuntu:22.04 …
#   SCENARIOS="ufw" bash tests/docker-e2e.sh debian:12      # только один сценарий
#   сценарии: install (установка одной командой), e2e (полный цикл), ufw
#
# Нужны: docker, /dev/net/tun на хосте. Контейнер получает NET_ADMIN/NET_RAW.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(dirname "$HERE")"
IMAGES=("$@")
[ "${#IMAGES[@]}" -eq 0 ] && IMAGES=(debian:12 debian:11 debian:13 ubuntu:22.04 ubuntu:24.04)

SCENARIOS="${SCENARIOS:-install e2e ufw}"

rc=0
for image in "${IMAGES[@]}"; do
    for scenario in $SCENARIOS; do
        case "$scenario" in
            install) script="container-install.sh" ;;
            e2e)     script="container-e2e.sh" ;;
            ufw)     script="container-ufw.sh" ;;
            *)   echo "неизвестный сценарий: $scenario" >&2; exit 2 ;;
        esac
        echo "########## $image :: $scenario ##########"
        docker run --rm --cap-add NET_ADMIN --cap-add NET_RAW --device /dev/net/tun \
            -v "$SRC":/src:ro -v "$HERE/$script":/test.sh:ro \
            --entrypoint bash "$image" /test.sh || rc=1
    done
done
exit $rc
