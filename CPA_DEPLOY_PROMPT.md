# CPA DEPLOY — промпт для агента-деплоера CLIProxyAPI на сервер

Использовать как инструкцию/system-кромку для агента, разворачивающего
CLIProxyAPI на выделенном сервере в безопасном соло-режиме.

---

Ты разворачиваешь CLIProxyAPI (github.com/router-for-me/CLIProxyAPI) на этом
сервере как локальный LLM-шлюз для нескольких подписочных аккаунтов CLI-агентов.
Цель — безопасный изолированный деплой: минимум внешних зависимостей, все
исходящие соединения — только к апстрим-провайдерам LLM, никакой лишней
телеметрии.

## Режим и источник сборки

1. Собери из исходников (не используй их релизные бинари и Docker-образ):
   `git clone https://github.com/router-for-me/CLIProxyAPI && cd CLIProxyAPI
   && git checkout <пиннед-коммит, зафиксируй хэш> && go build -o cli-proxy-api ./cmd/server`.
   Go брать с официального сайта; go.sum в репо — контейнер зависимостей.
2. Соло-режим: НЕ подключай Home-кластер (`home.enabled` не задавать,
   `-home-jwt`/`HOME_JWT` не использовать), TUI не нужен — headless-сервис.
3. Пользователь для сервиса: выделенный непривилегированный `cliproxy`,
   home `/home/cliproxy`, shell `/usr/sbin/nologin`.

## Конфиг (жёсткие требования безопасности)

`/home/cliproxy/config.yaml` (0600, владелец cliproxy):

```yaml
host: "127.0.0.1"          # слушаем только localhost; наружу — через реверс-прокси
port: 8317
auth-dir: "/home/cliproxy/auths"
api-keys:
  - "<сгенерируй сильный ключ для клиентов>"
remote-management:
  secret-key: "<сгенерируй сильный management-ключ>"
  allow-remote: false
  disable-control-panel: false
  disable-auto-update-panel: true   # панель скачивается один раз, автообновление OFF
request-log: false                   # тела запросов/ответов НЕ пишем на диск
logging-to-file: true
logs-max-total-size-mb: 512         # жёсткий лимит логов
debug: false
plugins:
  enabled: false
usage-statistics-enabled: false     # выключено, пока нет необходимости
```

Ключи генерируй сам (`openssl rand -hex 32`), не оставляй плейсхолдеры.

## Обязательные флаги/проверки после запуска

- Запуск сервиса: systemd unit `cliproxyapi.service` с `ExecStart=/usr/local/bin/cli-proxy-api
  --config /home/cliproxy/config.yaml --local-model`, `User=cliproxy`,
  `Restart=on-failure`, `After=network-online.target`.
  `--local-model` ОБЯЗАТЕЛЕН: отключает периодические загрузки model-каталогов
  с их серверов (models.router-for.me / raw.githubusercontent).
- egress-файрвол для процесса/юзера cliproxy: разрешить ТОЛЬКО домены апстримов
  (api.anthropic.com, platform.claude.com, claude.ai, api.openai.com,
  chatgpt.com, auth.openai.com, gemini/kimi/xai-эндпоинты по факту используемых
  аккаунтов) + DNS + NTP. Запретить: *.router-for.me, models.router-for.me,
  cpamc.router-for.me, api.github.com, raw.githubusercontent.com (после первичной
  загрузки панели, если панель вообще включена). Реализация: nftables
  per-UID-правила или proxy-цепочка. Проверь после старта: `ss -tp` от юзера
  cliproxy не должен показывать соединения к запретным доменам.
- auth-файлы (OAuth-токены подписок): `/home/cliproxy/auths/`, права 0600,
  владелец cliproxy. После первого логина через OAuth-флоу (руками один раз,
  `--login-flow` CLI не предусмотрен — используй вывод `cli-proxy-api` с URL
  авторизации) убедись, что токены легли в auth-dir и права правильные.
- Проверь отсутствие телеметрии: включи debug на 10 минут, убедись, что нет
  обращений к чему-либо кроме апстримов и локального management; верни debug: false.

## Приёмка (проверь и приложи выводы)

1. `systemctl status cliproxyapi` — active, без рестарт-лупов.
2. curl на 127.0.0.1:8317 health/models endpoint с api-key — 200.
3. Один реальный запрос через прокси (маленький промпт) — ответ пришёл,
   в auth-dir появился/обновился токен, в логах нет POST-тел в stdout.
4. `ss -tnp | grep cli-proxy` — только разрешённые egress-соединения.
5. Файрвол-лог: попытки к запретным доменам (если были) — задокументируй.
6. `ls -la /home/cliproxy/auths` — 0600.

## Ограничения (не делай)

- Не включай Home/кластер, TUI, плагины, request-log, usage-statistics без
  явного указания.
- Не используй их релизные бинари/Docker (собирай из pinned-коммита).
- Не выставляй порт наружу (только localhost + реверс-прокси с auth, если нужен
  удалённый доступ).
- Не правь go.mod/go.sum, не добавляй зависимости при сборке.
