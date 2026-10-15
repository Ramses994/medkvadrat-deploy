/* =====================================================================
   Служебная учётная запись API личного кабинета — ТОЛЬКО ЧТЕНИЕ.
   Версия 1.3 — 15.10.2026 (ТЗ §7.2, решение D2).

   Почему переписано. Блок 0 (выполнен 15.10.2026) показал: роли public в
   Medialog выданы INSERT/UPDATE/DELETE/ALTER примерно на 1 280 объектов
   (включая PATIENTS, PLANNING, MOTCONSU, FM_INVOICE), EXECUTE на 333 модуля,
   CONTROL на 6 объектов, TAKE OWNERSHIP на 3 (сводка блока 0).
   Права public получает КАЖДЫЙ пользователь базы. Поэтому:
   - db_datareader сам по себе не делает логин «только чтение»;
   - запреты ставятся на уровне всей базы (DENY перекрывает любой GRANT);
   - учётная запись на запись (svc_patient_api_rw) сейчас НЕ создаётся:
     через public она получила бы запись во все таблицы. Её схема прав —
     после разбора образца записи (runbook 04, R4).

   Что меняется в базе: создаётся логин сервера, пользователь в Medialog,
   членство в db_datareader и запреты (DENY) только для этого пользователя.
   Таблицы, данные, процедуры и права других пользователей НЕ меняются.

   Выполняет владелец под учётной записью администратора SQL Server, в SSMS,
   ПО БЛОКАМ (выделить блок → F5). Скрипт выгрузки Export-SqlResults.ps1 этот
   файл целиком не выполняет (в нём CREATE/DENY) — это ожидаемо.

   Перед запуском — сгенерировать пароль (PowerShell 5.1 или 7), только буквы
   и цифры: символы ; $ # = { } ' " ломают строку подключения или .env.
       $c=[char[]]'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
       $b=New-Object byte[] 32
       [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
       -join ($b | ForEach-Object { $c[$_ % $c.Length] })
   Подставить вместо <ПАРОЛЬ_RO> в блоке 1. Хранить только в .env стенда.
   (15.10.2026 запуск с заглушкой <ПАРОЛЬ_RO> упал на политике паролей —
   ничего не создано; проверка вернула пустой список логинов.)

   Always On нет (блок S6 пуст) — логин создаётся на одном сервере.
   ===================================================================== */


/* ---------- 0. Что уже выдано роли public (только чтение) -------------------
   Сводка вместо 5 000 строк. */
USE [Medialog];
SELECT p.class_desc, p.permission_name, p.state_desc, COUNT(*) AS N
FROM sys.database_permissions p
WHERE p.grantee_principal_id = DATABASE_PRINCIPAL_ID(N'public')
GROUP BY p.class_desc, p.permission_name, p.state_desc
ORDER BY p.class_desc, p.permission_name, p.state_desc;
GO


/* ---------- 1. Логин и пользователь ---------------------------------------- */
USE [master];
CREATE LOGIN [svc_patient_api_ro]
    WITH PASSWORD = N'<ПАРОЛЬ_RO>',
         DEFAULT_DATABASE = [Medialog],
         CHECK_POLICY = ON, CHECK_EXPIRATION = OFF;
GO
USE [Medialog];
CREATE USER [svc_patient_api_ro] FOR LOGIN [svc_patient_api_ro] WITH DEFAULT_SCHEMA = [dbo];
ALTER ROLE [db_datareader] ADD MEMBER [svc_patient_api_ro];
GO


/* ---------- 2. Запреты ------------------------------------------------------
   2а. На уровне всей базы: изменение данных, изменение объектов, выполнение
       процедур и функций, создание объектов. DENY сильнее GRANT от public.
       EXECUTE запрещён целиком: процедуры (например, CreateMotconsu,
       AddToAccount) через цепочку владения меняют данные в обход запретов
       на таблицы. Read-пути API процедур и функций не вызывают (проверено
       по коду main 15.10.2026). Проверка email — в коде API, не через
       dbo.fnEmailCheck. */
USE [Medialog];
DENY INSERT, UPDATE, DELETE, ALTER, EXECUTE, REFERENCES TO [svc_patient_api_ro];
DENY CREATE TABLE, CREATE VIEW, CREATE PROCEDURE, CREATE FUNCTION,
     CREATE SYNONYM, CREATE TYPE, CREATE SCHEMA, CREATE DEFAULT, CREATE RULE
     TO [svc_patient_api_ro];
GO

/* 2б. Объекты, на которые у public есть CONTROL (15.10.2026: dl_medecins_mail2,
       mkbcode, mkbdescr, mkbdescrmotconsu, teeth, teethmotconsu). CONTROL даёт
       право стать владельцем объекта, а на владельца запреты не действуют.
       DENY CONTROL закрывает объект полностью (и чтение тоже) — API они не нужны.
       Список строится из базы; сначала печатается, потом выполняется. */
USE [Medialog];
DECLARE @sql nvarchar(max) = N'';
SELECT @sql = @sql + N'DENY CONTROL ON OBJECT::' + QUOTENAME(s.name) + N'.' + QUOTENAME(o.name)
            + N' TO [svc_patient_api_ro];' + NCHAR(10)
FROM sys.database_permissions p
JOIN sys.objects o ON o.object_id = p.major_id
JOIN sys.schemas s ON s.schema_id = o.schema_id
WHERE p.grantee_principal_id = DATABASE_PRINCIPAL_ID(N'public')
  AND p.class = 1
  AND p.permission_name = N'CONTROL'
  AND p.state IN ('G', 'W');
PRINT @sql;
EXEC sys.sp_executesql @sql;
GO

/* 2в. Таблица с учётными данными почтовых рассылок (поле PWD) — API не нужна. */
USE [Medialog];
IF OBJECT_ID(N'dbo.DS_RESMSGTYPES', N'U') IS NOT NULL
    DENY SELECT ON OBJECT::[dbo].[DS_RESMSGTYPES] TO [svc_patient_api_ro];
GO

/* 2г. (добавлен 15.10.2026 после первого запуска) У public есть TAKE OWNERSHIP на
       3 объекта. Владельца запреты не касаются, поэтому закрываем и это. Сначала
       показывает, какие объекты, затем запрещает. Повторный запуск безопасен. */
USE [Medialog];
SELECT s.name AS schema_name, o.name AS object_name, o.type_desc
FROM sys.database_permissions p
JOIN sys.objects o ON o.object_id = p.major_id
JOIN sys.schemas s ON s.schema_id = o.schema_id
WHERE p.grantee_principal_id = DATABASE_PRINCIPAL_ID(N'public')
  AND p.class = 1 AND p.permission_name = N'TAKE OWNERSHIP' AND p.state IN ('G', 'W');

DECLARE @sql nvarchar(max) = N'';
SELECT @sql = @sql + N'DENY TAKE OWNERSHIP ON OBJECT::' + QUOTENAME(s.name) + N'.' + QUOTENAME(o.name)
            + N' TO [svc_patient_api_ro];' + NCHAR(10)
FROM sys.database_permissions p
JOIN sys.objects o ON o.object_id = p.major_id
JOIN sys.schemas s ON s.schema_id = o.schema_id
WHERE p.grantee_principal_id = DATABASE_PRINCIPAL_ID(N'public')
  AND p.class = 1 AND p.permission_name = N'TAKE OWNERSHIP' AND p.state IN ('G', 'W');
PRINT @sql;
EXEC sys.sp_executesql @sql;

/* Контроль: ровно эти объекты от имени нового пользователя (ожидается 0 во всех строках) */
IF OBJECT_ID(N'tempdb..#tko') IS NOT NULL DROP TABLE #tko;
SELECT QUOTENAME(s.name) + N'.' + QUOTENAME(o.name) AS full_name
INTO #tko
FROM sys.database_permissions p
JOIN sys.objects o ON o.object_id = p.major_id
JOIN sys.schemas s ON s.schema_id = o.schema_id
WHERE p.grantee_principal_id = DATABASE_PRINCIPAL_ID(N'public')
  AND p.class = 1 AND p.permission_name = N'TAKE OWNERSHIP';
EXECUTE AS USER = N'svc_patient_api_ro';
SELECT full_name,
       ISNULL(HAS_PERMS_BY_NAME(full_name, 'OBJECT', 'TAKE OWNERSHIP'), 0) AS CAN_TAKE_OWNERSHIP,
       ISNULL(HAS_PERMS_BY_NAME(full_name, 'OBJECT', 'CONTROL'), 0)        AS CAN_CONTROL
FROM #tko;
REVERT;
DROP TABLE #tko;
GO


/* ---------- 3. Проверка (ничего не меняет) ----------------------------------
   Права проверяются от имени нового пользователя функцией HAS_PERMS_BY_NAME —
   без попыток записи. Ожидается: все счётчики CAN_* = 0, кроме
   CAN_SELECT_PLANNING = 1 и CAN_SELECT_PATIENTS = 1. */
USE [Medialog];
SELECT name, type_desc, default_database_name, is_disabled
FROM sys.server_principals WHERE name LIKE N'svc_patient_api%';

IF OBJECT_ID(N'tempdb..#obj') IS NOT NULL DROP TABLE #obj;
SELECT QUOTENAME(s.name) + N'.' + QUOTENAME(o.name) AS full_name, o.type
INTO #obj
FROM sys.objects o
JOIN sys.schemas s ON s.schema_id = o.schema_id
WHERE o.is_ms_shipped = 0
  AND o.type IN ('U', 'V', 'P', 'PC', 'X', 'FN', 'IF', 'TF', 'FS', 'FT');

EXECUTE AS USER = N'svc_patient_api_ro';
SELECT
  SUM(CASE WHEN type IN ('U','V') AND HAS_PERMS_BY_NAME(full_name, 'OBJECT', 'INSERT') = 1 THEN 1 ELSE 0 END) AS CAN_INSERT,
  SUM(CASE WHEN type IN ('U','V') AND HAS_PERMS_BY_NAME(full_name, 'OBJECT', 'UPDATE') = 1 THEN 1 ELSE 0 END) AS CAN_UPDATE,
  SUM(CASE WHEN type IN ('U','V') AND HAS_PERMS_BY_NAME(full_name, 'OBJECT', 'DELETE') = 1 THEN 1 ELSE 0 END) AS CAN_DELETE,
  SUM(CASE WHEN HAS_PERMS_BY_NAME(full_name, 'OBJECT', 'ALTER') = 1 THEN 1 ELSE 0 END)                         AS CAN_ALTER,
  SUM(CASE WHEN HAS_PERMS_BY_NAME(full_name, 'OBJECT', 'TAKE OWNERSHIP') = 1 THEN 1 ELSE 0 END)                AS CAN_TAKE_OWNERSHIP,
  SUM(CASE WHEN type NOT IN ('U','V') AND HAS_PERMS_BY_NAME(full_name, 'OBJECT', 'EXECUTE') = 1 THEN 1 ELSE 0 END) AS CAN_EXECUTE,
  HAS_PERMS_BY_NAME(NULL, 'DATABASE', 'CREATE TABLE')     AS CAN_CREATE_TABLE,
  HAS_PERMS_BY_NAME(NULL, 'DATABASE', 'CREATE PROCEDURE') AS CAN_CREATE_PROC,
  HAS_PERMS_BY_NAME(NULL, 'DATABASE', 'ALTER')            AS CAN_ALTER_DB,
  HAS_PERMS_BY_NAME(N'[dbo].[PLANNING]', 'OBJECT', 'SELECT') AS CAN_SELECT_PLANNING,
  HAS_PERMS_BY_NAME(N'[dbo].[PATIENTS]', 'OBJECT', 'SELECT') AS CAN_SELECT_PATIENTS
FROM #obj;
REVERT;
DROP TABLE #obj;

/* Запреты, выданные пользователю (для отчёта) */
SELECT p.class_desc, p.permission_name, p.state_desc, OBJECT_NAME(p.major_id) AS OBJECT_NAME
FROM sys.database_permissions p
WHERE p.grantee_principal_id = DATABASE_PRINCIPAL_ID(N'svc_patient_api_ro')
ORDER BY p.class_desc, p.permission_name;
GO


/* ---------- 4. Переключение API ---------------------------------------------
   Делать ПОСЛЕ того, как блок 3 показал нули.
   В .env стенда (192.168.2.104):
     DB_USER=svc_patient_api_ro
     DB_PASSWORD=<ПАРОЛЬ_RO>
     DB_RW_USER=                     # пусто: write-пути отвечают 503 (после LK-0b)
   Перезапустить api-gateway и проверить:
     - /api/health → medialog: ok;
     - бот: «мои анализы», напоминания (/api/reminders/due), дашборд;
     - write-пути (запись, отмена) до LK-0b ответят ошибкой прав SQL — это и есть
       нужная защита.
   Старую личную учётную запись из .env убрать и сменить её пароль.

   Если что-то из чтения перестало работать — вернуть прежний DB_USER, прислать
   строку ошибки из журнала api-gateway (без ПДн). Откат (только при
   необходимости):  DROP USER [svc_patient_api_ro];  (в Medialog)
                    DROP LOGIN [svc_patient_api_ro]; (в master)
   ------------------------------------------------------------------------- */


/* ---------- 5. svc_patient_api_rw — не создавать до R4 -----------------------
   Через public такой логин получит INSERT/UPDATE/DELETE на все таблицы, а
   запрет на уровне базы перекрыл бы и нужные права на PLANNING. Варианты
   (выбор — после runbook 04):
   а) DENY на уровне объектов для всех таблиц, кроме списка из образца R4,
      с повторной проверкой после каждого обновления Медиалога;
   б) запись только через отдельную схему/процедуру с подписью сертификатом
      (требует создания объектов в Medialog — отдельное решение владельца);
   в) (найдено 15.10.2026, S17; предпочтительно, решение Q17) запись только
      через штатную процедуру онлайн-записи Медиалога pl_AddVisitContext и
      процедуру отмены: на уровне базы DENY INSERT/UPDATE/DELETE/ALTER и
      создания объектов; GRANT EXECUTE на 2–3 процедуры; DENY EXECUTE поштучно
      на все остальные процедуры (EXECUTE на уровне базы не запрещать — такой
      запрет перекрыл бы и нужный GRANT). Процедуры владельца dbo пишут в
      таблицы по цепочке владения, поэтому запреты на таблицы им не мешают,
      а прямой INSERT/UPDATE из API невозможен. После каждого обновления
      Медиалога — повторная проверка (новые процедуры без DENY).
   ------------------------------------------------------------------------- */


/* ---------- 6. Проверка для LK-2a: может ли svc_patient_api_ro читать штатную
   функцию свободного времени (ничего не меняет). Ожидается CAN_SELECT = 1.
   Если 0 — сообщить: для LK-2a понадобится GRANT SELECT на эту функцию. ------- */
USE [Medialog];
EXECUTE AS USER = N'svc_patient_api_ro';
SELECT HAS_PERMS_BY_NAME(N'[dbo].[pl_TelemedGetAvaliableSlots]', 'OBJECT', 'SELECT') AS CAN_SELECT_SLOTS_TVF,
       HAS_PERMS_BY_NAME(N'[dbo].[pl_GetMedecinGridFunc]', 'OBJECT', 'SELECT')       AS CAN_SELECT_GRID_TVF;
REVERT;
GO
