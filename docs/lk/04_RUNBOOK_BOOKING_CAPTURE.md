# Runbook R4: образец записи, переноса и отмены из клиента Медиалога

Цель — увидеть **точно**, какие таблицы и поля меняет клиент Медиалога, когда регистратор
записывает, переносит и отменяет приём. ЛК будет повторять ровно это, ничего не придумывая.

Выполняет только владелец. Изменения в базе — три обычных действия в клиенте Медиалога
на **тестовом пациенте** (`PATIENTS_ID=1`, «Тест Тестовый») и **тестовой линии
расписания** (Q13). Трассировка только читает и пишет файл на сервер БД.

Время: 20–30 минут. Лучше вне часов пик.

---

## 0. Подготовка

1. Подтвердить тестовую линию (Q13):
   ```sql
   SELECT PL_SUBJ_ID, NAME, MEDECINS_ID, FM_INTORG_ID, ISNULL(ARCHIVE,0) AS ARCHIVE,
          WEB_ACCESS, AGENT_ACCESS
   FROM dbo.PL_SUBJ WITH (NOLOCK)
   WHERE NAME LIKE N'%тест%';
   ```
   Выбрать линию, которую не видят пациенты и не использует регистратура. Записать её
   `PL_SUBJ_ID` → `<TEST_PL_SUBJ>`.
2. Узнать логин, под которым вы входите в клиент Медиалога (в трассировке страховых он
   виден как `login_name`, например `DMARTYNOV`) → `<MY_LOGIN>`.
3. Снимок «до»:
   ```sql
   SELECT * FROM dbo.PLANNING WITH (NOLOCK)
   WHERE PATIENTS_ID = 1 AND PL_SUBJ_ID = <TEST_PL_SUBJ>
   ORDER BY PLANNING_ID;
   ```

## 1. Запуск трассировки (только ваш логин)

```sql
IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = 'lk_capture_booking')
    DROP EVENT SESSION lk_capture_booking ON SERVER;
GO
CREATE EVENT SESSION lk_capture_booking ON SERVER
ADD EVENT sqlserver.sql_batch_completed(
  ACTION(sqlserver.client_app_name, sqlserver.username, sqlserver.session_id, sqlserver.transaction_id)
  WHERE sqlserver.username = N'<MY_LOGIN>'),
ADD EVENT sqlserver.rpc_completed(
  ACTION(sqlserver.client_app_name, sqlserver.username, sqlserver.session_id, sqlserver.transaction_id)
  WHERE sqlserver.username = N'<MY_LOGIN>'),
ADD EVENT sqlserver.sql_statement_completed(
  ACTION(sqlserver.client_app_name, sqlserver.username, sqlserver.session_id, sqlserver.transaction_id)
  WHERE sqlserver.username = N'<MY_LOGIN>'
    AND (sqlserver.like_i_sql_unicode_string(statement, N'%INSERT%')
      OR sqlserver.like_i_sql_unicode_string(statement, N'%UPDATE%')
      OR sqlserver.like_i_sql_unicode_string(statement, N'%DELETE%')))
ADD TARGET package0.event_file(
  SET filename = N'C:\Program Files\Microsoft SQL Server\MSSQL.1\MSSQL\LOG\lk_capture_booking.xel',
      max_file_size = 20, max_rollover_files = 2)
WITH (MAX_DISPATCH_LATENCY = 2 SECONDS, STARTUP_STATE = OFF);
GO
ALTER EVENT SESSION lk_capture_booking ON SERVER STATE = START;
SELECT GETDATE() AS CAPTURE_STARTED;
```

Сессия ловит только ваш логин, поэтому действия сотрудников в неё не попадут.
Записать время старта.

## 2. Три действия в клиенте Медиалога

Перед каждым действием и после него записывайте время (до секунды) — по нему потом
разделяются события.

**А. Запись.** Расписание → тестовая линия → свободная ячейка в будущем →
двойной щелчок → пациент «Тест Тестовый» → вид приёма → сохранить.
*Пока окно записи открыто и ещё не сохранено*, выполните в SSMS отдельным окном
(под другим логином или тем же — не страшно, это чтение):
```sql
SELECT t.name, SUM(p.rows) AS ROWS_CNT
FROM sys.tables t JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0,1)
WHERE t.name LIKE '%LOCK%' GROUP BY t.name;
```
Это покажет, где клиент держит блокировку ячейки (R3).

**Б. Перенос.** Ту же запись перенести на другое время тем способом, каким обычно
переносит регистратура.

**В. Отмена.** Перед отменой создайте по записи направление или предоплатный талон, если
регистратура так обычно делает, — чтобы увидеть, что отмена делает с ними. Затем отмените
запись так, как это делает регистратура. Если в клиенте два
варианта («пациент предупредил, что не придёт» и «удалить запись»), сделайте оба на двух
разных записях: создайте вторую запись (как в А) и отмените её вторым способом.

## 3. Остановка и снимок «после»

```sql
ALTER EVENT SESSION lk_capture_booking ON SERVER STATE = STOP;

SELECT * FROM dbo.PLANNING WITH (NOLOCK)
WHERE PATIENTS_ID = 1 AND PL_SUBJ_ID = <TEST_PL_SUBJ>
ORDER BY PLANNING_ID;
```

## 4. Чтение трассировки

```sql
SELECT
    x.value('(event/@timestamp)[1]', 'datetime2') AS TS_UTC,
    x.value('(event/@name)[1]', 'nvarchar(60)') AS EVENT_NAME,
    x.value('(event/action[@name="session_id"]/value)[1]', 'int') AS SPID,
    x.value('(event/action[@name="transaction_id"]/value)[1]', 'bigint') AS TRAN_ID,
    LEFT(COALESCE(
        x.value('(event/data[@name="statement"]/value)[1]', 'nvarchar(max)'),
        x.value('(event/data[@name="batch_text"]/value)[1]', 'nvarchar(max)')), 4000) AS SQL_TEXT
FROM (SELECT CAST(event_data AS xml) AS x
      FROM sys.fn_xe_file_target_read_file(
        N'C:\Program Files\Microsoft SQL Server\MSSQL.1\MSSQL\LOG\lk_capture_booking*.xel',
        NULL, NULL, NULL)) t
ORDER BY TS_UTC;
```

Время в трассировке — UTC (на 3 часа меньше московского).

Сохранить результат в файл. **Перед отправкой проверить**, что в тексте нет данных
других пациентов (их не должно быть: трассировался только ваш логин, а клиент при
открытии расписания читает данные, но текст `SELECT` не содержит результатов). Если есть
сомнения — отправить только строки с `INSERT`, `UPDATE`, `DELETE`, `EXEC`.

## 5. Уборка (обязательно)

```sql
DROP EVENT SESSION lk_capture_booking ON SERVER;
```
Затем удалить файлы `lk_capture_booking*.xel` из папки `LOG` на сервере БД.

Тестовые записи оставить: они понадобятся для сравнения с записями из ЛК (приёмка
этапа 2). Если нужно — отменить их в клиенте.

## 6. Что передать Claude

1. Результат шага 4 (или его write-часть) и время действий А, Б, В.
2. Снимки «до» и «после» из шагов 0 и 3.
3. Таблицы блокировок, которые показал запрос во время шага А.
4. Определения триггеров на `PLANNING` (блок S11).

По ним Claude составит точную спецификацию write-пути для промта LK-2b.
