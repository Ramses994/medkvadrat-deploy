# Cursor — LK-0: безопасный фундамент (два PR)

Контекст: `docs/lk/01_TZ_PATIENT_CABINET.md` §4 «Этап 0», `docs/lk/00_KNOWLEDGE_BASE_MEDIALOG.md` §9,
`docs/MEDIALOG_RULES.md`. Новых функций нет: ограждаем работающий код до появления ЛК у пациентов.
Write-пути остаются включаемыми, но только для белых списков владельца (решение D1).

**Ограничения для тебя (Cursor):**
- Не подключайся к боевому Медиалогу (`192.168.2.229`) и не запускай против него ни API, ни
  утилиты. Все проверки — `go test`, `go vet`, юнит-тесты на моках.
- Не меняй SQL существующих read-эндпоинтов и логику записи — только ограждения и конфиг.
- Каждый PR — отдельная ветка от актуального `main`, описание по шаблону PR.

---

## PR LK-0a — `medkvadrat-deploy`: документы и процесс

Ветка `docs/lk-foundation`.

1. Положить файлы (я передам их вложением) в `docs/lk/`:
   - `00_KNOWLEDGE_BASE_MEDIALOG.md`
   - `01_TZ_PATIENT_CABINET.md`
   - `02_WORKFLOW.md`
   - `03_VERIFICATION_SQL.sql`
   - `04_RUNBOOK_BOOKING_CAPTURE.md`
   - `05_SQL_SERVICE_LOGINS.sql`
   - `06_BOT_CONSENT.md`
   - `prompts/` (все промты из вложения)
   - `tools/Export-SqlResults.ps1` (выгрузка результатов проверочных запросов в файлы)

   В `.gitignore` добавить `docs/lk/tools/results/` — там результаты запросов к боевой базе
   (строки тестового профиля и профиля владельца); в репозиторий они попадать не должны.
   Проверка: `git status` после запуска скрипта не показывает файлов из `results/`.
2. Создать `.github/pull_request_template.md` из блока «Шаблон описания PR» в `02_WORKFLOW.md`.
   Такой же шаблон — в `medkvadrat-patient-api` и `medkvadrat-max-bot` (отдельными маленькими
   коммитами в их PR LK-0b или отдельными PR — как удобнее; файл одинаковый).
3. В `README.md` раздел «Личный кабинет пациента» — 3–5 строк со ссылками на `docs/lk/`.
4. В `.env.example` добавить (с комментариями) переменные из PR LK-0b:
   `MEDIALOG_WRITE_ENABLED=false`, `MEDIALOG_WRITE_ALLOW_PATIENTS=`, `MEDIALOG_WRITE_ALLOW_PL_SUBJ=`,
   `DB_RW_USER=`, `DB_RW_PASSWORD=`, `MOTCONSU_POLL_ENABLED=false`, `CORS_ALLOWED_ORIGINS=`,
   `DB_APP_NAME=medkvadrat-patient-api` — и пробросить их в сервис `api-gateway` в
   `docker-compose.yml`. Значение `DB_USER` в примере заменить на `svc_patient_api_ro` с
   комментарием «служебная учётная запись только на чтение, см. docs/lk/01 §7.2 и
   docs/lk/05_SQL_SERVICE_LOGINS.sql».

Только документы и конфиг; проверка `compose-config / validate` должна пройти.

---

## PR LK-0b — `medkvadrat-patient-api`: флаги и подключение

Ветка `chore/lk-0-guards`.

### 1. Белые списки записи в Медиалог (решение владельца D1)

Write-эндпоинты не выключаются, но работают только в узких рамках, заданных владельцем.

- `config`:
  - `MedialogWriteEnabled bool` ← `MEDIALOG_WRITE_ENABLED`, по умолчанию `false`;
  - `MedialogWriteAllowPatients []int64` ← `MEDIALOG_WRITE_ALLOW_PATIENTS` (CSV), по умолчанию пусто;
  - `MedialogWriteAllowPlSubj []int64` ← `MEDIALOG_WRITE_ALLOW_PL_SUBJ` (CSV), по умолчанию пусто.
- Общая проверка `WriteGuard` (один пакет, один тест-набор) для маршрутов
  `POST /api/me/appointments`, `DELETE /api/me/appointments/{motconsu_id}`, `POST /api/schedule/book`:
  1. выключатель `false` → `403 WRITE_DISABLED`;
  2. `patient_id` (из JWT, для S2S — из тела) не в `ALLOW_PATIENTS` → `403 WRITE_NOT_ALLOWED`;
  3. линия расписания целевого слота не в `ALLOW_PL_SUBJ` → `403 WRITE_NOT_ALLOWED`.
     Линию определить одним `SELECT PL_SUBJ_ID FROM PLANNING WHERE PLANNING_ID=@id`
     (только чтение) до любого write; для отмены — по записи, которую отменяют.
  Пустой список = запрещено всем. Проверки выполняются **до** любого изменения в базе.
- Сообщение пациенту для 403: «Запись через приложение пока недоступна. Позвоните в
  регистратуру: +7 (499) 288-88-14».
- **Журнал write** в `gateway.db`, таблица `medialog_write_log`: `id`, `created_at`,
  `request_id`, `route`, `patient_id`, `planning_id`, `pl_subj_id`, `decision`
  (`denied_disabled|denied_patient|denied_pl_subj|attempted`), `result` (`ok|error|conflict`),
  `error_code`. Запись в журнал — до и после попытки. ФИО и телефонов нет.
- **Вторая строка подключения для записи:** `DB_RW_USER`, `DB_RW_PASSWORD` (тот же сервер и
  база). Write-пути (`BookMe`, `CancelMe`, `Book`) используют отдельный `*sql.DB` на этом
  логине; все чтения — основной. Если `DB_RW_USER` пуст — write-пути отвечают
  `503 WRITE_NOT_CONFIGURED` (не падать на старте).
- Логика самих write-путей **не меняется** в этом PR (её заменит LK-2b).
- Тесты: таблица случаев для `WriteGuard` (выключено; пациент вне списка; линия вне списка;
  всё разрешено) + запись в журнал; golden для трёх маршрутов в состоянии «запрещено».

### 2. Флаг опроса MOTCONSU

- `MOTCONSU_POLL_ENABLED`, по умолчанию `false`. В `cmd/api/main.go` `MotconsuPoller`
  стартует только при `true`; при `false` — одна строка лога `motconsu poller disabled`.

### 3. Имя приложения в подключении

- `DB_APP_NAME`, по умолчанию `medkvadrat-patient-api`; добавить `app name=<значение>` в
  строку подключения в `internal/db/mssql.go`. Значение экранировать так же, как остальные
  параметры (без `;`).

### 4. CORS по списку

- `CORS_ALLOWED_ORIGINS` — CSV. Пусто → заголовок `Access-Control-Allow-Origin` не ставится
  вовсе (браузерные запросы с чужих источников не пройдут; S2S и бот не затронуты).
  Иначе — отражать `Origin`, только если он точно есть в списке, плюс `Vary: Origin`.
- Юнит-тест: разрешённый источник, чужой источник, пустой список, `OPTIONS`.

### 5. Здоровье

- `/api/health` возвращает `{"api":"ok","medialog":"ok|unavailable"}`; проверка Медиалога —
  `SELECT 1` с тайм-аутом 2 с. HTTP 200 в обоих случаях (контейнер жив), чтобы healthcheck
  compose не перезапускал API при недоступности МИС.

### 6. Закрыть пути «свободных слотов» (найдено 15.10.2026, блок S1)

В Медиалоге нет заранее созданных пустых строк расписания. Строка `PLANNING` без
`PATIENTS_ID` — это **запись нового пациента** (ФИО введено в строку, ЭМК ещё нет), а не
свободное время. Сейчас:
- `GET /api/catalog/slots` (`internal/repo/catalog.go`) и `GET /api/schedule/slots`
  (`internal/repo/planning.go`) отдают такие строки как свободные;
- `POST /api/schedule/book` и `POST /api/me/appointments` (`booking_me.go`, ветка
  `!slotPat.Valid`) вызывают `planning.FillSlot` — `UPDATE PLANNING SET PATIENTS_ID=…` по
  такой строке, то есть **перезаписывают чужую запись**.

Сделать:
- `GET /api/catalog/slots`, `GET /api/schedule/slots`, `POST /api/schedule/book` — сразу
  `503 FEATURE_DISABLED` с текстом «Онлайн-запись готовится. Позвоните в регистратуру:
  +7 (499) 288-88-14», **без обращения к базе**. Код запросов не удалять (его заменит LK-2a/2b),
  пометить `// Deprecated: wrong free-time model, see docs/lk/00 §3`.
- В `BookMe`: если у целевой строки `PATIENTS_ID IS NULL` — `409 SLOT_NOT_FREE` до любого
  write; `FillSlot` не вызывать ни при каких условиях. Остальная логика `BookMe`/`CancelMe`
  не меняется.
- Бот MAX эти маршруты не вызывает (проверено по `main`) — изменений в боте нет.
- Тесты: golden на три маршрута (`503`); юнит на `BookMe` со строкой без пациента (`409`,
  ноль вызовов `Exec`).

### 7. Логин только на чтение

- В `.env.example` (deploy, см. LK-0a п. 4) `DB_USER=svc_patient_api_ro`, `DB_RW_USER=` пусто
  с комментарием «логин на запись появится после R4 — docs/lk/05, блок 5».
- Read-пути не должны вызывать процедуры и функции Медиалога (у логина `DENY EXECUTE`):
  добавить тест-проверку, что в SQL read-репозиториев нет `EXEC` и `dbo.fn`/`dbo.Get…(`
  (простой поиск по исходникам в `go test`).

### Чеклист PR
- [ ] Новые переменные в `README` и в `.env.example` репозитория
- [ ] Без изменения SQL read-путей и логики записи (кроме п. 6: закрытие «слотов» и запрет `FillSlot`)
- [ ] `go test ./...`, `go vet ./...` зелёные
- [ ] Шаблон PR добавлен

Названия PR: `docs: patient cabinet TZ, knowledge base, workflow` и
`chore(api): LK-0 guards — write allowlists and log, rw connection, poller flag, app name, CORS, disable slot paths`.
Пришли ссылки на оба PR.
