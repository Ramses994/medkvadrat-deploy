/* =====================================================================
   Проверки перед разработкой ЛК — ТОЛЬКО ЧТЕНИЕ. Версия 1.3 — 15.10.2026
   (S0–S18 выполнены 15.10.2026; добавлен S19).
   Объединены пакет Claude (V*) и сверка ChatGPT (C*).

   База Medialog, сервер 192.168.2.229, SQL Server 2014. Запускать в SSMS
   по одному блоку (между блоками — GO). Блоки возвращают схему, агрегаты
   или строки только тестового профиля (1) и профиля владельца (1587578).

   Уровень изоляции не меняется: нужны подтверждённые данные. Окна дат
   узкие, чтобы чтение было коротким. Если блок идёт дольше 60 секунд —
   отменить и сообщить.

   Ограничения выводов:
   - нули в окне дат не доказывают отсутствие данных за всё время;
   - отсутствие объекта при ограниченной видимости метаданных не доказано
     (блок S0 показывает, есть ли VIEW DEFINITION);
   - распределение значений не заменяет словарь статусов.

   Выгрузка всех результатов в файлы одной командой (CSV + xlsx + zip):
     powershell -ExecutionPolicy Bypass -File tools\Export-SqlResults.ps1 -SqlFile 03_VERIFICATION_SQL.sql
   Результат передать Claude zip-архивом из tools\results\.
   ===================================================================== */
SET NOCOUNT ON;
GO

/* ---------------------------------------------------------------------
   S0 [C0]. Видимость метаданных и схема ключевых объектов
   --------------------------------------------------------------------- */
SELECT DB_NAME() AS database_name,
       HAS_PERMS_BY_NAME(DB_NAME(), N'DATABASE', N'VIEW DEFINITION') AS can_view_definition;

SELECT o.name AS object_name, o.type_desc, c.name AS column_name, ty.name AS data_type,
       c.max_length, c.is_nullable
FROM sys.objects o
JOIN sys.columns c ON c.object_id = o.object_id
JOIN sys.types ty ON ty.user_type_id = c.user_type_id
WHERE o.type IN ('U','V')
  AND o.name IN (N'PL_DAY',N'PL_INT',N'PL_EXCL',N'PL_AGEND',N'PL_SUBJ_PARAM',
                 N'PL_GENER',N'PL_PARAM',N'PL_EXAM',N'SMS_VIEW_PLANNING')
ORDER BY o.name, c.column_id;
GO

/* ---------------------------------------------------------------------
   S1 [V1+C1] (Q1). Строки PLANNING без пациента на ближайшие 14 дней.
   Важно: запись НОВОГО пациента без ЭМК тоже даёт PATIENTS_ID IS NULL,
   но с введённым именем (справка, «Записать на прием нового пациента»).
   Поэтому PATIENTS_ID IS NULL ≠ свободный слот. Имена не выводятся.
   --------------------------------------------------------------------- */
SELECT
    CASE WHEN PATIENTS_ID IS NULL THEN 'NO_PATIENT_ID' ELSE 'HAS_PATIENT_ID' END AS ROW_KIND,
    ISNULL(CONVERT(varchar(10), STATUS), 'NULL') AS STATUS,
    ISNULL(CANCELLED, 0) AS CANCELLED,
    CASE WHEN NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(255), NOM))), N'') IS NOT NULL
           OR NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(255), PRENOM))), N'') IS NOT NULL
         THEN 1 ELSE 0 END AS HAS_ENTERED_NAME,
    CASE WHEN PL_GENER_ID IS NULL THEN 0 ELSE 1 END AS HAS_GENERATOR,
    COUNT_BIG(*) AS N
FROM dbo.PLANNING
WHERE DATE_CONS >= CONVERT(date, GETDATE())
  AND DATE_CONS <  DATEADD(day, 14, CONVERT(date, GETDATE()))
GROUP BY CASE WHEN PATIENTS_ID IS NULL THEN 'NO_PATIENT_ID' ELSE 'HAS_PATIENT_ID' END,
         ISNULL(CONVERT(varchar(10), STATUS), 'NULL'), ISNULL(CANCELLED, 0),
         CASE WHEN NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(255), NOM))), N'') IS NOT NULL
                OR NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(255), PRENOM))), N'') IS NOT NULL
              THEN 1 ELSE 0 END,
         CASE WHEN PL_GENER_ID IS NULL THEN 0 ELSE 1 END
ORDER BY ROW_KIND, STATUS;
GO

/* ---------------------------------------------------------------------
   S2 [V2+C3] (Q2). Статусы PLANNING и MOTCONSU: описания в схеме и
   распределения за прошедшие 30 дней
   --------------------------------------------------------------------- */
SELECT OBJECT_NAME(c.object_id) AS table_name, c.name AS column_name,
       ep.name AS property_name, CONVERT(nvarchar(4000), ep.value) AS property_value
FROM sys.columns c
LEFT JOIN sys.extended_properties ep
  ON ep.class = 1 AND ep.major_id = c.object_id AND ep.minor_id = c.column_id
WHERE (c.object_id = OBJECT_ID(N'dbo.PLANNING') AND c.name IN (N'STATUS', N'CANCELLED', N'PATIENT_ARRIVEE'))
   OR (c.object_id = OBJECT_ID(N'dbo.MOTCONSU') AND c.name IN (N'REC_STATUS', N'CONS_STATUS'));

/* Описания полей в метаданных самого Медиалога (METAFIELD) */
SELECT TABLE_NAME, FIELD_NAME, CONVERT(nvarchar(2000), CUSTOM) AS FIELD_SETTINGS
FROM dbo.METAFIELD
WHERE (TABLE_NAME = 'PLANNING' AND FIELD_NAME IN ('STATUS', 'CANCELLED', 'PATIENT_ARRIVEE'))
   OR (TABLE_NAME = 'MOTCONSU' AND FIELD_NAME IN ('REC_STATUS', 'CONS_STATUS'));

SELECT ISNULL(CONVERT(varchar(10), STATUS), 'NULL') AS STATUS,
       ISNULL(CANCELLED, 0) AS CANCELLED, ISNULL(PATIENT_ARRIVEE, 0) AS ARRIVED,
       SUM(CASE WHEN DATE_CANCEL IS NOT NULL THEN 1 ELSE 0 END) AS HAS_DATE_CANCEL,
       SUM(CASE WHEN SOURCE_PLANNING_ID IS NOT NULL THEN 1 ELSE 0 END) AS HAS_SOURCE,
       COUNT_BIG(*) AS N
FROM dbo.PLANNING
WHERE DATE_CONS >= DATEADD(day, -30, CONVERT(date, GETDATE()))
  AND DATE_CONS <  CONVERT(date, GETDATE())
  AND PATIENTS_ID IS NOT NULL
GROUP BY ISNULL(CONVERT(varchar(10), STATUS), 'NULL'), ISNULL(CANCELLED, 0), ISNULL(PATIENT_ARRIVEE, 0)
ORDER BY STATUS, CANCELLED, ARRIVED;

SELECT ISNULL(REC_STATUS, 'NULL') AS REC_STATUS,
       CASE WHEN CANCEL_DATE_TIME IS NULL THEN 0 ELSE 1 END AS HAS_CANCEL_TIME,
       CASE WHEN PLANNING_ID IS NULL THEN 0 ELSE 1 END AS HAS_PLANNING_LINK,
       COUNT_BIG(*) AS N
FROM dbo.MOTCONSU
WHERE DATE_CONSULTATION >= DATEADD(day, -30, CONVERT(date, GETDATE()))
  AND DATE_CONSULTATION <  CONVERT(date, GETDATE())
GROUP BY ISNULL(REC_STATUS, 'NULL'),
         CASE WHEN CANCEL_DATE_TIME IS NULL THEN 0 ELSE 1 END,
         CASE WHEN PLANNING_ID IS NULL THEN 0 ELSE 1 END;

/* Процедуры расписания, где STATUS описан комментариями (имена) */
SELECT o.name, o.type_desc
FROM sys.sql_modules m
JOIN sys.objects o ON o.object_id = m.object_id
WHERE o.name LIKE 'pl[_]%' AND m.definition LIKE '%STATUS%'
ORDER BY o.name;
/* Затем: SELECT OBJECT_DEFINITION(OBJECT_ID('dbo.pl_GetPatientVisitsList'));
   передать фрагменты с комментариями про STATUS. */
GO

/* ---------------------------------------------------------------------
   S3 [V4] (этап 1). Записи тестового профиля и владельца — эталон для ЛК
   --------------------------------------------------------------------- */
SELECT TOP 40
    p.PLANNING_ID, p.PATIENTS_ID,
    CONVERT(varchar(16), DATEADD(MINUTE,(p.HEURE/100)*60+(p.HEURE%100), p.DATE_CONS), 120) AS VISIT_AT,
    p.DUREE, ISNULL(p.STATUS,-1) AS STATUS, ISNULL(p.CANCELLED,0) AS CANCELLED,
    ISNULL(p.PATIENT_ARRIVEE,0) AS ARRIVED, p.SOURCE_PLANNING_ID,
    ps.PL_SUBJ_ID, ps.FM_INTORG_ID, o.CODE AS BRANCH, ps.MEDECINS_ID, ex.NAME AS EXAM_NAME,
    CASE WHEN EXISTS (SELECT 1 FROM dbo.MOTCONSU m WHERE m.PLANNING_ID = p.PLANNING_ID)
         THEN 1 ELSE 0 END AS HAS_MOTCONSU
FROM dbo.PLANNING p
JOIN dbo.PL_SUBJ ps ON ps.PL_SUBJ_ID = p.PL_SUBJ_ID
LEFT JOIN dbo.FM_ORG o ON o.FM_ORG_ID = ps.FM_INTORG_ID
LEFT JOIN dbo.PL_EXAM ex ON ex.PL_EXAM_ID = p.PL_EXAM_ID
WHERE p.PATIENTS_ID IN (1, 1587578)
ORDER BY p.DATE_CONS DESC, p.HEURE DESC;

SELECT CASE WHEN MEDECINS_ID IS NULL THEN 'NO_DOCTOR' ELSE 'DOCTOR' END AS KIND, COUNT(*) AS CNT
FROM dbo.PL_SUBJ
WHERE ISNULL(ARCHIVE, 0) = 0
GROUP BY CASE WHEN MEDECINS_ID IS NULL THEN 'NO_DOCTOR' ELSE 'DOCTOR' END;
GO

/* ---------------------------------------------------------------------
   S4 [C5] (Q5). SMS-объекты в схеме и флаги оповещений PLANNING.
   Имена журналов SMS не предполагаются — ищутся по каталогу.
   Флаги ALERTED* не доказывают доставку пациенту.
   --------------------------------------------------------------------- */
SELECT o.name AS object_name, o.type_desc, c.name AS column_name, ty.name AS data_type
FROM sys.objects o
JOIN sys.columns c ON c.object_id = o.object_id
JOIN sys.types ty ON ty.user_type_id = c.user_type_id
WHERE o.type IN ('U','V') AND o.name LIKE N'%SMS%'
ORDER BY o.name, c.column_id;

SELECT referenced_schema_name, referenced_entity_name
FROM sys.sql_expression_dependencies
WHERE referencing_id = OBJECT_ID(N'dbo.SMS_VIEW_PLANNING');

SELECT COUNT_BIG(*) AS TOTAL,
       SUM(CONVERT(bigint, CASE WHEN ALERTED = 1 THEN 1 ELSE 0 END)) AS ALERTED_1,
       SUM(CONVERT(bigint, CASE WHEN ALERTED2 = 1 THEN 1 ELSE 0 END)) AS ALERTED2_1,
       SUM(CONVERT(bigint, CASE WHEN ALERTED_CANCEL = 1 THEN 1 ELSE 0 END)) AS ALERTED_CANCEL_1,
       SUM(CONVERT(bigint, CASE WHEN ISNULL(FORCE_SEND_SMS,0) <> 0 THEN 1 ELSE 0 END)) AS FORCE_SEND_SMS,
       SUM(CONVERT(bigint, CASE WHEN ARRIVEE_SETTED_BY_ANSWER = 1 THEN 1 ELSE 0 END)) AS ARRIVEE_BY_ANSWER
FROM dbo.PLANNING
WHERE DATE_CONS >= DATEADD(day, -14, CONVERT(date, GETDATE()))
  AND DATE_CONS <  CONVERT(date, GETDATE());
GO

/* ---------------------------------------------------------------------
   S5 [C6]. WEB-маркеры и автор 2 за 14 дней (по дате создания).
   Значения WEB_USER не выводятся. Нули относятся только к окну.
   --------------------------------------------------------------------- */
SELECT CASE WHEN KRN_CREATE_USER_ID = 2 THEN 1 ELSE 0 END AS CREATOR_IS_2,
       COUNT_BIG(*) AS N,
       SUM(CONVERT(bigint, CASE WHEN CR_WEB = 1 THEN 1 ELSE 0 END)) AS CR_WEB_1,
       SUM(CONVERT(bigint, CASE WHEN NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(255), WEB_USER))), N'') IS NOT NULL
                                THEN 1 ELSE 0 END)) AS WEB_USER_FILLED,
       SUM(CONVERT(bigint, CASE WHEN SOURCE_CODE IS NOT NULL THEN 1 ELSE 0 END)) AS SOURCE_CODE_NONNULL,
       SUM(CONVERT(bigint, CASE WHEN CHANEL_CODE IS NOT NULL THEN 1 ELSE 0 END)) AS CHANEL_CODE_NONNULL
FROM dbo.PLANNING
WHERE CREATE_DATE_TIME >= DATEADD(day, -14, CONVERT(date, GETDATE()))
  AND CREATE_DATE_TIME <  DATEADD(day, 1, CONVERT(date, GETDATE()))
GROUP BY CASE WHEN KRN_CREATE_USER_ID = 2 THEN 1 ELSE 0 END;

/* Включён ли WEB-доступ на линиях и видах приёма (если клиника их ведёт) */
SELECT 'PL_SUBJ' AS SRC, ISNULL(WEB_ACCESS,0) AS WEB_ACCESS, ISNULL(AGENT_ACCESS,0) AS AGENT_ACCESS, COUNT(*) AS N
FROM dbo.PL_SUBJ WHERE ISNULL(ARCHIVE,0) = 0
GROUP BY ISNULL(WEB_ACCESS,0), ISNULL(AGENT_ACCESS,0);
GO

/* ---------------------------------------------------------------------
   S6 [V6] (Q6). Always On: есть ли читаемая вторичная реплика
   --------------------------------------------------------------------- */
SELECT ag.name AS AG_NAME, ar.replica_server_name, ar.availability_mode_desc,
       ar.secondary_role_allow_connections_desc, rs.role_desc
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar ON ar.group_id = ag.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states rs ON rs.replica_id = ar.replica_id;
GO

/* ---------------------------------------------------------------------
   S7 [V7+C2] (Q9). Сетка расписания: объём таблиц и связи (FK).
   Отсутствие FK не исключает связь, реализованную клиентом.
   --------------------------------------------------------------------- */
SELECT t.name AS TABLE_NAME, SUM(pt.rows) AS ROWS_CNT
FROM sys.tables t
JOIN sys.partitions pt ON pt.object_id = t.object_id AND pt.index_id IN (0,1)
WHERE t.name IN ('PL_DAY','PL_INT','PL_EXCL','PL_AGEND','PL_SUBJ','PL_PARAM','PL_EXAM','PL_SUBJ_PARAM','PL_GENER')
GROUP BY t.name ORDER BY t.name;

SELECT OBJECT_NAME(f.parent_object_id) AS source_table,
       COL_NAME(f.parent_object_id, f.parent_column_id) AS source_column,
       OBJECT_NAME(f.referenced_object_id) AS target_table,
       COL_NAME(f.referenced_object_id, f.referenced_column_id) AS target_column
FROM sys.foreign_key_columns f
WHERE OBJECT_NAME(f.parent_object_id) IN (N'PL_DAY',N'PL_INT',N'PL_EXCL',N'PL_AGEND',N'PL_SUBJ_PARAM',N'PL_GENER',N'PL_SUBJ')
   OR OBJECT_NAME(f.referenced_object_id) IN (N'PL_DAY',N'PL_INT',N'PL_EXCL',N'PL_AGEND',N'PL_SUBJ_PARAM',N'PL_GENER',N'PL_SUBJ')
ORDER BY source_table, source_column;

/* Логические связи по метаданным Медиалога */
SELECT PARENT, CHILD, KEY_FIELDS, REF_FIELDS, KIND
FROM dbo.TABLELINK
WHERE PARENT IN ('PL_DAY','PL_INT','PL_EXCL','PL_AGEND','PL_SUBJ','PL_PARAM','PL_GENER')
   OR CHILD  IN ('PL_DAY','PL_INT','PL_EXCL','PL_AGEND','PL_SUBJ','PL_PARAM','PL_GENER')
ORDER BY PARENT, CHILD;
GO

/* ---------------------------------------------------------------------
   S8 [V8] (этап 1). Покрытие email для кода входа, пациенты за 14 дней.
   dbo.fnEmailCheck — скалярная функция, поэтому окно короткое.
   --------------------------------------------------------------------- */
WITH pats AS (
    SELECT DISTINCT PATIENTS_ID
    FROM dbo.PLANNING
    WHERE DATE_CONS >= DATEADD(day, -14, CONVERT(date, GETDATE()))
      AND DATE_CONS <  CONVERT(date, GETDATE())
      AND PATIENTS_ID IS NOT NULL
)
SELECT COUNT(*) AS PATIENTS,
       SUM(CASE WHEN e.E1 IS NOT NULL THEN 1 ELSE 0 END) AS EMAIL_VALID,
       SUM(CASE WHEN COALESCE(e.E1, e.E2) IS NOT NULL THEN 1 ELSE 0 END) AS EMAIL_ANY_VALID
FROM pats
JOIN dbo.PATIENTS pt ON pt.PATIENTS_ID = pats.PATIENTS_ID
CROSS APPLY (SELECT NULLIF(dbo.fnEmailCheck(CONVERT(varchar(255), pt.EMAIL)), '') AS E1,
                    NULLIF(dbo.fnEmailCheck(CONVERT(varchar(255), pt.ELEKTRONNAYA_POCHTA)), '') AS E2) e;
GO

/* ---------------------------------------------------------------------
   S9 [V14] (Q11 закрыт: любая из двух отметок e-mail; Q12). Согласия
   активных пациентов (записи за 90 дней). Только агрегаты.
   --------------------------------------------------------------------- */
WITH pats AS (
    SELECT DISTINCT PATIENTS_ID
    FROM dbo.PLANNING
    WHERE DATE_CONS >= DATEADD(day, -90, CONVERT(date, GETDATE()))
      AND PATIENTS_ID IS NOT NULL
)
SELECT COUNT(*) AS PATIENTS,
       SUM(CASE WHEN pt.EMAIL_S_REZUL_TATAMI_ISSL = 1 THEN 1 ELSE 0 END) AS EMAIL_RESULTS,
       SUM(CASE WHEN pt.EMAIL_O_GRAFIKE_RABOTY_I_ = 1 THEN 1 ELSE 0 END) AS EMAIL_SCHEDULE_PROMO,
       SUM(CASE WHEN pt.EMAIL_S_REZUL_TATAMI_ISSL = 1 OR pt.EMAIL_O_GRAFIKE_RABOTY_I_ = 1 THEN 1 ELSE 0 END) AS EMAIL_ANY_FLAG,
       SUM(CASE WHEN w.MESSENGER_NOTIFY = 1 THEN 1 ELSE 0 END) AS MESSENGER_YES,
       SUM(CASE WHEN w.MESSENGER_NOTIFY = 0 THEN 1 ELSE 0 END) AS MESSENGER_NO,
       SUM(CASE WHEN w.PATIENTS_ID IS NULL THEN 1 ELSE 0 END) AS MESSENGER_NO_FORM
FROM pats
JOIN dbo.PATIENTS pt ON pt.PATIENTS_ID = pats.PATIENTS_ID
LEFT JOIN dbo.DATA_W3_RASSYLKA w ON w.PATIENTS_ID = pats.PATIENTS_ID;
GO

/* ---------------------------------------------------------------------
   S10 [V9] (D2). Права текущего логина — что он может менять
   --------------------------------------------------------------------- */
SELECT dp.permission_name, dp.state_desc, dp.class_desc
FROM sys.database_permissions dp
JOIN sys.database_principals pr ON pr.principal_id = dp.grantee_principal_id
WHERE pr.name = USER_NAME();
SELECT r.name AS ROLE_NAME
FROM sys.database_role_members m
JOIN sys.database_principals r ON r.principal_id = m.role_principal_id
JOIN sys.database_principals u ON u.principal_id = m.member_principal_id
WHERE u.name = USER_NAME();
SELECT IS_SRVROLEMEMBER('sysadmin') AS IS_SYSADMIN;
GO

/* ---------------------------------------------------------------------
   S11 [V10+C8] (R2). Триггеры PLANNING/MOTCONSU и зависимости
   (CreateMotconsu НЕ вызывается). Текст триггеров можно передать целиком:
   SELECT OBJECT_DEFINITION(OBJECT_ID('dbo.<имя>'));
   --------------------------------------------------------------------- */
SELECT OBJECT_NAME(tr.parent_id) AS parent_table, tr.name AS trigger_name,
       te.type_desc AS trigger_event, tr.is_disabled, tr.is_instead_of_trigger, o.modify_date
FROM sys.triggers tr
JOIN sys.objects o ON o.object_id = tr.object_id
LEFT JOIN sys.trigger_events te ON te.object_id = tr.object_id
WHERE tr.parent_id IN (OBJECT_ID(N'dbo.PLANNING'), OBJECT_ID(N'dbo.MOTCONSU'))
ORDER BY parent_table, trigger_name, trigger_event;

SELECT OBJECT_NAME(d.referencing_id) AS source_object, d.referenced_entity_name
FROM sys.sql_expression_dependencies d
WHERE d.referencing_id = OBJECT_ID(N'dbo.CreateMotconsu')
   OR d.referencing_id IN (SELECT object_id FROM sys.triggers
                           WHERE parent_id IN (OBJECT_ID(N'dbo.PLANNING'), OBJECT_ID(N'dbo.MOTCONSU')))
   OR d.referenced_id IN (OBJECT_ID(N'dbo.PLANNING'), OBJECT_ID(N'dbo.MOTCONSU'))
ORDER BY source_object, d.referenced_entity_name;

SELECT name, type_desc FROM sys.objects WHERE OBJECTPROPERTY(object_id, 'IsEncrypted') = 1;
GO

/* ---------------------------------------------------------------------
   S12 [V11] (R3). Таблицы блокировок клиента («занято другим пользователем»)
   --------------------------------------------------------------------- */
SELECT t.name AS TABLE_NAME, SUM(p.rows) AS ROWS_CNT
FROM sys.tables t
JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0,1)
WHERE t.name LIKE '%LOCK%' OR t.name LIKE '%BUSY%'
GROUP BY t.name ORDER BY t.name;

SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME LIKE '%LOCK%' OR TABLE_NAME LIKE '%BUSY%'
ORDER BY TABLE_NAME, ORDINAL_POSITION;
GO

/* ---------------------------------------------------------------------
   S13 [V12] (этап 3). Структура таблиц программ, депозитов, счетов;
   объекты «контроля долгов»
   --------------------------------------------------------------------- */
SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME IN ('FM_ACCOUNT','FM_ACCOUNT_TRAN','FM_INVOICE','FM_BILLDET_PAY',
                     'FM_CONTR','FM_CLINK','FM_CLINK_PATIENTS','FM_PROG',
                     'FM_LOYALTY','FM_LOYALTY_MEMBER','FM_DISCOUNT','FM_DEPOSITTYPE')
ORDER BY TABLE_NAME, ORDINAL_POSITION;

SELECT o.name, o.type_desc, o.modify_date
FROM sys.objects o
WHERE o.type IN ('P','FN','TF','IF','V')
  AND (o.name LIKE '%DOLG%' OR o.name LIKE '%DEBT%' OR o.name LIKE '%DEPOS%'
       OR o.name LIKE '%ACCOUNT%' OR o.name LIKE '%NOPAID%')
ORDER BY o.type_desc, o.name;
GO

/* ---------------------------------------------------------------------
   S14 [V13+B7] (этап 3). Прикрепления и счета профилей 1 и 1587578.
   Действие прикрепления — относительно даты (начало, окончание, отмена).
   --------------------------------------------------------------------- */
SELECT fcp.PATIENTS_ID, fc.CODE AS CLINK_CODE, c.CODE AS CONTR_CODE,
       c.PAYMENT_TYPE, c.FM_ORG1_ID, c.FM_ORG2_ID,
       o1.CODE AS ORG1_CODE, o2.CODE AS ORG2_CODE,
       CONVERT(varchar(10), fcp.DATE_FROM, 120)   AS DATE_FROM,
       CONVERT(varchar(10), fcp.DATE_TO, 120)     AS DATE_TO,
       CONVERT(varchar(10), fcp.DATE_CANCEL, 120) AS DATE_CANCEL,
       ISNULL(fcp.CANCEL, 0) AS CANCEL_FLAG
FROM dbo.FM_CLINK_PATIENTS fcp
JOIN dbo.FM_CLINK fc ON fc.FM_CLINK_ID = fcp.FM_CLINK_ID
JOIN dbo.FM_CONTR c  ON c.FM_CONTR_ID = fc.FM_CONTR_ID
LEFT JOIN dbo.FM_ORG o1 ON o1.FM_ORG_ID = c.FM_ORG1_ID
LEFT JOIN dbo.FM_ORG o2 ON o2.FM_ORG_ID = c.FM_ORG2_ID
WHERE fcp.PATIENTS_ID IN (1, 1587578)
ORDER BY fcp.PATIENTS_ID, fcp.DATE_TO DESC;

SELECT b.PATIENTS_ID, COUNT(*) AS BILLS, MIN(b.BILL_DATE) AS FIRST_BILL, MAX(b.BILL_DATE) AS LAST_BILL
FROM dbo.FM_BILL b
WHERE b.PATIENTS_ID IN (1, 1587578)
GROUP BY b.PATIENTS_ID;
GO

/* ---------------------------------------------------------------------
   S15 [C9]. В какой зоне хранится MOTCONSU.CANCEL_DATE_TIME.
   Сравнить cancel_stored и cancel_plus_3h с НЕЗАВИСИМО известным
   московским временем отмены (например, по журналу клиента или по памяти
   владельца о своей отмене). DATE_CONSULTATION временем отмены не является.
   --------------------------------------------------------------------- */
SELECT TOP (20) MOTCONSU_ID, PATIENTS_ID,
       CONVERT(varchar(19), CANCEL_DATE_TIME, 120) AS cancel_stored,
       CONVERT(varchar(19), DATEADD(hour, 3, CANCEL_DATE_TIME), 120) AS cancel_plus_3h
FROM dbo.MOTCONSU
WHERE PATIENTS_ID IN (1, 1587578) AND CANCEL_DATE_TIME IS NOT NULL
ORDER BY CANCEL_DATE_TIME DESC, MOTCONSU_ID DESC;

/* То же для PLANNING.DATE_CANCEL и CREATE_DATE_TIME (по своим записям) */
SELECT TOP (20) PLANNING_ID, PATIENTS_ID,
       CONVERT(varchar(19), CREATE_DATE_TIME, 120) AS created_stored,
       CONVERT(varchar(19), KRN_CREATE_DATE, 120)  AS krn_created_stored,
       CONVERT(varchar(19), DATE_CANCEL, 120)      AS date_cancel_stored
FROM dbo.PLANNING
WHERE PATIENTS_ID IN (1, 1587578)
ORDER BY PLANNING_ID DESC;
GO

/* ---------------------------------------------------------------------
   S16 (R2, Q5; добавлен 15.10.2026 по итогам S11/S4). Триггеры PLANNING,
   которые обращаются к SMS и внешним системам: текст определений и
   объём SMS_MESSAGES. Только метаданные и агрегаты — без телефонов и текстов.
   --------------------------------------------------------------------- */
SELECT o.name AS trigger_name, OBJECT_NAME(o.parent_object_id) AS parent_table,
       OBJECT_DEFINITION(o.object_id) AS definition
FROM sys.objects o
WHERE o.type = 'TR'
  AND o.name IN (N'planning_auto_notify', N'PLANNING_EXCHANGE', N'PLANNING_MOBIMED',
                 N'tIU_PATIENTS_SYS_PHONE_AUTO_NOTIFY');

/* Что делает CreateSMS (вызывается из planning_auto_notify) */
SELECT N'CreateSMS' AS object_name, OBJECT_DEFINITION(OBJECT_ID(N'dbo.CreateSMS')) AS definition;

/* SMS_MESSAGES: последние 20 000 строк по ключу (без скана всей таблицы) */
WITH last_rows AS (
    SELECT TOP (20000) SMS_MESSAGES_ID, KRN_CREATE_DATE, SENDED_DATETIME,
           REC_TYPE, TYPE_MESSAGES, STATUS
    FROM dbo.SMS_MESSAGES
    ORDER BY SMS_MESSAGES_ID DESC
)
SELECT CONVERT(varchar(7), KRN_CREATE_DATE, 120) AS MONTH_CREATED,
       REC_TYPE, TYPE_MESSAGES, STATUS,
       SUM(CASE WHEN SENDED_DATETIME IS NOT NULL THEN 1 ELSE 0 END) AS SENT,
       COUNT(*) AS N,
       CONVERT(varchar(16), MAX(KRN_CREATE_DATE), 120) AS LAST_CREATED
FROM last_rows
GROUP BY CONVERT(varchar(7), KRN_CREATE_DATE, 120), REC_TYPE, TYPE_MESSAGES, STATUS
ORDER BY MONTH_CREATED DESC, N DESC;

/* Таблица блокировок клиента: на какие таблицы ставятся блокировки (R3) */
SELECT TABLE_NAME, COUNT(*) AS N,
       CONVERT(varchar(16), MIN(CREATION_DATE), 120) AS OLDEST,
       CONVERT(varchar(16), MAX(CREATION_DATE), 120) AS NEWEST
FROM dbo.BLOCK
GROUP BY TABLE_NAME;
GO

/* ---------------------------------------------------------------------
   S17 (R1; добавлен 15.10.2026). Как сам Медиалог считает сетку и ищет
   свободное время: тексты штатных процедур и функций расписания.
   --------------------------------------------------------------------- */
SELECT o.name AS object_name, o.type_desc, OBJECT_DEFINITION(o.object_id) AS definition
FROM sys.objects o
WHERE o.name IN (N'pl_GetMedecinGrid', N'pl_GetMedecinGridFunc_excls', N'pl_SearchVisitTime',
                 N'pl_GetPlDay', N'pl_GetSubjsGrid', N'pl_CheckNewPlanning',
                 N'pl_CheckPatRecCountInModel', N'pl_AddVisit');
GO

/* ---------------------------------------------------------------------
   S18 (этап 2; добавлен 15.10.2026 по итогам S16–S17). Штатная онлайн-запись
   Медиалога: процедура pl_AddVisit(Context) — та, через которую пишут
   Мобимед/инфоматы/веб. Нужны: её актуальная версия, процедуры отмены,
   функции сетки, «веб-пользователь», состояние подписок HL7 и SMS.
   Только метаданные, настройки и агрегаты.
   --------------------------------------------------------------------- */
/* 1. Все объекты расписания и онлайн-записи (имена) */
SELECT o.name, o.type_desc, CONVERT(varchar(10), o.modify_date, 120) AS modified
FROM sys.objects o
WHERE o.type IN ('P', 'FN', 'IF', 'TF')
  AND (o.name LIKE N'pl[_]%' OR o.name LIKE N'%Visit%' OR o.name LIKE N'%Web%'
       OR o.name LIKE N'%Planning%' OR o.name LIKE N'%Mobimed%')
ORDER BY o.name;

/* 2. Тексты: актуальная процедура записи, отмена/удаление, функции сетки */
SELECT o.name AS object_name, o.type_desc, OBJECT_DEFINITION(o.object_id) AS definition
FROM sys.objects o
WHERE o.type IN ('P', 'FN', 'IF', 'TF')
  AND (o.name IN (N'pl_AddVisitContext', N'pl_GetMedecinGridFunc', N'pl_GetMedecinGridFunc3',
                  N'pl_GetSubjDayParam', N'pl_GetSubjDayParamFunc', N'pl_GetSubjAgenda',
                  N'pl_CalcDuree', N'fnGetDateLocal')
       OR o.name LIKE N'pl[_]%Cancel%' OR o.name LIKE N'pl[_]%Del%' OR o.name LIKE N'pl[_]%Remove%'
       OR o.name LIKE N'pl[_]%Move%' OR o.name LIKE N'pl[_]%Transfer%');

/* 3. «Веб-пользователь» (по умолчанию pl_AddVisit ищет MEDECINS.NOM = 'WEB')
      и пользователь 2 — служебные учётные записи, не пациенты */
SELECT MEDECINS_ID, NOM, PRENOM
FROM dbo.MEDECINS
WHERE NOM = 'WEB' OR MEDECINS_ID = 2;

/* 4. Подписки HL7 (Мобимед) и обмен расписанием */
SELECT HL7_SUBSCRIBERS_ID, CODE, ENABLED FROM dbo.HL7_SUBSCRIBERS;
SELECT HL7_TRIGGERS_ID, CODE, ACTION_CODE, ENABLED FROM dbo.HL7_TRIGGERS
WHERE CODE LIKE N'%PLANNING%';
WITH last_ev AS (
    SELECT TOP (20000) REC_TYPE, CREATION_DATE FROM dbo.HL7_EVENTS ORDER BY HL7_EVENTS_ID DESC
)
SELECT REC_TYPE, CONVERT(varchar(7), CREATION_DATE, 120) AS MONTH_CREATED, COUNT(*) AS N,
       CONVERT(varchar(16), MAX(CREATION_DATE), 120) AS LAST_CREATED
FROM last_ev GROUP BY REC_TYPE, CONVERT(varchar(7), CREATION_DATE, 120)
ORDER BY MONTH_CREATED DESC, N DESC;
SELECT COUNT(*) AS PL_SUBJ_WITH_EXCHANGE_CODE FROM dbo.PL_SUBJ WHERE LEN(EXCHANGE_CODE) > 0;

/* 5. Настройки автоматических SMS (без текста шаблона) */
SELECT AUTO_SMS_REM_ON_RECEPTION, SEND_SMS_FOR_N_HOURS, DONT_SEND_SMS_LESS_N_HOURS,
       CASE WHEN SMS_TEMPLATE IS NULL OR SMS_TEMPLATE = '' THEN 0 ELSE 1 END AS HAS_TEMPLATE
FROM dbo.CALL_CENTER_PARAMS;

/* 6. DATE_START/DATE_END против DATE_CONS+HEURE (14 дней): можно ли брать DATE_START */
SELECT COUNT(*) AS ROWS_14D,
       SUM(CASE WHEN DATE_START IS NULL THEN 1 ELSE 0 END) AS DATE_START_NULL,
       SUM(CASE WHEN DATE_START <> DATEADD(MINUTE, (HEURE / 100) * 60 + HEURE % 100, DATE_CONS) THEN 1 ELSE 0 END) AS DATE_START_DIFFERS,
       SUM(CASE WHEN DATE_END <> DATEADD(MINUTE, DUREE, DATE_START) THEN 1 ELSE 0 END) AS DATE_END_DIFFERS
FROM dbo.PLANNING
WHERE DATE_CONS >= CONVERT(date, GETDATE())
  AND DATE_CONS <  DATEADD(day, 14, CONVERT(date, GETDATE()));
GO

/* ---------------------------------------------------------------------
   S19 (этап 2, Q4/Q15/R6; добавлен 15.10.2026 по итогам S18). Контекст сессии
   для pl_AddVisitContext, штатный расчёт свободного времени, и кто сейчас
   реально записывает пациентов через штатные процедуры (Мобимед/веб).
   --------------------------------------------------------------------- */
/* 1. Тексты: контекст сессии, свободное время, слоты, сетка */
SELECT o.name AS object_name, o.type_desc, OBJECT_DEFINITION(o.object_id) AS definition
FROM sys.objects o
WHERE o.name IN (N'set_session_params', N'get_session_param', N'get_session_paramTable',
                 N'pl_GetFreeTime', N'pl_TelemedGetAvaliableSlots', N'pl_GetMedecinGridFuncMedId',
                 N'pl_GetSubjsGrid', N'up_get_id');

/* 2. Кто создаёт записи за 90 дней: веб-пользователь 174 «WEB», пользователь 2,
      и признаки канала. Только агрегаты по месяцам. */
SELECT CONVERT(varchar(7), CREATE_DATE_TIME, 120) AS MONTH_CREATED,
       CASE WHEN KRN_CREATE_USER_ID = 174 THEN '174 WEB'
            WHEN KRN_CREATE_USER_ID = 2   THEN '2 Амбулаторные'
            ELSE 'прочие' END AS CREATOR,
       SUM(CASE WHEN ISNULL(CR_WEB, 0) = 1 THEN 1 ELSE 0 END) AS CR_WEB_1,
       SUM(CASE WHEN ISNULL(SOURCE_CODE, '') <> '' THEN 1 ELSE 0 END) AS HAS_SOURCE_CODE,
       SUM(CASE WHEN ISNULL(NOT_ACCEPTED, 0) = 1 THEN 1 ELSE 0 END) AS NOT_ACCEPTED_1,
       SUM(CASE WHEN ISNULL(WEB_USER, '') <> '' THEN 1 ELSE 0 END) AS HAS_WEB_USER,
       COUNT(*) AS N
FROM dbo.PLANNING
WHERE CREATE_DATE_TIME >= DATEADD(day, -90, CONVERT(date, GETDATE()))
  AND (STATUS = 0 OR STATUS IS NULL)
GROUP BY CONVERT(varchar(7), CREATE_DATE_TIME, 120),
         CASE WHEN KRN_CREATE_USER_ID = 174 THEN '174 WEB'
              WHEN KRN_CREATE_USER_ID = 2   THEN '2 Амбулаторные'
              ELSE 'прочие' END
ORDER BY MONTH_CREATED DESC, CREATOR;

/* 3. Есть ли у записей пользователя 2 строка PLANNING_USER_EXT (её создаёт pl_AddVisit*) */
SELECT COUNT(*) AS USER2_ROWS_30D,
       SUM(CASE WHEN ue.PLANNING_ID IS NOT NULL THEN 1 ELSE 0 END) AS WITH_USER_EXT
FROM dbo.PLANNING p
LEFT JOIN (SELECT DISTINCT PLANNING_ID FROM dbo.PLANNING_USER_EXT) ue ON ue.PLANNING_ID = p.PLANNING_ID
WHERE p.KRN_CREATE_USER_ID = 2
  AND p.CREATE_DATE_TIME >= DATEADD(day, -30, CONVERT(date, GETDATE()));

/* 4. Очередь HL7: какие колонки есть (доставляются ли события) */
SELECT c.name AS column_name, t.name AS data_type
FROM sys.columns c JOIN sys.types t ON t.user_type_id = c.user_type_id
WHERE c.object_id = OBJECT_ID(N'dbo.HL7_EVENTS')
ORDER BY c.column_id;
GO

/* Блоки сверки ChatGPT, не включённые сюда:
   C4 (хранилища протоколов DATA*) — не нужен: клинические данные не входят в ЛК (решение D7);
   C7 (охват XE-событий) — заменён собственной трассировкой в 04_RUNBOOK_BOOKING_CAPTURE.md. */
