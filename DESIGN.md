# MIMIC — дизайн-документ
**Прокси-окружение для реверс-инжиниринга и использования подписочных квот CLI-агентов**
v0.1 · 2026-09-14 · статус: на review · рабочее имя MIMIC (мимикрия под нативных клиентов; заменимо)

---

## 1. Задача и позиционирование

CLI-агенты (Claude Code, Codex, Gemini CLI, Kimi Code, Qwen Code) продают по подписке квоту,
на порядок выгоднее, чем их же pay-per-token API. Цель MIMIC — окружение, которое:

1. Проксирует стандартные API (OpenAI-compatible, Anthropic, Gemini) **на подписочные креды**,
   сохраняя wire-фиделити настоящего CLI-клиента (TLS, HTTP/2, заголовки, беты, identity).
2. **Автоматически распознаёт дрифт** протоколов нативных клиентов (новые заголовки, беты,
   формы JSON) и обновляет «персоны» без ручного реверса и без релиза кода.
3. Побеждает CLIProxyAPI по всем осям: фиделити, устойчивость к дрифту, надёжность,
   наблюдаемость, производительность, безопасность цепочки поставок.

Не-цели: перепродажа чужих аккаунтов, обход оплаты, multi-tenant SaaS из коробки
(одиночный оператор с флотом своих кредов; кластеризация — фаза P4).

---

## 2. Аудит CLIProxyAPI: наследуем и исправляем

Клон аудита: `~/dev/audit/CLIProxyAPI` (все ссылки ниже — файлы в нём).

### 2.1 Что наследуем (наш паритет-минимум)

- Глубокая доменная логика Claude-фиделити: упорядоченные beta-профили, casing-карты
  заголовков, device identity, session continuity, helper-профили Haiku.
- Распознавание нативного клиента «4 сигнала + allowlist entrypoints».
- OAuth-флоу Claude с PKCE, refresh с singleflight и backoff.
- Квоты из заголовков `Anthropic-Ratelimit-Unified-*`, cooldown с fuzz.
- Канонический IR для thinking/reasoning (canonical config → per-provider).
- Плагины, storage-бэкенды, кластер — как направления фаз.

### 2.2 Что исправляем (структурные слабости)

| Проблема CPA | Факт | Решение в MIMIC |
|---|---|---|
| Fingerprint захардкожен в коде | пины `2.1.258`, `sdk 0.112.1` в комментариях и константах; `claude_executor_request.go` — 2514 строк, identity/beta/transport слиты в один файл | Декларативные версионируемые **персоны** (JSON-бандлы) + реестр, hot-swap без релиза |
| Измерения ручные | «Verified against api.anthropic.com with native 2.1.258 captures on interactive, non-interactive, subagent…» — труд людей, нет конвейера | **Radar**: авто-рекордер → корпус → диффы → оракул → канарейка |
| Дрифт уже наступил | npm latest: `@anthropic-ai/claude-code` **2.1.270** (пин 2.1.258), `@anthropic-ai/sdk` **0.125.0** (пин 0.112.1), `@openai/codex` 0.154.0 (совпадает) | Version-watch триггерит авто-захват новой версии CLI |
| Хрупкость трансляторов | AGENTS.md запрещает standalone-правки `internal/translator/` — код под мораторием | Golden-тесты, автогенерируемые из корпуса Radar |
| Supply chain | management-панель скачивается с GitHub в рантайме (`managementasset`) | Все ассеты вендорятся в бинарник с чексуммами |
| Модель конкурентности | Go-горутины + мьютексы; в репо есть `*_auth_race_test.go` | Actor-модель BEAM: актор на кред, супервизия, изоляция сбоев |
| Транспортная честность | у CPA уже есть utls (OAuth) и casing-карты — но разнесены и не версионируются | Единый слой wire-fidelity в Rust NIF с профилями |

---

## 3. Стек и обоснование

### 3.1 Распределение

| Слой | Язык | Почему |
|---|---|---|
| Оркестрация: ingress, роутинг, диалекты, флот кредов, квоты, конфиг, control plane | **Gleam** (BEAM) | Actor-модель = модель предметной области (актор-на-кред, актор-на-сессию); супервизия и hot-reload нативны; mist 6.0.3 — зрелый HTTP-сервер с SSE/WebSocket; отказоустойчивость без ручных мьютексов |
| Wire-fidelity egress, TLS/H2-имперсонизация, парсинг/диффы корпуса, SIMD-JSON | **Rust** (NIF через rustler) | wreq 0.16: BoringSSL + программируемый ClientHello, JA3/JA4, HTTP/2-паритет; rustler — индустриальный стандарт BEAM-NIF; simd-json, zstd, h2 — готовые детали |
| (опция, не обязательна) автономный сниффер-бинарь | Zig | Нет сейчас; см. 3.2 |

### 3.2 Почему Rust, а не Zig

| Критерий | Rust | Zig |
|---|---|---|
| TLS-имперсонизация (порядок extensions, curves, sigalgs, ALPN) | wreq (BoringSSL), rustls с кастомным ClientHello — готово | std.crypto.tls не даёт контроля над ClientHello; свой TLS-стек = месяцы |
| HTTP/2-фиделити (SETTINGS, порядок фреймов, HPACK-динамика) | крейт h2, wreq «H2 parity» | нет эквивалента |
| BEAM FFI | rustler (resource-объекты, dirty schedulers, enif_send) | zigler существует, но экосистема тоньше |
| Быстрый JSON/корпус | simd-json, zstd, rkyv | вручную |
| Зрелость для этой ниши | rustls/utls-мир — это ровно ниша «protocol matching» | — |

Zig хорош там, где нужен крошечный самостоятельный бинарник; вся реверс-часть живёт
от экосистемы имперсонизации, которой в Zig нет. Решение: **Rust**. Zig оставляем
как запасной вариант для будущего автономного pcap-сниффера (P4+), не раньше.

### 3.3 Правила NIF-интеграции (критично)

- Никаких долгих NIF-вызовов на шедулерах BEAM: egress-соединение владеется Rust-потоком,
  чанки тела приходят в Gleam-процессы через `enif_send` (сообщения), NIF-вызовы короткие.
- Rust-сторона не знает бизнес-логики; контракт — байты фреймов + события.
- Watchdog: egress-актор отслеживает живость Rust-потока; падение NIF не роняет VM
  (rustler resource + супервизор перезапускает egress-актора).

---

## 4. Архитектура

```
                     ┌────────────────────────── Control plane ──────────────────────────┐
                     │  Config(TOML, hot) · Persona Registry · Management API · Метрики   │
                     └───────────▲──────────────────────────────▲──────────────────────┘
                                 │ supervise/reload             │
   клиенты ──► Ingress (mist) ──┴──► Recognizer ──► Dialect/IR ──► Router ──► Fleet (акторы кредов)
   (SDK/CLI)    SSE · WS · h1/h2         │                          квоты, cooldown, sticky
                                          │                                │
                                          ▼                                ▼
                                   Cloak (если не native)         Persona Engine ──► Egress NIF (wreq)
                                   passthrough (если native)      (bundle vN)         TLS/H2/h1, casing
                                                                              │
                                              Upstream: api.anthropic.com · chatgpt ·
                                              gemini · kimi · xai … (через резидентный egress, per-cred)

   RADAR (фоновый контур):  Recorder(MITM/pcap) → Corpus → Differ → Version-watch
                            → Hypothesis → Oracle(replay) → Canary → Persona Registry
```

Потоки данных:
- **Запрос**: ingress → recognizer (нативный? passthrough : cloaking) → диалект в IR →
  router выбирает креда (квоты/веса/sticky) → persona engine материализует wire-вид →
  egress NIF отправляет → SSE-чанки сообщениями назад → диалект обратно клиенту.
- **Дрифт**: recorder пишет корпус → differ вычисляет отчёт → hypothesis готовит
  новую версию персоны → oracle валидирует на upstream → canary раскатывает.

---

## 5. Persona Engine (ядро системы)

Персона = **версионируемый артефакт**, заменяющий хардкод CPA. Формат — JSON-бандл:

```
persona/claude-code/2.1.270.toml (или .json)
  meta:      semver, чексумма blake3, source (measured/hand), captured_from, dates
  transport: alpn=["http/1.1"] для api.anthropic.com; clienthello-шаблон (ext-порядок,
             группы, sigalgs); для h2-hosts — settings-фрейм и pseudo-header порядок
  headers:   ordered list [{name, casing, source: fixed|generator|passthrough,
             conditions}] — включая casing-карту и генераторы (UA-грамматика с версией
             из внешнего реестра, x-client-request-id = свежий UUID и т.п.)
  betas:     ordered list с условиями: credential=oauth|api-key, model-class, request-kind
             (main|subagent|probe|helper|count_tokens), body-features (fallbacks,
             thinking.display, structured outputs…)
  identity:  account_uuid, device pool, session rules (X-Claude-Code-Session-Id из
             metadata.user_id), стабильные seed-деривации
  timing:    распределения (думание, jitter, TTFT-ориентир)
  body:      системный префикс, обязательные поля метаданных
```

Свойства:
- Hot-swap: реестр персон следит за директорией; смена атомарна (swap на новой ссылке),
  в полёте — дорабатывают старые запросы.
- Линт персоны: несочетаемые беты (комбинация, которую реальный клиент не шлёт —
  прямой путь к детекту upstream'ом), отсутствующие обязательные заголовки.
- Источник правды о версиях CLI — реестр пакетов (npm и т.п.), не захардкоженные строки.
- Базовая персона Claude Code (измеренная CPA, переносим как v0 с атрибуцией) — Приложение B.

---

## 6. Fleet — акторы кредов

Один актор BEAM на кред. Состояния: `ready · refreshing · cooling(cooldown) · drained · failed`.

- **Refresh**: OAuth endpoints/PKCE по данным персоны; singleflight (один параллельный
  refresh на кред), backoff 5s→5m (наследуем практику CPA), refresh-блокировка при
  4xx от token endpoint.
- **Cooldown**: триггеры — 429/529, `Anthropic-Ratelimit-Unified-{5h,7d}-Status: rejected`,
  сетевые отказы; длительность из заголовков reset + fuzz 1–30s (конфигурируемо).
- **Quota ledger**: окна 5h/7d из `*-Limit-Remaining/Reset` и Unified-статусов;
  «мягкий» планировщик: не отправлять запрос креду, у которого окно почти выжжено —
  цель не максимизировать расход, а не попасть под жёсткие лимиты.
- **Sticky routing**: session_id → кред сохраняется на время сессии (identity стабильна),
  новые сессии — наименее загруженному по ledger.
- **Egress-адрес**: per-cred привязка резидентного прокси (стабильный IP на аккаунт).
- **Идиома надёжности CPA, принимаемая как закон**: таймауты только на приобретение
  креда; после установки upstream-соединения таймаутов нет.

Супервизор: `one_for_one`; падение актора креда не влияет на соседей и на ingress.

---

## 7. Recognizer — сверхбыстрое распознавание входящих

Задача: за микросекунды решить — входящий клиент это настоящий Claude Code/Codex/…
(→ **passthrough**: чужой фингерпринт не трогаем, апстриму уходит то, что прислал клиент)
или имитация (→ **cloaking**: навязываем нашу персону). База — 4-сигнальный контракт
CPA (подтверждён кодом `helps/claude_client_detection.go`), расширяем слоями:

| Слой | Что | Стоимость | Выход |
|---|---|---|---|
| L0 | Метод+path+UA-префикс (`claude-cli/…`, regex) | ~100ns | отсечение посторонних |
| L1 | Header-сет сигнатура: perfect-hash по (имя→присутствие) + порядок имён (hash конкатенации) + `x-app: cli` + наличие `claude-code-20250219` | ~1µs | native-кандидат |
| L2 | Тело: префикс system-блока (`"You are Claude Code…"` — первые ~40 байт, zero-copy), `metadata.user_id` (^`user_…`), shape (stream, thinking, betas-условия) | ~2–5µs | confirmed / unconfirmed |
| L3 | Пассивная статистика: паттерны inter-arrival, keep-alive, размерностей (фоново) | асинхронно | скоринг «подозрительности» |

Правила:
- Входной L1/L2-прогон скомпилирован в Rust NIF: принимает (headers, body-prefix,
  body-json-указатели), отдаёт вердикт — Gleam не парсит тело на hot path.
- «Confirmed native» → копируем только fingerprint-заголовки (кейсинг, порядок, беты)
  и доклеиваем кред-identity; остальное — как прислал клиент.
- «Unconfirmed» → полная персона (cloaking). Промежуточные (native UA, но странные
  заголовки) — консервативно cloaking.
- Allowlist entrypoints персоны: `cli`, `sdk-cli`, `claude-vscode` (как у CPA); новые
  entrypoint'ы проходят карантин (L3) до включения в allowlist.

---

## 8. Radar — контур детекта дрифтов (главное отличие от CPA)

Индустриализированная версия этого контура (пайплайны PB/PO/CO, драйвы, гейты,
бюджет-гард, промоушен персон) выделена в отдельный документ: WORKSHOP.md.

Цикл: **Recorder → Corpus → Differ → Version-watch → Hypothesis → Oracle → Canary.**

### 8.1 Recorder
- Режим A (активный, основной): локальный MITM-прокси с own CA. Оператор ставит
  `HTTPS_PROXY` + CA нативному CLI (claude/codex/gemini) и работает как обычно;
  recorder пишет **полный wire-след**: TLS ClientHello, ALPN, HTTP/2 SETTINGS и порядок
  фреймов, заголовки в исходном порядке и кейсинге, тела (zstd).
- Режим B (пассивный): pcap на сетевом интерфейсе — TTL= decrypted traffic не имеет,
  но даёт TLS-фингерпринты (JA4) и timing-энвелопы без вмешательства.
- Расписание: ночные smoke-сессии CLI на VM (headless), чтобы дрифт ловился до того,
  как его увидит прод-трафик.

### 8.2 Corpus
- Запись = content-addressed (blake3 нормализованного фрейма), zstd, дедупликация;
  индекс по (клиент, версия, endpoint, request-kind, день).
- Тело хранится обрезанным до N КБ по умолчанию (приватность), полным — по флагу.
- Формат записи — rkyv/serde, схема версионируется вместе с кодом.

### 8.3 Differ
Структурный дифф по осям:
- Заголовки: добавлен/удалён/переименован кейсинг/изменился порядок/изменился генератор.
- Беты: изменился состав или порядок; новые условия.
- JSON: новые/удалённые поля, изменения типов, новый request-kind.
- Транспорт: JA4-хэш, ALPN, h1/h2 выбор, settings-диффы.
- Timing: сдвиги распределений.
Выход — **drift report** (машиночитаемый) + human-readable diff для ревью.

### 8.4 Version-watch
Поллинг реестров пакетов (`@anthropic-ai/claude-code`, `@anthropic-ai/sdk`,
`@openai/codex`, `@google/gemini-cli`, `kimi-code`, …). Бамп версии → автоматическая
задача recorder'у «прогнать smoke-сессию новой версии» → differ старая vs новая →
hypothesis. Сегодняшний факт, мотивирующий: CPA пинит 2.1.258/0.112.1, в npm уже
2.1.270/0.125.0 — CPA уже молча отстаёт.

### 8.5 Hypothesis → Oracle
- Hypothesis: из drift report генерируется кандидат новой версии персоны (машинное
  редактирование TOML, человек в цикле approves).
- Oracle = сам upstream. Кандидат прогоняется на replay корпуса (нормализованные
  реальные запросы) против живого апстрима: приёмка по классам ответов
  (2xx/4xx-словари типа invalid beta, TTFT, SSE-грамматика), бинарный поиск
  минимального ломающего изменения. Отдельно: «запросы, которые реальный клиент
  никогда не шлёт» (negative cases) должны давать те же ответы, что у нативного
  клиента (сравнение с corpus-ответами).
- Лимиты oracle-прогонов (штук/в час), чтобы не светиться.

### 8.6 Canary
- Новая персона катается 1% → 10% → 100% запросов (по кредам-канарейкам, не по
  пользователям); откат при росте 4xx/latency. Метрика acceptance-rate per-persona
  — сигнальная для алертов.

---

## 9. Egress — wire-fidelity (Rust NIF)

Что именно реплицируем (baseline — факты CPA, Приложения A/B):

- **ALPN http/1.1 к api.anthropic.com** — не случайность, а фича: на h1 кейсинг имён
  заголовков доходит до сервера нетронутым (HPACK в h2 режет кейс). Реальный клиент
  идёт h1 — мы тоже.
- **Casing-карта**: `anthropic-beta`, `anthropic-version`, `x-app`,
  `x-client-request-id`, `anthropic-dangerous-direct-browser-access`,
  `X-Stainless-OS` (остальные — канонические). Порядок = bytewise sort (воспроизводит
  порядок реального клиента).
- **Полный обязательный набор**: `Anthropic-Version: 2023-06-01`,
  `Anthropic-Dangerous-Direct-Browser-Access: true`, `X-App: cli`,
  `X-Stainless-Retry-Count: 0`, `X-Stainless-Runtime: node`, `X-Stainless-Lang: js`,
  `X-Stainless-Timeout: 600` (отсутствует на count_tokens), `X-Stainless-Async: async`
  (только если прислал подтверждённый нативный), `Accept: application/json`,
  `Accept-Encoding: gzip, deflate, br, zstd` (identity для SSE к третьим сторонам),
  `Connection: keep-alive`, свежий `x-client-request-id` UUID (только first-party),
  `X-Claude-Code-Session-Id` (из metadata.user_id), passthrough `X-Claude-Code-Agent-Id`,
  `X-Claude-Code-Parent-Agent-Id`, `X-Claude-Remote-*`, `X-Client-App`,
  `X-Anthropic-Additional-Protection`.
- **Стабильная identity**: account_uuid/device — детерминированные производные от
  seed (как CPA), не меняются от запроса к запросу; session-continuity.
- **Codex-специфика**: UA `codex-tui/<ver> (Mac OS …; arm64) iTerm.app/… (codex-tui; <ver>)`
  (версия — из реестра, ОС-профиль — конфигурируемый, не хардкод конкретной машины),
  `Originator` passthrough, `X-Codex-Turn-Metadata/Turn-State/Window-Id`,
  identity-confuse `client_metadata.x-codex-installation-id`;
  внизходящий UA клиента **не форвардится** (Cloudflare 1010 — урок CPA).
- **Транспорт**: h2-паритет для chatgpt-бэкенда (wreq), keep-alive пулы, дефлят/бр/зстд
  переговоры как нативный клиент, correct zlib-vs-raw deflate (peek CMF/FLG).
- **Кодек OAuth control-plane**: header-order профили refresh/inspect (наследуем
  измеренные CPA порядки), utls-подобный ClientHello через wreq.

---

## 10. Dialect + IR

- Канонический IR: `turn`, `tool_call`, `thinking`, `usage`, `stream-event`.
  Трансляторы: openai-chat ↔ anthropic-messages ↔ gemini-generate ↔ openai-responses
  (+ interactions). N×M без NxM-кода: всё через IR (принцип CPA сохраняем, мораторий
  на правки не нужен — покрытие golden-тестами из корпуса).
- Thinking-пайплайн: canonical ThinkingConfig → per-provider output (схема CPA здравая).
- SSE: серверные события пересобираются из IR; TTFB-пасс-тру без полного буфера.
- Ограничение диалекта: unsupported-поля логируются и дропаются явно (не молча).

---

## 11. Data plane (ingress)

- mist (Gleam/BEAM): HTTP/1.1+2, SSE, WebSocket (для Codex-транспорта — wsrelay-аналог),
  graceful drain при reload, backpressure по медленным клиентам (не тянуть upstream).
- Шардинг по CPU-шедулерам BEAM; цель: 10k параллельных SSE-стримов на Mac Studio,
  p50 накладных расходов прокси (без upstream) < 1ms, p99 < 5ms.
- Клиентские API-ключи, per-key лимиты/тэги, отзыв без рестарта.

---

## 12. Control plane и наблюдаемость

- Management API: CRUD кредов/ключей/персон, квоты live, drift reports, replay-запуск,
  health. Веб-панель — вендорится в релиз (никаких rантайм-скачиваний с GitHub).
- Логи: структурные, с redaction-словарём (токены, ключи); тела не пишутся по умолчанию,
  хэш-ссылка на corpus-запись при отладке.
- Метрики: per-cred quota/latency, per-persona acceptance rate, drift index
  (расстояние текущей персоны от последнего измерения), recognizer-статистика L0–L3.

---

## 13. Хранилища

| Что | Где | Примечания |
|---|---|---|
| Креды (OAuth-токены) | `~/.mimic/auths/` | 0600, опция age-шифрования; формат persona-совместим |
| Персоны | `~/.mimic/personas/**.toml` + git-repo реестра | hot-reload, чексуммы |
| Корпус Radar | `~/.mimic/corpus/` | content-addressed, zstd, ротация |
| Конфиг | `mimic.toml` | hot-reload watcher; env-оверрайды |
| Состояние флота | ETS / Mnesia (позже PG, фаза P4) | restart-safe: критичное — в auth-dir |

---

## 14. Тестирование

1. Юнит: Gleam (`gleam test`) + Rust (`cargo test`) на каждый слой.
2. Golden corpus: авто-генерация фикстур из записей Radar (заголовки/тела/события).
3. Differential: одна и та же corpus-запись → (а) живой upstream через MIMIC,
   (б) эталонный ответ из корпуса; диффы по классам, не по байтам.
4. Persona-acceptance CI: nightly replay малой выборки (лимитированный бюджет) —
   ловит тихий дрифт до пользователей.
5. Нагрузка: SSE 10k стримов, memory ceiling, graceful drain.
6. Отказ: kill актора креда/NIF-потока посреди стрима — стрим не умирает (failover
   на другого креда только для не-sticky запросов).

---

## 15. Безопасность

- Секреты только в auth-dir (0600/age); в логах — redaction.
- Egress-прокси per-cred (стабильный IP на аккаунт), общий пул — опция.
- Identity-изоляция: у каждого креда свои account/device/session identity; никакой
  пересечки (уроки identity-confuse у CPA codex).
- Supply chain: панели и ассеты вендорятся; зависимости фиксируются lock-файлами;
  release-бинарники детерминированы и подписаны.
- ToS-риск принимается сознательно: «мягкие» квоты, отсутствие аномальных всплесков,
  тайминг-энвелопы нативного клиента (timing-слой персоны).

---

## 16. Риски и контрмеры

| Риск | Контрмера |
|---|---|
| Anthropic целенаправленно детектит прокси (несуществующие beta-комбинации, casing, timing) | Persona-lint (запрещённые комбинации), canary, timing-энвелопы, стабильные identity |
| Дрифт беты/заголовков ломает прод раньше Radar | Version-watch + ночные smoke-сессии + acceptance-rate алерты |
| Падение NIF роняет узел | rustler + dirty schedulers, короткие вызовы, enif_send-поток, супервизор egress-акторов |
| Cloudflare-блокировки (1010 на codex) | не форвардить клиентский UA, h2-паритет, резидентный egress |
| Бан аккаунтов за аномалии | мягкий quota-лидер, fuzz cooldown, per-cred egress, распределение по времени суток |
| BEAM-SSE производительность | чанки через сообщения (не NIF-поллинг), бинарные данные без копирования (refc binaries) |

---

## 17. Фазы

| Фаза | Содержание | Выход |
|---|---|---|
| P0 | Каркас: ingress + egress NIF + персона claude-code v0 (перенос измерений CPA) + auth-dir | «прозрачный» прокси Claude с фиделити |
| P1 | Fleet: акторы кредов, квоты, cooldown, sticky, management API | стабильный мульти-кред |
| P2 | Radar: recorder, corpus, differ, version-watch, oracle, canary | авто-детект дрифтов |
| P3 | Диалекты openai/gemini + персоны codex/gemini-cli/kimi/qwen | мульти-провайдер |
| P4 | Кластер (BEAM distribution/PG), wsrelay, плагины | масштаб |

---

## Приложение A. Проверенные факты из кода CPA (file:line)

- Beta-порядок Claude Code 2.1.258 (20 позиций, упорядоченно):
  `claude_executor_request.go:117–137`: 1 claude-code-20250219 · 2 oauth-2025-04-20
  (OAuth) · 3 context-1m-2025-08-07 (1m-модели) · 4 interleaved-thinking-2025-05-14 ·
  5 redact-thinking-2026-02-12 · 6 thinking-token-count-2026-05-13 ·
  7 context-management-2025-06-27 · 8 prompt-caching-scope-2026-01-05 ·
  9 mid-conversation-system-2026-04-07 · 10 advisor-tool-2026-03-01 ·
  11 advanced-tool-use-2025-11-20 · 12 effort-2025-11-24 ·
  13 server-side-fallback-2026-06-01 · 14 fallback-credit-2026-06-01 (OAuth) ·
  15 structured-outputs-2025-12-15 · 16 thinking-display-updates-2026-08-18 ·
  17 fast-mode-2026-02-01 · 18 afk-mode-2026-01-31 · 19 extended-cache-ttl-2025-04-11
  (OAuth; нет на subagent/probe) · 20 cache-diagnosis-2026-04-07.
- Casing-карта: `claude_executor_request.go:1248–1258`.
- ALPN h1 для Anthropic (кейсинг выживает только на h1): комментарий
  `claude_executor_request.go:1260+`.
- Детекция нативного клиента (4 сигнала + allowlist entrypoints {cli, sdk-cli,
  claude-vscode}; ~30 entrypoint'ов в subclient-карте): `helps/claude_client_detection.go`.
- Helper-профили Haiku (`claude-haiku-4-5-20251001`, 6 точных beta-профилей, измерено
  на 2.1.220): `helps/claude_client_detection.go` (measuredClaudeCodeHelperBetaProfiles).
- OAuth Claude: authorize `claude.ai/oauth/authorize`; token/refresh
  `platform.claude.com/v1/oauth/token`; profile `api.anthropic.com/api/oauth/profile`;
  roles `…/api/oauth/claude_cli/roles`; client_id `9d1c250a-e61b-44d9-88ed-5944d1962f5e`;
  redirect `localhost:54545/callback`; scopes `user:profile user:inference
  user:sessions:claude_code user:mcp_servers user:file_upload`; PKCE; refresh
  singleflight, backoff 5s–5m: `internal/auth/claude/anthropic_auth.go:20–33`.
- Header-order профили OAuth control-plane (refresh/inspect): `internal/auth/claude/utls_transport.go:23–45`.
- Rate-limit: `Anthropic-Ratelimit-Unified-Status`, `Unified-5h-Status`,
  `Unified-7d-Status`, `Unified-7d_oi-Status` (allowed/allowed_warning/rejected);
  fuzz cooldown 1–30s: `helps/claude_ratelimit.go`.
- Codex: UA `codex-tui/0.154.0 (Mac OS 26.5.2; arm64) iTerm.app/3.6.11 (codex-tui; 0.154.0)`
  (`codex_executor_request.go:26`); `Originator` passthrough; `X-Codex-*`;
  identity-confuse installation-id; Cloudflare 1010 → клиентский UA вниз не форвардится
  (`codex_executor_request.go:302–316`).
- Identity seeds: sha256 `"cpa-claude-code-cli-device|"+seed`, UUIDv5 account:
  `helps/claude_cli_identity_seed.go`.
- Правило «нет таймаутов после upstream-connect» и мораторий на translator: `AGENTS.md`.
- Управляющая панель скачивается с GitHub в рантайме: `config.example.yaml`
  (`remote-management.panel-github-repository`), `internal/managementasset/`.

## Приложение B. Baseline-персона Claude Code (v0, из измерений CPA)

Заголовки (h1, порядок bytewise, кейсинг по карте): Authorization (OAuth) /
x-api-key (API-key) · Content-Type: application/json · Accept: application/json ·
Accept-Encoding: gzip, deflate, br, zstd · anthropic-beta: <упорядоченные беты,
Прил. A, условия> · anthropic-version: 2023-06-01 ·
anthropic-dangerous-direct-browser-access: true · x-app: cli · x-client-request-id:
<UUID> · X-Stainless-Retry-Count: 0 · X-Stainless-Runtime: node ·
X-Stainless-Runtime-Version: <node> · X-Stainless-Package-Version: <sdk> ·
X-Stainless-OS/Arch: <по device-профилю> · X-Stainless-Lang: js ·
X-Stainless-Timeout: 600 (кроме count_tokens) · X-Claude-Code-Session-Id: <сессия> ·
User-Agent: claude-cli/<ver> (external, <entrypoint>[, agent-sdk/<ver>]) ·
Connection: keep-alive.
Тело: system-префикс `"You are Claude Code, Anthropic's official CLI for Claude."`
(с cache_control ephemeral), metadata.user_id = `user_<uuid>` (та же сессия, что в
X-Claude-Code-Session-Id).

## Приложение C. Дрифт на момент аудита (2026-09-14)

| Пакет | npm latest | Пин в CPA | Статус |
|---|---|---|---|
| @anthropic-ai/claude-code | 2.1.270 | 2.1.258 | отстаёт |
| @anthropic-ai/sdk | 0.125.0 | 0.112.1 | отстаёт |
| @openai/codex | 0.154.0 | 0.154.0 | актуально |

---

## Открытые вопросы

1. Имя проекта (MIMIC — рабочее).
2. Приоритет провайдеров после Claude: Codex или Gemini CLI первым?
3. TOML или JSON для персон (TOML удобнее для ревью диффов; JSON — для машинной генерации
   hypothesis; можно TOML для ручных правок + JSON как канонический формат реестра).
4. Режим identity для API-key кредов (CPA синтезирует device/account из seed — принять
   как есть или дать «честный» режим без синтеза?).
