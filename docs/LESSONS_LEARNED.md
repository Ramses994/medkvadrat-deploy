# Lessons learned (deploy & integrations, 2026)

Краткие заметки после первого деплоя сложного контура (GHCR, self-hosted runner, SQLite в api-gateway, pilot OTP). Чтобы через три месяца не повторять те же часы отладки.

## GitHub / registry

- **Fine-grained PAT** с узкими правами часто **не подходит** для `docker pull` с **приватного ghcr.io** в том виде, как ожидает Docker на стенде. Практичные варианты: **classic PAT** с `read:packages` (и нужными repo scope) или **публичные packages** только для dev-образов (осознанный компромисс).

## Контейнеры и тома

- **api-gateway** (и аналогичные сервисы) могут работать под **`USER nobody` (uid 65534)**. Новый **named volume** создаётся с root-only правами на data-dir → процесс **не может писать SQLite** без разового `chown` на хосте. Правильное долгосрочное решение: **`Dockerfile` — `RUN mkdir -p /app/data && chown -R nobody:nobody /app/data` до `USER nobody`** (см. issue в `medkvadrat-patient-api`).

## Секреты и отладка

- **`docker compose config`** (и экспорт compose в CI) выводит **подстановки env в открытом виде**. Перед вставкой лога в чат / тикет — **маскировать** секреты; в репозитории имеет смысл завести обёртку в `scripts/`, которая по умолчанию заменяет значения на `***` (см. issue про ротацию секретов в `medkvadrat-deploy`).

## Git на сервере

- **`git pull` по HTTPS** на стенде обычно требует **SSH deploy key** или credential helper; **парольная аутентификация GitHub** для git часто отключена — закладываться на ключ.

## Процесс

- Инфраструктурные правки в **`medkvadrat-deploy`** должны идти **только через PR** в `main` + branch protection + зелёный check **`compose-config / validate`** — см. README репозитория.
