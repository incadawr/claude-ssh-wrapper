# claude-ssh-wrapper

Тонкий bash-враппер, который заворачивает сетевой трафик `claude` CLI (Claude Code) и/или `codex` CLI (OpenAI) через SSH-тоннель в HTTP-прокси на вашем сервере. Остальная система ходит в сеть напрямую.

Платформа: **macOS** (Linux, вероятно, тоже заработает, но не цель MVP).

## Как это работает

`claude` — Node.js-приложение, его HTTP-клиент уважает `HTTPS_PROXY`. `codex` (Rust под капотом) тоже честно читает `HTTPS_PROXY`/`HTTP_PROXY`/`ALL_PROXY`. Враппер:

1. Поднимает SSH ControlMaster с `-L 127.0.0.1:<localPort>:127.0.0.1:<remotePort>` до вашего сервера.
2. Выставляет `HTTPS_PROXY=http://127.0.0.1:<localPort>`.
3. `exec` в настоящий бинарь (`claude` или `codex`).

Весь HTTP(S) клиента (и его подпроцессов — bash-tools, субагентов, WebFetch) идёт через ваш сервер. Остальные процессы переменную не видят. Оба враппера переиспользуют один и тот же SSH-мастер и один и тот же конфиг — никакого дублирования.

## Требования

- macOS с `ssh` (есть из коробки) и `jq` (`brew install jq`)
- установленный `claude` и/или `codex` CLI (для claude установщик предложит поставить через официальный скрипт; codex ставится самостоятельно — `npm i -g @openai/codex` или `brew install codex`)
- свой сервер с HTTP-прокси (`tinyproxy`, `xray` HTTP inbound, `3proxy` и т.п.), слушающим на `127.0.0.1:<remotePort>`
- рабочий SSH key-based доступ к серверу (настраивается в `~/.ssh/config`)

## Установка

```sh
git clone https://github.com/incadawr/claude-ssh-wrapper.git
cd claude-ssh-wrapper
./install.sh
```

Установщик интерактивный:
- найдёт настоящие `claude` и `codex` в PATH (claude — предложит поставить, если нет)
- спросит про каждый отдельно: ставить враппер или нет (`Install <name> wrapper? [Y/n]`)
- положит выбранные врапперы в `~/bin/{claude,codex}`
- спросит SSH host и user, создаст или дополнит `~/.claude-wrapper/config.json`
- предложит дописать `export PATH="$HOME/bin:$PATH"` в ваш shell rc
- напомнит открыть новый терминал

Можно ставить любую комбинацию: только claude, только codex, оба. Re-run установщика добавит вторую галочку, не трогая существующие настройки.

Формат конфига:

```json
{
  "server": {
    "host": "my.server.net",
    "user": "claude",
    "port": 22
  },
  "proxy": {
    "localPort": 8888,
    "remotePort": 18080
  },
  "claude": {
    "binary": "/Users/you/.local/bin/claude"
  },
  "codex": {
    "binary": "/opt/homebrew/bin/codex"
  }
}
```

Блоки `claude` и `codex` независимы — оставляйте только тот, что нужен.

| Поле | Обязательно | Дефолт | Описание |
|---|---|---|---|
| `server.host` | да | — | хост SSH-сервера (IP или `~/.ssh/config`-алиас) |
| `server.user` | да | — | SSH-юзер |
| `server.port` | нет | 22 | SSH-порт |
| `proxy.localPort` | нет | 8888 | локальный порт на маке |
| `proxy.remotePort` | нет | 18080 | порт HTTP-прокси на сервере |
| `claude.binary` | для claude-враппера | заполняется установщиком | абсолютный путь к настоящему `claude` |
| `codex.binary` | для codex-враппера | заполняется установщиком | абсолютный путь к настоящему `codex` |

SSH-ключи/алиасы — в обычном `~/.ssh/config`, в конфиг враппера не попадают.

## Использование

```sh
claude            # обычный запуск — трафик идёт через ваш сервер
codex             # то же самое; шарит тоннель и конфиг с claude-враппером
```

При старте в stderr печатается одна строка-баннер:
```
claude-wrapper: via root@my.server.net (127.0.0.1:8888 → :18080)
codex-wrapper: via root@my.server.net (127.0.0.1:8888 → :18080)
```
Подавить баннер в скриптах: `CLAUDE_WRAPPER_QUIET=1 claude -p "..."` или `CODEX_WRAPPER_QUIET=1 codex ...`.

Первый запуск в сессии (любой из двух врапперов) поднимает SSH master в фоне (`~/.claude-wrapper/tunnel.sock`), последующие — переиспользуют сокет независимо от того, какой враппер был первым.

Принудительно закрыть тоннель:

```sh
ssh -S ~/.claude-wrapper/tunnel.sock -O exit dummy
```

## Диагностика

Когда `claude` падает с чем-то вроде `API Error: Unable to connect to API (ConnectionRefused)` — это почти всегда означает, что упала локальная связка SSH+прокси, а не настоящий API. Чтобы это сразу было видно:

### Pre-flight в самом враппере

Перед `exec claude` враппер делает быстрый `curl` через прокси к `api.anthropic.com`. Если ответа нет — выходит с понятным сообщением вместо того, чтобы дать `claude` стартовать и сломаться внутри.

```
claude-wrapper: tunnel/proxy unreachable via http://127.0.0.1:8888. Run: claude-doctor
```

Отключить (если хочется минимум задержки и вы готовы видеть стандартную ошибку клода): `CLAUDE_WRAPPER_NO_PREFLIGHT=1 claude`.

### `claude-doctor` — one-shot health-чек

Ставится установщиком в `~/bin/claude-doctor`. Проверяет конфиг, ssh master, локальный listener, прокси-зонд через тоннель и прямой зонд (для baseline). Не открывает и не закрывает ничего — безопасно запускать когда `claude` уже работает.

```sh
claude-doctor
```

Пример вывода при упавшем туннеле:

```
ssh master
  ✗ control socket missing: ~/.claude-wrapper/tunnel.sock
    tunnel is not open. fix: run 'claude' once to (re)open the master
proxy probe (api.anthropic.com via http://127.0.0.1:8888)
  ✗ no HTTP response (curl couldn't connect through the proxy)
direct probe (api.anthropic.com without proxy)
  ✓ HTTP 404 in 0.17s

verdict: tunnel down. mac itself reaches api.anthropic.com — fix the SSH/proxy chain.
```

### Live health-лог (`tunnel-watchdog`)

Враппер при первом запуске поднимает фоновый watchdog (`~/.claude-wrapper/tunnel-watchdog`), который раз в 30 секунд пишет одну строку в `~/.claude-wrapper/tunnel.log`:

```sh
tail -f ~/.claude-wrapper/tunnel.log
```

```
2026-04-25T22:30:15+0300 OK    http=401 time=0.234s
2026-04-25T22:30:45+0300 OK    http=401 time=0.219s
2026-04-25T22:31:15+0300 FAIL  ssh master down (consecutive=1)
2026-04-25T22:31:45+0300 FAIL  ssh master down (consecutive=2)
2026-04-25T22:32:15+0300 STOP  master gone for 3 cycles, exiting
```

Single-instance через PID-файл — повторные запуски `claude` не плодят watchdogs. Watchdog сам гасится после трёх подряд `FAIL master down` (типичный сценарий — пользователь сделал `ssh -O exit`); при следующем `claude` стартует заново вместе с новым master. Лог обрезается до ~5000 строк автоматически.

Параметры для тонкой настройки (env, читаются watchdogом при старте):

| Env | Дефолт | Описание |
|---|---|---|
| `CLAUDE_WRAPPER_WATCHDOG_INTERVAL` | 30 | период проверки, секунды |
| `CLAUDE_WRAPPER_WATCHDOG_TIMEOUT` | 5 | таймаут одного curl-зонда |
| `CLAUDE_WRAPPER_WATCHDOG_FAIL_LIMIT` | 3 | сколько подряд `master down` до самовыхода |
| `CLAUDE_WRAPPER_WATCHDOG_URL` | `https://api.anthropic.com/` | что зондируем |
| `CLAUDE_WRAPPER_WATCHDOG_LOG_MAX` | 5000 | потолок строк в `tunnel.log` |

### Меню-бар индикатор (опционально)

В `extras/swiftbar/` лежит плагин для [SwiftBar](https://swiftbar.app) (или [xbar](https://xbarapp.com)). Кладёт в меню-бар иконку с цветом по последнему статусу из `tunnel.log` и dropdown с последними строками лога и быстрыми действиями (запустить `claude-doctor`, открыть `tail -f`, переоткрыть тоннель).

```sh
brew install --cask swiftbar
ln -s "$PWD/extras/swiftbar/claude-tunnel.30s.sh" \
      "$HOME/Library/Application Support/SwiftBar/claude-tunnel.30s.sh"
# затем в SwiftBar: Refresh All
```

Что увидите в меню-баре:
- 🟢 `192ms` — последний пробинг прошёл, в скобках latency через прокси
- 🔴 `fail` — последняя строка лога FAIL (`master down` или прокси не отвечает)
- 🟡 `stale` — лог старше 90с (watchdog, видимо, повис)
- 🟡 `off` — watchdog не запущен (запустите `claude` любой командой)
- ⚪ `stopped` — watchdog штатно завершился (после трёх FAIL подряд)

Плагин read-only: только читает `tunnel.log` и `watchdog.pid`, ничего не открывает и не пишет. Установщик `install.sh` его НЕ ставит — это опциональная интеграция, лежит в репо отдельно.

### Старые скрипты в `scripts/`

```sh
./scripts/bash-check.sh      # проверяет ключ/SSH/форвард/прокси (hardcoded дефолты)
./scripts/wrapper-check.sh   # то же, но читает реальный ~/.claude-wrapper/config.json
```

`wrapper-check.sh` повторяет логику враппера 1:1 (тот же конфиг, тот же ControlMaster, те же env), но вместо `exec claude` делает `curl --proxy ...` и печатает egress IP — так видно, работает ли именно связка «враппер → прокси». В отличие от `claude-doctor`, при необходимости сам *открывает* тоннель (и закрывает за собой, если открывал).

## Несколько профилей

Альтернативный конфиг через env-переменную:

```sh
CLAUDE_WRAPPER_CONFIG=~/.claude-wrapper/eu.json claude
```

## Деинсталляция

```sh
./uninstall.sh           # удаляет враппер, закрывает тоннель, оставляет конфиг
./uninstall.sh --purge   # плюс удаляет ~/.claude-wrapper
```

## Ограничения

- **Что ловится прокси:** HTTP(S) `claude` и его дочерних процессов (bash-tools, MCP-серверы, субагенты) — env наследуется, все уважающие `HTTPS_PROXY` клиенты ходят через сервер.
- **Что не ловится:** не-HTTP (raw TCP/UDP/WebRTC) — не проблема для Claude Code, он ходит только через HTTPS-API. Плюс отдельные MCP-серверы на Node с глобальным `fetch`, которые не уважают env — такие идут напрямую (ограничение undici, не враппера).
- **DNS:** целевые хосты резолвятся на сервере (HTTP-прокси `CONNECT`). С мака не уходит DNS-запросов про конечные домены.
- **Lifecycle тоннеля:** SSH master после `claude` не гасится автоматически — живёт до `ssh -O exit` или перезагрузки. Повторные запуски `claude` быстрее (master переиспользуется).

## Серверная часть

Repo содержит только mac-side. На сервере должен слушать HTTP-прокси на `127.0.0.1:<remotePort>` — доступ только через SSH-форвард.

Минимальный пример с `tinyproxy` на Debian/Ubuntu:

```sh
apt install -y tinyproxy
sed -i 's/^Port .*/Port 18080/; s/^Listen .*/Listen 127.0.0.1/' /etc/tinyproxy/tinyproxy.conf
systemctl restart tinyproxy
```

