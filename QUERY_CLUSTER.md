# MIMIC — кластер запросов для GitHub-разведки
v0.1 · 2026-09-27 · вход для агентов, спарсивших GitHub
Цель: найти реализующиеся прокси «подписка CLI-агента → API» и смежные
инструменты (запись/воспроизведение wire-поведения, пулы кредов, диалекты),
которые можно разобрать перед реализацией слайсов из SLICES.md.

Формат запроса — фраза для `gh search repos` / GitHub code search / веб-поиска.
Каждый запрос помечен треком MIMIC, к которому он относится.

---

## Т1. Подписка → API (ядро, D-трек MIMIC)

EN:
- claude code subscription to api proxy
- claude max oauth reverse proxy openai compatible
- turn claude code into api endpoint
- claude code oauth token refresh proxy sse streaming
- codex chatgpt subscription api proxy
- gemini cli to openai api service
- github copilot to openai api service
- qwen code oauth api proxy
- kimi cli api proxy
- cli subscription as llm api gateway

CN (крупнейшая часть экосистемы — обязательно прогонять):
- claude code 反向代理
- claude 镜像 api
- codex 转 api
- gemini 免费 api 白嫖
- 转api 订阅

RU (проверить нишу):
- прокси claude api подписка

## Т2. Мульти-аккаунт, пул, квоты (D2/D3 MIMIC)

- multi account claude proxy pool
- llm subscription pool router load balancing
- claude rate limit headers quota tracker
- sticky session upstream credential pool
- api key rotation quota scheduler
CN: claude 拼车 多账号 负载均衡

## Т3. Wire-фиделити / TLS-импersonация (B3/R1 MIMIC)

- http client fingerprint tls impersonation
- curl_cffi impersonate http2 ja3 ja4
- header order case preserving http proxy
- browser-impersonation http client rust
- tls client hello control http2 settings frame

## Т4. Запись/воспроизведение/дифф корпусов (A/F MIMIC)

- mitm record llm traffic corpus
- http record replay regression testing proxy
- contract testing golden files api drift
- sdk version drift detection release gate

## Т5. Диалекты/трансляция форматов (E MIMIC)

- openai anthropic api format translator proxy
- litellm openai compatible endpoint proxy
- gemini anthropic openai unified api translation
- sse stream format converter proxy

---

## Фильтры для агентов (критерии отбора кандидатов)

1. Активность: коммиты за последние 6–12 мес ИЛИ archived, но исторически
   значимый (для идей).
2. Звёзды: >20 для «взрослых», любой для свежих, но тогда смотреть активность
   и качество README.
3. Функциональные маркеры (хотя бы 2): OAuth-флоу провайдера; SSE-стриминг;
   несколько апстрим-аккаунтов; OpenAI-совместимый фронт; refresh-токены.
4. Язык реализации НЕ критичен (Rust/Go/TS/Python — все интересны; Gleam
   интересен отдельно как доказательство жизнеспособности стека).
5. Отдельно помечать: способ сборки (исходники vs бинари/Docker), наличие
   телеметрии/фоновой загрузки, состояние лицензии (смотреть на copyleft —
   AGPL-проекты учитывать как «идеи, не код»).

## Семенной список (уже известные репо — включить в выдачу и дедуп)

- router-for-me/CLIProxyAPI — уже аудирован (~/dev/audit/CLIProxyAPI)
- Xerxes-2/clewdr — Rust, Claude+Claude Code, native+OpenAI endpoints
- Wei-Shaw/claude-relay-service — CRS, 拼车, зеркалирование Claude Code
- ding113/claude-code-hub — 3.4k★, Claude Code & Codex, балансировка, учёт
- KarpeLesLab/teamclaude — пул Claude Max/Codex/API-key (точное имя проверить)
- ZhangHanDong/claude-code-api-rs — 177★, Rust OpenAI-гейтвей для Claude Code
- codingworkflow/claude-code-api — 332★
- 4xian/claude-codex-api — 210★, переключатель Claude Code/Codex
- DevLLM/cop-gpt-service — GitHub Copilot → ChatGPT API
- nettee/gemini-cli-proxy — 153★, Gemini CLI → OpenAI
- ubaltaci/gemini-cli-proxy — 36★, Gemini CodeAssist через OpenAI/Anthropic API
- 6Kmfi6HP/opencode2api — OpenCode → Codex/Claude Code API
- kobie3717/claude-oauth-proxy — 11★, anti-ban engine
- claudespiral/claude-oauth-proxy — Pro/Max как стандартный Anthropic API
- npow/claude-relay — OpenAI/Anthropic API поверх claude CLI (child-process)
- achetronic/claude-oauth-proxy — 10★, Anthropic Teams/Enterprise, auto-refresh, SSE

## Что вынести по каждому кандидату (выход агента)

- URL, звёзды, язык, лицензия, последний коммит
- Какие апстримы и типы авторизации (OAuth/API-key/session-cookie)
- Есть ли: мульти-аккаунт, квота-трекинг, sticky-сессии, диалекты, SSE
- Как обеспечивается wire-фиделити (или не обеспечивается — тоже сигнал)
- Оценка: что взять как референс для какого слайса MIMIC (A1..H2/R1)
