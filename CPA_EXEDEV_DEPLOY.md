# CPA+MLflow на exe.dev — промпт для агента-деплоера
Версия 0.1 · 2026-09-14 · вход для агента, разворачивающего связку
MLflow AI Gateway → CLIProxyAPI на exe.dev. Источники по exe.dev:
llms.txt, docs (proxy, customization, integrations, vm-to-vm, regions).

---

## Контекст и целевая топология

Оператор даёт агентам MLflow AI Gateway как единый LLM-эндпоинт. За шлюзом
должен стоять CLIProxyAPI (github.com/router-for-me/CLIProxyAPI) — локальный
LLМ-шлюз с подписными аккаунтами CLI-агентов (OAuth от Claude/Codex/Gemini/Kimi).
MLflow gateway подсосан к CPA как один из provider'ов, CPA уже держит все
аккаунты. Агенты видят только MLflow-эндпоинт с ключом; CPA для них —
невидимый upstream.

Целевая схема на exe.dev (одна VM, минимум движущихся частей):

```
[агенты: Shelley/CLI на других VM или локально]
        │ HTTPS + bearer (MLFLOW_GATEWAY_KEY)
        ▼
  https://<vm>.exe.xyz[:5000]        ← exe.dev HTTPS-proxy (private по умолчанию!)
        │
  MLflow AI Gateway (порт 5000 внутри VM)
        │  route → upstream http://127.0.0.1:8317/v1
        ▼
  CLIProxyAPI (127.0.0.1:8317, api-key CPA_API_KEY)
        │  OAuth-аккаунты из /home/exedev/.cli-proxy-api/auths
        ▼
  api.anthropic.com / chatgpt.com / gemini / kimi / xai
```

Одна VM на всю связку достаточна (MLflow gateway легковесный, CPA тоже);
VM-to-VM peer integration добавим только если CPA выносится на отдельную VM.

## Фаза 0 — создание VM

- `ssh exe.dev new --name llm-gw --image=exeuntu` (или дефолтный образ).
- Регион: TYO или LAX — ближе к апстримам и оператору (JST); регион аккаунта
  фиксирует размещение всех VM.
- Проверь `ssh llm-gw.exe.xyz uname -a`; пользователь по умолчанию `exedev`
  с sudo. НЕ создавай отдельных юзеров — exe.dev модель "одна VM = один юзер".
- Опционально закрепи цель через `ssh exe.dev tag llm-gw llm-infra` — удобно
  для auto-attach интеграций.

## Фаза 1 — CLIProxyAPI (те же правила безопасности, что в CPA_DEPLOY_PROMPT)

1. Сборка из pinned-коммита (не релизные бинари):
   `sudo apt-get install -y golang git` (или скачивание Go с go.dev),
   `git clone https://github.com/router-for-me/CLIProxyAPI /opt/cliproxyapi-src`,
   `git checkout <пиннед-коммит>`, `go build -o /usr/local/bin/cli-proxy-api ./cmd/server`.
2. Рабочая директория `/home/exedev/.cli-proxy-api/` (это дефолтный auth-dir
   CPA — auth-файлы лягут туда сами). Конфиг `/home/exedev/.cli-proxy-api/config.yaml`:

```yaml
host: "127.0.0.1"
port: 8317
auth-dir: "/home/exedev/.cli-proxy-api/auths"
api-keys:
  - "<CPA_API_KEY: openssl rand -hex 32>"
remote-management:
  secret-key: "<MGMT_KEY: openssl rand -hex 32>"
  allow-remote: false
  disable-control-panel: true      # панель вообще не нужна, головная боль меньше
  disable-auto-update-panel: true
request-log: false
logging-to-file: true
logs-max-total-size-mb: 512
debug: false
plugins:
  enabled: false
usage-statistics-enabled: false
```

3. systemd-сервис `cliproxyapi.service` (User=exedev, Restart=on-failure,
   ExecStart с `--config ... --local-model`). `--local-model` обязателен.
4. Egress: на VM общий доступ в интернет по умолчанию есть; NFTABLES per-UID
   ограничение делаем только если оператор попросил (на exe.dev VM уже изолирована;
   лишний фаервол опционален). Запиши в отчёт, что egress открыт.
5. Первый логин подписочных аккаунтов: OAuth-флоу CPA — `cli-proxy-api` без
   отдельной login-команды запускает callback-сервер при старте; выполни
   логины по инструкциям вывода сервиса (URL авторизации), токены упадут в
   auth-dir. Если логин требует браузера на машине оператора — согласуй с
   оператором, не импровизируй с headless-браузером без спроса.

## Фаза 2 — MLflow AI Gateway

1. `pip install 'mlflow[gateway]'` в venv `/opt/mlflow-venv` (или uv).
2. Конфиг `/home/exedev/mlflow-config.yaml`:

```yaml
route_type: llm/v1/chat  # базовый; маршруты добавляются CLI-командами
# Для AI Gateway используется CLI:
# mlflow gateway start --config-path ... --host 127.0.0.1 --port 5000
```

Фактические маршруты создаются через `mlflow gateway` CLI (routes add),
схема:

```bash
source /opt/mlflow-venv/bin/activate
mlflow gateway start --config-path /home/exedev/mlflow-gateway.yaml \
  --host 127.0.0.1 --port 5000 &
# gateway.yaml: provider openai-compatible, api_base http://127.0.0.1:8317/v1,
# key CPA_API_KEY; маршруты: claude-*, gpt-*, gemini-* (по моделям из /v1/models CPA)
```

3. systemd-юнит `mlflow-gateway.service` (User=exedev, после
   cliproxyapi.service, ExecStart с полным конфигом маршрутов).
4. Проверка: `curl -s http://127.0.0.1:5000/health` — 200;
   `curl -s -H "Authorization: Bearer <MLFLOW_KEY>" -d '{"route":"...","payload":{...}}' .../invocations` — ответ модели.

## Фаза 2.5 — exe.dev LLM integration как дополнительный upstream в MLflow

У exe.dev есть собственный managed LLM-шлюз (интеграция `llm`, дефолтное имя,
hostname `https://llm.int.exe.xyz`): exe.dev-управляемые креды Anthropic/OpenAI/
Fireworks с месячным токен-аллокейшеном подписки. Дополнительно включить его
в MLflow как ещё один provider — полезно для дешёвых фоновых задач и как
fallback, когда подписные CPA-аккаунты упираются в квоты.

Механика (важно: направление интеграции — ИЗ VM, а не в неё):

1. На llm-gw VM дефолтная интеграция `llm` уже прицеплена (`auto:all`) —
   проверь: `curl -s https://llm.int.exe.xyz/v1/models` из VM работает, ключей
   на VM нет (секрет живёт на edge exe.dev).
2. В MLflow gateway добавь маршруты на exe.dev-шлюз как на обычный
   OpenAI-compatible провайдер: api_base `https://llm.int.exe.xyz/v1`
   (НЕ http://169.254.169.254/... — metadata-endpoint депрекейтед с 2026-08-03),
   auth — без ключа (edge авторизует по факту прицепленности VM) или с
   integration-токеном, если MLflow требует непустой bearer.
3. Не путать источники: exe.dev-шлюз — это ЕЩЁ один upstream, независимый от
   CPA. MLflow роутит по имени модели: подписные модели (claude-code-тарифы,
   свои аккаунты) → CPA-маршруты; managed-модели (дешёвый фон) → llm.int.
   Роутинг-приоритеты задаются в конфиге MLflow.

## Фаза 3 — публикация наружу (exe.dev HTTP proxy)

- MLflow слушает 127.0.0.1 — наружу его выставляет exe.dev proxy:
  `ssh exe.dev share port llm-gw 5000`.
- Приватность: по умолчанию `https://llm-gw.exe.xyz:5000` доступен только
  пользователям с доступом к VM (exe.dev login-гейт). Публичным НЕ делать:
  `share set-public` не запускать. Агенты с других VM аутентифицируются через
  exe.dev-логин (если агент — Shelley на VM того же аккаунта, он получит
  доступ автоматически) или через bearer MLFLOW_GATEWAY_KEY (в конфиге gateway
  включи auth-заголовок, если MLflow gateway его поддерживает; если нет —
  доступ контролируется exe.dev-гейтом, это приемлемо).
- Альтернатива для других VM оператора (чище): peer integration
  `ssh exe.dev integrations add http-proxy --name llm --target https://llm-gw.exe.xyz:5000/ --peer --attach vm:<agent-vm>`
  — тогда агент-VM зовёт `http://llm.int.exe.xyz/...` без кредов вообще,
  CPA-ключ и MLflow-ключ не покидают серверную VM. ПРЕДПОЧТИТЕЛЬНЫЙ путь.

## Фаза 4 — приёмка (приложить выводы)

1. `systemctl status cliproxyapi mlflow-gateway` — оба active.
2. Из другой VM (или через peer-integration hostname): запрос к
   MLflow-эндпоинту с реальным промптом — ответ модели пришёл, трейс
   прошёл MLflow→CPA→upstream. Проверь в CPA-логах (`journalctl -u cliproxyapi`):
   запрос был, тело не залогировано, upstream 200.
3. `curl http://127.0.0.1:8317/v1/models` с CPA_API_KEY — список моделей.
4. `ls -la /home/exedev/.cli-proxy-api/auths` — auth-файлы есть, 0600.
5. `ssh exe.dev stat llm-gw` — CPU/RAM/disk в норме, нет.swap-паники.
6. Peer-integration (если делали): из agent-VM `curl http://llm.int.exe.xyz/health` — 200.

## Фаза 5 — опция: публичный HTTPS base_url

Если нужен ПУБЛИЧНЫЙ base_url (клиенты вне exe.dev-аккаунта: локальные
инструменты, сторонние сервисы, обмен с партнёрами):

1. **Публичный режим exe.dev proxy**: `ssh exe.dev share set-public llm-gw`
   → `https://llm-gw.exe.xyz:5000` открывается всему интернету. TLS, домен
   и X-Forwarded-* — на exe.dev, ноль усилий.
2. **ОБЯЗАТЕЛЬНО свой auth-слой на MLflow/gateway**: публичный прокси без
   exe.dev-логина не даёт никакой аутентификации — все анонимны. Варианты:
   - bearer-ключ на MLflow-gateway (лучший): ключ в конфиге, клиенты шлют
     `Authorization: Bearer ...`;
   - если gateway-слой слаб — маленький nginx/caddy перед ним с
     `Authorization`-проверкой и 401;
   - «Login with exe» (`https://llm-gw.exe.xyz/__exe.dev/login`) — подходит
     только для человеко-браузерных клиентов, НЕ для programmatic SDK:
     требует exe.dev-аккаунт у каждого клиента, куки не дружат с curl.
3. **IP-фильтр если клиенты известны**: nftables на VM: 443/5000 только с
     списка IP-клиентов поверх (или вместо) bearer.
4. Rate-limit на publik-эндпоинте — обязательно (иначе этот URL = открытая
   дверь в твои подписные квоты): nginx `limit_req` или gateway-уровень.
5. `X-ExeDev-UserID`/`X-ExeDev-Email` на приватном прокси можно использовать
   для per-user логирования; на публичном они появляются только у тех, кто
   прошёл exe.dev-логин (большинство programmatic-клиентов — нет).

Итог по умолчанию: peer-integration для своих VM (безкредово), bearer-ключ
через публичный `llm-gw.exe.xyz` для внешних, оба — с rate-limit.

## Ограничения

- Домашний кластер CPA (Home/-home-jwt) не включать; плагины, TUI,
  request-log — не включать.
- Не выставлять MLflow/CPA порты публично (только exe.dev private-gейт или peer).
- Не модифицировать go.mod/go.sum; пиннед-коммит CPA зафиксировать в отчёте.
- OAuth-логины аккаунтов — согласовывать с оператором (каждый логин виден
  провайдеру как новое устройство).
- Если exe.dev VM не в том регионе, который нужен оператору (JST-близость),
  остановись и спроси (регион меняется только на уровне аккаунта).

## Открытые вопросы (решает оператор до запуска агента)

1. Одна VM или две (CPA отдельно от MLflow)? Рекомендация: одна; разделение
   нужно только если MLflow-гейтвей будет публичным для третьих лиц.
2. Peer-integration для агентских VM (безкредовый путь) или bearer-ключи?
   Рекомендация: peer для своих VM, bearer — для внешних клиентов.
3. Резервирование: вторая VM с холодной копией CPA-конфига и auth-дир
   (снапшот auth-файлов зашифрован age) — делать сейчас или отложить.
