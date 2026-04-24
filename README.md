# claude-ssh-wrapper

Тонкий bash-враппер, который заворачивает сетевой трафик `claude` CLI (Claude Code) через SSH-тоннель в HTTP-прокси на вашем сервере. Остальная система ходит в сеть напрямую.

Платформа: **macOS** (Linux, вероятно, тоже заработает, но не цель MVP).

## Как это работает

`claude` — Node.js-приложение, его HTTP-клиент уважает `HTTPS_PROXY`. Враппер:

1. Поднимает SSH ControlMaster с `-L 127.0.0.1:<localPort>:127.0.0.1:<remotePort>` до вашего сервера.
2. Выставляет `HTTPS_PROXY=http://127.0.0.1:<localPort>`.
3. `exec` в настоящий бинарь `claude`.

Весь HTTP(S) `claude` (и его подпроцессов — bash-tools, субагентов, WebFetch) идёт через ваш сервер. Остальные процессы переменную не видят.

## Требования

- macOS с `ssh` (есть из коробки) и `jq` (`brew install jq`)
- установленный `claude` CLI (если не стоит — установщик предложит поставить его через официальный скрипт)
- свой сервер с HTTP-прокси (`tinyproxy`, `xray` HTTP inbound, `3proxy` и т.п.), слушающим на `127.0.0.1:<remotePort>`
- рабочий SSH key-based доступ к серверу (настраивается в `~/.ssh/config`)

## Установка

```sh
git clone https://github.com/incadawr/claude-ssh-wrapper.git
cd claude-ssh-wrapper
./install.sh
```

Установщик интерактивный:
- найдёт настоящий `claude` в PATH (или предложит поставить)
- положит враппер в `~/bin/claude`
- спросит SSH host и user, создаст `~/.claude-wrapper/config.json`
- предложит дописать `export PATH="$HOME/bin:$PATH"` в ваш shell rc
- напомнит открыть новый терминал

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
  }
}
```

| Поле | Обязательно | Дефолт | Описание |
|---|---|---|---|
| `server.host` | да | — | хост SSH-сервера (IP или `~/.ssh/config`-алиас) |
| `server.user` | да | — | SSH-юзер |
| `server.port` | нет | 22 | SSH-порт |
| `proxy.localPort` | нет | 8888 | локальный порт на маке |
| `proxy.remotePort` | нет | 18080 | порт HTTP-прокси на сервере |
| `claude.binary` | да | заполняется установщиком | абсолютный путь к настоящему `claude` |

SSH-ключи/алиасы — в обычном `~/.ssh/config`, в конфиг враппера не попадают.

## Использование

```sh
claude            # обычный запуск — трафик идёт через ваш сервер
```

При старте в stderr печатается одна строка-баннер:
```
claude-wrapper: via root@my.server.net (127.0.0.1:8888 → :18080)
```
Подавить баннер в скриптах: `CLAUDE_WRAPPER_QUIET=1 claude -p "..."`.

Первый запуск в сессии поднимает SSH master в фоне (`~/.claude-wrapper/tunnel.sock`), последующие переиспользуют сокет.

Принудительно закрыть тоннель:

```sh
ssh -S ~/.claude-wrapper/tunnel.sock -O exit dummy
```

## Диагностика

Два скрипта для проверки настройки без запуска `claude`:

```sh
./scripts/bash-check.sh      # проверяет ключ/SSH/форвард/прокси (hardcoded дефолты)
./scripts/wrapper-check.sh   # то же, но читает реальный ~/.claude-wrapper/config.json
```

`wrapper-check.sh` повторяет логику враппера 1:1 (тот же конфиг, тот же ControlMaster, те же env), но вместо `exec claude` делает `curl --proxy ...` и печатает egress IP — так видно, работает ли именно связка «враппер → прокси», независимо от самого клода.

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

