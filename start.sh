#!/usr/bin/env bash
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
export MSYS_NO_PATHCONV=1

IMAGE='ollama/ollama:latest'
MODEL='qwen3-local'
BASE_MODEL='qwen3:14b'
VOLUME='qwen-local-data'
BOOTSTRAP="qwen-download-$$"
BOOTSTRAP_CREATED=0
RESET='' DIM='' CYAN='' GREEN='' RED=''
if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-}" != dumb ]]; then
  RESET=$'\033[0m'; DIM=$'\033[2m'; CYAN=$'\033[36m'; GREEN=$'\033[32m'; RED=$'\033[31m'
fi
log() {
  local level="$1" color="$2"; shift 2
  printf '%s[%s]%s %s%-8s%s %s\n' "$DIM" "$(date '+%H:%M:%S')" "$RESET" "$color" "$level" "$RESET" "$*"
}
info() { log 'ИНФО' "$CYAN" "$@"; }
ok() { log 'ГОТОВО' "$GREEN" "$@"; }
fail() { log 'ОШИБКА' "$RED" "$@" >&2; exit 1; }
cleanup() {
  if [[ "$BOOTSTRAP_CREATED" == 1 ]]; then
    docker rm -f "$BOOTSTRAP" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
trap 'code=$?; log "ОШИБКА" "$RED" "Сбой на строке $LINENO (код $code). Подробности — выше." >&2; exit "$code"' ERR
printf '\n%s%s%s\n\n' "$CYAN" '  QWEN LOCAL · Ollama + Dozzle + OpenCode' "$RESET"
info 'Проверяем Docker и Docker Compose…'
command -v docker >/dev/null || fail 'Docker не найден. Установите Docker Desktop с WSL 2 backend.'
docker info >/dev/null || fail 'Docker недоступен. Запустите Docker Desktop в режиме Linux containers.'
docker compose version >/dev/null
ok 'Docker готов к работе.'
case "${1:-chat}" in
  chat|serve|opencode) ;;
  status) docker compose -f compose.yaml ps; docker compose -f compose.yaml logs --tail 50 dozzle docker-proxy open-webui; exit 0 ;;
  stop) info 'Останавливаем сервисы…'; docker compose -f compose.yaml stop; ok 'Сервисы остановлены. Модель сохранена.'; exit 0 ;;
  *) fail 'Использование: bash start.sh [chat|serve|opencode|stop|status]' ;;
esac
REUSE_SERVICES=0
if [[ "${1:-chat}" == opencode ]]; then
  info 'Проверяем, готовы ли уже локальные сервисы…'
  REUSE_SERVICES=1
  for container in qwen-local qwen-monitor qwen-monitor-proxy qwen-webui; do
    if [[ "$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null || true)" != true ]]; then
      REUSE_SERVICES=0; break
    fi
  done
  if [[ "$REUSE_SERVICES" == 1 ]]; then
    if ! docker exec qwen-local ollama list >/dev/null 2>&1 ||
       ! docker exec qwen-monitor /dozzle healthcheck >/dev/null 2>&1 ||
       ! docker exec qwen-webui python -c 'import urllib.request; urllib.request.urlopen("http://127.0.0.1:8080/health", timeout=3)' >/dev/null 2>&1; then
      REUSE_SERVICES=0
    fi
  fi
fi
if [[ "$REUSE_SERVICES" == 1 ]]; then
  ok 'Сервисы уже работают. Используем их без перезапуска.'
  info 'WebUI: http://127.0.0.1:3000 · Мониторинг: http://127.0.0.1:8080'
else
for image in "$IMAGE" amir20/dozzle:v11.3.0 tecnativa/docker-socket-proxy:latest ghcr.io/open-webui/open-webui:slim; do
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    info "Скачиваем образ: $image…"
    docker pull "$image"
  else
    ok "Образ уже доступен: $image"
  fi
done
docker volume create "$VOLUME" >/dev/null
if ! docker run --rm --network none -v "$VOLUME:/root/.ollama" --entrypoint /bin/sh "$IMAGE" -c 'test -f /root/.ollama/models/manifests/registry.ollama.ai/library/qwen3/14b'; then
  info 'Скачиваем Qwen3 14B (~9,3 ГБ). Нужен интернет; запросов чата здесь нет.'
  docker run -d --memory 16g --memory-swap 16g --cpus 4 --name "$BOOTSTRAP" -e OLLAMA_NO_CLOUD=1 -v "$VOLUME:/root/.ollama" "$IMAGE" >/dev/null
  BOOTSTRAP_CREATED=1
  READY=0
  for ((attempt=0; attempt<60; attempt++)); do
    if docker exec "$BOOTSTRAP" ollama list >/dev/null 2>&1; then READY=1; break; fi
    sleep 1
  done
  if [[ "$READY" != 1 ]]; then
    docker logs "$BOOTSTRAP" >&2
    fail 'Сервис скачивания не запустился за 60 секунд. Логи — выше.'
  fi
  docker exec "$BOOTSTRAP" ollama pull "$BASE_MODEL"
  docker stop "$BOOTSTRAP" >/dev/null
  docker rm "$BOOTSTRAP" >/dev/null
  BOOTSTRAP_CREATED=0
  ok 'Модель скачана и сохранена локально.'
else
  ok 'Модель уже скачана. Используем локальную копию.'
fi
info 'Лимиты: Ollama — 16 ГБ RAM / 4 CPU; мониторинг — 512 МБ RAM / 1 CPU; WebUI — 1 ГБ RAM / 1 CPU.'
info 'Запускаем Ollama и мониторинг…'
info 'Пересоздаём все сервисные контейнеры. Модель и данные сохраняются.'
docker compose -f compose.yaml up -d --force-recreate --remove-orphans
info 'Ожидаем готовности Ollama (до 60 секунд)…'
READY=0
for ((attempt=0; attempt<60; attempt++)); do
  if docker exec qwen-local ollama list >/dev/null 2>&1; then READY=1; break; fi
  sleep 1
done
if [[ "$READY" != 1 ]]; then
  docker logs qwen-local >&2
  fail 'Ollama не запустилась за 60 секунд. Проверьте поддержку GPU в Docker.'
fi
NETWORKS=$(docker inspect qwen-local --format '{{range $name, $settings := .NetworkSettings.Networks}}{{$name}} {{end}}')
[[ "$NETWORKS" == 'qwen-local-network ' ]] || fail 'Сеть контейнера не соответствует конфигурации.'
INTERNAL=$(docker network inspect qwen-local-network --format '{{.Internal}}')
[[ "$INTERNAL" == false ]] || fail 'Исходящий интернет контейнера отключён.'
BINDING=$(docker inspect qwen-local --format '{{range (index .HostConfig.PortBindings "11434/tcp")}}{{.HostIp}}:{{.HostPort}} {{end}}')
[[ "$BINDING" == '127.0.0.1:11434 ' ]] || fail 'Порт API должен быть привязан только к 127.0.0.1:11434.'
ok 'Ollama готова. Привязка API проверена.'
info 'Ожидаем готовности Dozzle (до 60 секунд)…'
READY=0
for ((attempt=0; attempt<60; attempt++)); do
  if docker exec qwen-monitor /dozzle healthcheck >/dev/null 2>&1; then READY=1; break; fi
  sleep 1
done
if [[ "$READY" != 1 ]]; then
  docker compose -f compose.yaml logs --tail 50 dozzle docker-proxy >&2
  fail 'Мониторинг не запустился за 60 секунд. Логи — выше.'
fi
info 'Ожидаем готовности Open WebUI (до 180 секунд)…'
READY=0
for ((attempt=0; attempt<90; attempt++)); do
  if docker exec qwen-webui python -c 'import urllib.request; urllib.request.urlopen("http://127.0.0.1:8080/health", timeout=3)' >/dev/null 2>&1; then READY=1; break; fi
  sleep 2
done
if [[ "$READY" != 1 ]]; then
  docker compose -f compose.yaml logs --tail 50 open-webui >&2
  fail 'Open WebUI не запустился. Логи — выше. Диагностика: bash start.sh status'
fi
ok 'Чат в браузере: http://127.0.0.1:3000'
ok 'Мониторинг: http://127.0.0.1:8080'
if command -v curl >/dev/null; then
  PORT_ERRORS=0
  for url in http://127.0.0.1:11434/api/tags http://127.0.0.1:8080 http://127.0.0.1:3000/health; do
    PORT_READY=0
    for ((attempt=0; attempt<10; attempt++)); do
      if curl --noproxy "*" --fail --silent --connect-timeout 2 --max-time 5 "$url" >/dev/null; then
        PORT_READY=1; break
      fi
      sleep 1
    done
    if [[ "$PORT_READY" == 1 ]]; then
      ok "Порт доступен с компьютера: $url"
    else
      PORT_ERRORS=1
      log 'ОШИБКА' "$RED" "Не удалось подключиться: $url. Подробности curl:" >&2
      curl --noproxy "*" --fail --show-error --silent --connect-timeout 2 --max-time 5 "$url" >/dev/null || true
    fi
  done
  if [[ "$PORT_ERRORS" == 1 ]]; then
    info 'Состояние контейнеров и опубликованные порты:'
    docker compose -f compose.yaml ps
    docker port qwen-local || true
    docker port qwen-monitor || true
    docker port qwen-webui || true
    log 'ОШИБКА' "$RED" 'Сервисы отвечают внутри Docker, но часть портов недоступна из этого терминала. Проверьте опубликованные порты выше; в WSL попробуйте URL из браузера Windows. Логи: bash start.sh status' >&2
  fi
fi
ok 'API: http://127.0.0.1:11434 · Модель: qwen3-local'
fi
info 'Применяем системную инструкцию к локальной модели…'
docker cp ./Modelfile qwen-local:/tmp/qwen-local.Modelfile
docker exec qwen-local ollama create "$MODEL" -f /tmp/qwen-local.Modelfile
ok 'Локальная модель qwen3-local готова.'
if [[ "${1:-chat}" == opencode ]]; then
  info 'Открываем OpenCode с локальной Qwen3 14B…'
  if command -v opencode >/dev/null 2>&1; then
    opencode --model ollama/qwen3-local
  elif command -v npx >/dev/null 2>&1; then
    info 'OpenCode отсутствует в PATH. Запускаем через npx; при первом запуске пакет будет скачан.'
    npx --yes --package opencode-ai opencode --model ollama/qwen3-local
  elif command -v npx.cmd >/dev/null 2>&1; then
    info 'Запускаем OpenCode через npx.cmd; при первом запуске пакет будет скачан.'
    npx.cmd --yes --package opencode-ai opencode --model ollama/qwen3-local
  else
    fail 'Не найдены OpenCode и Node.js. Установите Node.js LTS, откройте новый терминал и повторите запуск. Либо запустите bash start.sh serve для чата в браузере.'
  fi
  exit 0
fi
if [[ "${1:-chat}" == serve ]]; then
  info 'Чат: bash start.sh · OpenCode: bash start.sh opencode'
  info 'Остановка сервисов: bash start.sh stop'
  exit 0
fi
[[ -t 0 && -t 1 ]] || fail 'Для чата нужен интерактивный терминал. Запуск только API: bash start.sh serve'
info 'Открываем чат. Первый ответ может занять время: модель загружается в память.'
info 'Выход: /bye · Остановка сервисов: bash start.sh stop'
if command -v winpty >/dev/null 2>&1 && [[ "${TERM:-}" == xterm* ]] && [[ "${MSYSTEM:-}" != '' ]]; then
  winpty docker exec -it qwen-local ollama run "$MODEL"
else
  docker exec -it qwen-local ollama run "$MODEL"
fi
