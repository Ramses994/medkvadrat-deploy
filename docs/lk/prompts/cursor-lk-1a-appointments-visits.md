# Cursor — LK-1a: «Мои записи» и «История» из `PLANNING` (только чтение)

Репозиторий `medkvadrat-patient-api`, ветка `feat/lk-1a-me-planning`, от `main` после LK-0b.
Контекст: ТЗ §4 этап 1 (п. 1.4–1.6), база знаний §3. Только `SELECT`.

**Не подключайся к боевому Медиалогу.** Проверку на живых данных делает владелец на стенде.

## Почему

`GET /api/me/appointments` сейчас читает `MOTCONSU`. Записи, созданные регистратурой, живут
только в `PLANNING` (без `MOTCONSU`), поэтому пациент их не увидит. Проверено на реальной
записи от 26.06.2026.

## Факты о `PLANNING` (база знаний §3)

- Время: `DATEADD(MINUTE,(HEURE/100)*60+(HEURE%100), DATE_CONS)`; отдавать строкой
  `CONVERT(varchar(16), …, 120)` и парсить в Go как Europe/Moscow (как в `reminders.go`).
- Действующая запись: `ISNULL(STATUS,0)=0`.
- `CANCELLED=1` — «Пациент не придёт»: строка остаётся, ячейка считается свободной.
- `PATIENT_ARRIVEE=1` — отметка регистратуры о приходе (ставится вручную или автоматически при
  создании записи ЭМК из расписания); это не подтверждение оказанной услуги.
- Филиал: `PL_SUBJ.FM_INTORG_ID → FM_ORG.CODE`, человекочитаемое имя и адрес — `repo.Branches`.
- Врач: `PL_SUBJ.MEDECINS_ID → MEDECINS` (`NOM`, `PRENOM`, `PATRONYME`).
  **Не использовать `PL_SUBJ.NAME`** — в нём бывает личный телефон врача.
  Если `MEDECINS_ID` пуст (кабинет, аппарат) — `doctor_name = null`.
- Вид приёма: `PL_EXAM.NAME`.

## 1. `GET /api/me/appointments?status=upcoming|past` (замена)

SQL (параметры `@pid`, `@now` строкой `2006-01-02T15:04:05`):

```sql
SELECT TOP (200)
  p.PLANNING_ID,
  CONVERT(varchar(16), DATEADD(MINUTE,(p.HEURE/100)*60+(p.HEURE%100), p.DATE_CONS), 120) AS STARTS_AT,
  ISNULL(p.DUREE, 0) AS DURATION_MIN,
  ISNULL(p.CANCELLED, 0) AS CANCELLED,
  ISNULL(p.PATIENT_ARRIVEE, 0) AS ARRIVED,
  ISNULL(o.FM_ORG_ID, 0) AS BRANCH_ID, ISNULL(o.CODE, '') AS BRANCH_CODE,
  ps.MEDECINS_ID,
  LTRIM(RTRIM(ISNULL(m.NOM,'') + ' ' + ISNULL(m.PRENOM,'') + ' ' + ISNULL(m.PATRONYME,''))) AS DOCTOR_NAME,
  ISNULL(ex.NAME, '') AS EXAM_NAME
FROM dbo.PLANNING p
JOIN dbo.PL_SUBJ ps   ON ps.PL_SUBJ_ID = p.PL_SUBJ_ID
LEFT JOIN dbo.FM_ORG o   ON o.FM_ORG_ID = ps.FM_INTORG_ID
LEFT JOIN dbo.MEDECINS m ON m.MEDECINS_ID = ps.MEDECINS_ID
LEFT JOIN dbo.PL_EXAM ex ON ex.PL_EXAM_ID = p.PL_EXAM_ID
WHERE p.PATIENTS_ID = @pid
  AND ISNULL(p.STATUS, 0) = 0
  AND <окно>
ORDER BY <порядок>
```

- `upcoming`: `DATEADD(...) >= @now`, `ORDER BY DATE_CONS, HEURE` (ближайшая первой).
- `past`: `DATEADD(...) < @now AND p.DATE_CONS >= DATEADD(year,-3,@now)`,
  `ORDER BY DATE_CONS DESC, HEURE DESC`.
- `CANCELLED=1` не исключать: показать со статусом.

DTO (элемент):
```json
{
  "planning_id": 11737097,
  "starts_at": "2026-06-26 19:30",
  "duration_min": 30,
  "state": "scheduled",
  "branch": {"id": 3, "name": "Куркино", "address": "г. Москва, ул. Ландышевая, 14к1"},
  "doctor": {"id": 1828, "name": "Гаевой Эдуард Валерьевич"},
  "exam_name": "Приём стоматолога",
  "confirmation": "confirmed"
}
```
- `state`: `scheduled` (будущая, не отменена), `warned_absent` (`CANCELLED=1`),
  `attended` (`ARRIVED=1`), `not_marked` (время прошло, отметки о приходе нет).
  Не называть это «неявкой»: регистратура отмечает приход не всегда, пациенту показывать
  нейтрально («визит не отмечен»).
- `confirmation` — из `gateway.db` батчем по `planning_id` (переиспользовать
  `confirmations.StatusByPlanningIDs`), иначе `null`.
- `doctor` = `null`, если `MEDECINS_ID` пуст.

## 2. `GET /api/me/visits?from=YYYY-MM-DD&to=YYYY-MM-DD`

Визиты с отметкой о приходе (в интерфейсе — «отмечен приход», не «услуга оказана»): тот же SQL, `ISNULL(p.PATIENT_ARRIVEE,0)=1`, окно по `DATE_CONS`
(по умолчанию последние 12 месяцев, максимум 3 года), `TOP (500)`, новые сверху. DTO —
как выше, `state` всегда `attended`.

## 3. Права доступа

- `patient_id` — только из JWT. Никаких `patient_id` в query.
- Никаких изменений в DELETE/POST записи (они под флагом из LK-0b).

## 4. Тесты

- Golden: upcoming (2 записи, одна с `CANCELLED=1`), past с `attended` и `not_marked`,
  пустой ответ, visits.
- Юнит: расчёт `state`; формат `starts_at`; `doctor=null` при пустом `MEDECINS_ID`;
  адрес филиала из `Branches`, неизвестный `branch_id` → `name = branch_code`, `address = null`.
- Проверить, что `PL_SUBJ.NAME` нигде не попадает в ответ.

## 5. Проверка на стенде (делает владелец)

```
GET /api/me/appointments?status=upcoming   (JWT профиля владельца)
GET /api/me/visits?from=2026-01-01&to=2026-10-14
```
Сверка с блоком S3 из `docs/lk/03_VERIFICATION_SQL.sql`: те же `planning_id`, время,
филиал; ФИО и телефоны в логах отсутствуют.

## Чеклист PR
- [ ] Только `SELECT`; `PL_SUBJ.NAME` не используется
- [ ] `patient_id` только из токена
- [ ] Время строкой из SQL, без UTC-сдвига
- [ ] Overlay подтверждений одним запросом
- [ ] `go test ./...`, `go vet ./...` зелёные

PR: `feat(api): /api/me/appointments and /api/me/visits from PLANNING (read-only)`.
