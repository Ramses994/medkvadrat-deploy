# medkvadrat-deploy

Продакшн-стенд сети клиник МедКвадрат. Содержит `docker-compose.yml`, скрипт деплоя и GitHub Actions workflow для автодеплоя через self-hosted runner.

## Архитектура

```
┌─────────────────────────────────────────────────────────────┐
│                 192.168.2.122 (Ubuntu/Debian)               │
│                                                             │
│  ┌──────────────────┐   ┌──────────────────┐                │
│  │   api-gateway    │   │     max-bot      │                │
│  │   :8080 → host   │◄──│  long polling    │                │
│  │                  │   │  platform-api.max│                │
│  └────────┬─────────┘   └──────┬───────────┘                │
│           │                    │                            │
│           │            ┌───────┴──────┐                     │
│           │            │  SQLite том  │                     │
│           │            │  bot-data    │                     │
│           │            └──────────────┘                     │
│           │                                                 │
└───────────┼─────────────────────────────────────────────────┘
            │
            ▼  (LAN)
  ┌─────────────────────┐
  │  192.168.2.229:1433 │
  │   MSSQL Medialog    │
  └─────────────────────┘
```

Оба сервиса тянут образы из `ghcr.io`. Сборка идёт в GitHub Actions, деплой — через self-hosted runner, который подключён к этому серверу.

## Upgrade: со стека «шаг 1» (только long poll) на «шаг 2+» (OTP, SQLite, /api/me)

`api-gateway` в шаге 2+ пишет SQLite (`gateway.db`: сессии OTP, refresh tokens, rate limits). Без смонтированного тома и каталога контейнер уходит в рестарт-луп (`SQLITE_CANTOPEN` / code 14): директория не создана или путь только для чтения.

1. `cd /opt/medkvadrat/medkvadrat-deploy && git pull`
2. Сверься с `.env.example`: скопируйте новые переменные в свой `.env`.
3. Сгенерируйте секреты для режима `pilot` (или оставьте `AUTH_MODE=dev` на время теста без реальной СМС):
   ```bash
   openssl rand -hex 32   # JWT_SECRET
   openssl rand -hex 32   # OTP_HMAC_SECRET
   ```
4. При `AUTH_MODE=pilot` укажите `AUTH_PILOT_WHITELIST` (телефоны тестеров) и при необходимости блок `SMTP_*`.
5. Выполните деплой: `./deploy.sh`

После обновления у `api-gateway` появляется named volume `medkvadrat-gateway-data` с `gateway.db` в `/app/data`. Перед откатом на образ «шаг 1» снимите из `docker-compose` блок `GATEWAY_DB_PATH` / volume (или оставьте `AUTH_MODE=dev` и пусть SQLite создаётся пустым).

## Первичная установка на пустой сервер

Предполагается Ubuntu 22.04/24.04 или Debian 12. Все команды — от пользователя с sudo.

### 1. Docker и Docker Compose v2

```bash
# Официальный скрипт Docker
curl -fsSL https://get.docker.com | sudo sh

# Добавляем текущего пользователя в группу docker (перелогиниться после)
sudo usermod -aG docker $USER

# Проверка
docker --version
docker compose version
```

### 2. Клонирование репозитория

```bash
sudo mkdir -p /opt/medkvadrat
sudo chown $USER:$USER /opt/medkvadrat
cd /opt/medkvadrat
git clone https://github.com/<OWNER>/medkvadrat-deploy.git
cd medkvadrat-deploy
```

### 3. Конфигурация .env

```bash
cp .env.example .env
# Сгенерировать API_TOKEN
openssl rand -hex 32
# Открыть и заполнить все CHANGE_ME
nano .env
```

**Обязательно** перед первым запуском:
- сменить `DB_PASSWORD` в MSSQL и записать сюда новый (старый засвечен в рабочих переписках);
- сгенерировать случайный `API_TOKEN` (тот же автоматически уходит в бот как `GATEWAY_TOKEN`);
- вставить `MAX_BOT_TOKEN` из [MAX для партнёров](https://business.max.ru).

### 4. Первичный запуск

```bash
./deploy.sh
```

Если образы ещё не собраны в GitHub Actions — сначала нужно сделать push в main каждого из репо сервисов (см. ниже), иначе `docker compose pull` упадёт с «image not found».

### 5. Self-hosted runner для автодеплоя

В GitHub: `medkvadrat-deploy` → Settings → Actions → Runners → New self-hosted runner → Linux x64.

На сервере выполнить команды, которые предложит UI (скачать tarball, распаковать в `~/actions-runner/`, запустить `config.sh` с токеном). **Важно:**

- Не ставить runner от root. Использовать отдельного пользователя (например, `deployer`), членом группы `docker`.
- При `./config.sh` добавить метку (label) `medkvadrat-prod` — она указана в `deploy.yml`.
- Установить как systemd-сервис:
  ```bash
  sudo ./svc.sh install deployer
  sudo ./svc.sh start
  sudo ./svc.sh status
  ```

Проверка — в Settings → Runners должен появиться статус **Idle**.

### 6. PAT для repository_dispatch

Для того чтобы билд образа в сервисных репо триггерил деплой в этом репо, нужен Personal Access Token:

1. Создать fine-grained PAT: https://github.com/settings/personal-access-tokens → New token
2. Resource owner: организация/пользователь, где лежит `medkvadrat-deploy`
3. Repository access: только `medkvadrat-deploy`
4. Permissions: **Actions: Read and write**, **Contents: Read**
5. Скопировать токен.
6. В каждом сервисном репо (`medkvadrat-patient-api`, `medkvadrat-max-bot`): Settings → Secrets and variables → Actions → New repository secret → имя `DEPLOY_DISPATCH_TOKEN`, значение — токен из п.5.

## Что нужно сделать в репозиториях сервисов

В каждом из `medkvadrat-patient-api` и `medkvadrat-max-bot`:

1. Скопировать `SERVICE_WORKFLOW_TEMPLATE.yml` из этого репо в `.github/workflows/docker.yml`.
2. В Settings → Actions → General → Workflow permissions поставить **Read and write**.
3. Добавить secret `DEPLOY_DISPATCH_TOKEN` (см. п.6 выше).
4. Сделать push в `main`. В Actions должен запуститься билд, на ghcr.io появится образ `ghcr.io/<OWNER>/<repo>:latest`.

## Ежедневная эксплуатация

### Посмотреть логи
```bash
docker compose logs -f                 # оба сервиса
docker compose logs -f api-gateway     # один
docker compose logs --tail=100 max-bot # последние 100 строк
```

### Статус
```bash
docker compose ps
curl -s http://localhost:8080/api/health
```

### Ручной передеплой (если автодеплой не сработал)
```bash
cd /opt/medkvadrat/medkvadrat-deploy
git pull
./deploy.sh
```

### Откат на предыдущую версию

В `docker-compose.yml` временно заменить `:latest` на конкретный `:<sha>`:
```yaml
image: ghcr.io/medkvadrat/medkvadrat-patient-api:abc123def
```
Затем `docker compose up -d api-gateway`. После стабилизации — коммит с возвратом на `:latest`.

### Бэкап SQLite бота

```bash
docker run --rm \
  -v medkvadrat-bot-data:/data \
  -v $(pwd):/backup \
  alpine tar czf /backup/bot-db-$(date +%Y%m%d-%H%M).tar.gz -C /data .
```

Рекомендуется прогнать ежедневно через cron.

## Безопасность — чек-лист

- [ ] `.env` не в git, права 600: `chmod 600 .env`
- [ ] Пароль MSSQL **изменён** после того, как старый попал в рабочие переписки
- [ ] `API_TOKEN` сгенерирован через `openssl rand -hex 32`, не hardcoded
- [ ] Self-hosted runner работает НЕ от root
- [ ] Оба сервисных репо **приватные** (self-hosted runner + публичные репо = RCE от любого PR)
- [ ] Порт 8080 закрыт на файрволе клиники от внешнего мира (только LAN)
- [ ] Регулярный бэкап SQLite

## Частые ошибки

**`docker compose pull` → `denied: permission_denied`** — образ приватный, не прошёл `docker login ghcr.io`. Для self-hosted runner это делается в workflow; для ручного деплоя экспортировать `GHCR_TOKEN` и `GHCR_USER` перед запуском `./deploy.sh`.

**Бот стартует, но `GetMe` отвечает 401** — невалидный `MAX_BOT_TOKEN`. Проверить в MasterBot, что токен не отозван.

**api-gateway healthcheck проваливается** — скорее всего MSSQL недоступен с контейнера. Проверить `docker compose logs api-gateway`, убедиться что `DB_SERVER=192.168.2.229` достижим (`docker compose exec api-gateway wget -qO- http://192.168.2.229:1433` — TCP-тест руками).

**`repository_dispatch` прошёл, но deploy workflow не запустился** — скорее всего `DEPLOY_DISPATCH_TOKEN` истёк или не имеет прав на `actions:write`. Создать заново.
