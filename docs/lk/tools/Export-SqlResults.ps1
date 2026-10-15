<#
.SYNOPSIS
  Выполняет проверочный SQL-скрипт проекта ЛК (только чтение) и сохраняет каждый
  результат в CSV, общий журнал и при возможности одну книгу Excel; всё упаковывает в zip.

.DESCRIPTION
  - Скрипт делится на пакеты по строкам GO. Метка пакета берётся из заголовка блока
    («S3 [V4] ...» -> S03). Каждый результирующий набор -> S03_1.csv, S03_2.csv ...
  - Защита «только чтение»: пакет, где вне комментариев и строковых литералов есть
    INSERT/UPDATE/DELETE/MERGE/CREATE/ALTER/DROP/TRUNCATE/EXEC/GRANT/DENY/REVOKE/BACKUP/
    RESTORE/DBCC/KILL/SHUTDOWN/RECONFIGURE/INTO, не выполняется (пометка
    SKIPPED в журнале). Такие скрипты (05_SQL_SERVICE_LOGINS, runbook 04) — только вручную в SSMS.
  - Тайм-аут пакета — 60 с (правило из 03_VERIFICATION_SQL.sql). Ошибка пакета не
    останавливает остальные; она пишется в журнал.
  - CSV: UTF-8 с BOM, разделитель «;» — открываются в русском Excel двойным щелчком.
  - Пароль не сохраняется: Windows-вход по умолчанию, SQL-вход — через окно ввода.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\Export-SqlResults.ps1 -SqlFile ..\03_VERIFICATION_SQL.sql
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\Export-SqlResults.ps1 -SqlFile ..\03_VERIFICATION_SQL.sql -Only S3,S9 -SqlLogin
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)] [string]   $SqlFile,
  [string]   $Server         = '192.168.2.229',
  [string]   $Database       = 'Medialog',
  [switch]   $SqlLogin,                       # SQL-вход вместо Windows-входа
  [string[]] $Only,                           # напр. -Only S3,S9
  [int]      $TimeoutSec     = 60,
  [string]   $OutRoot        = '',          # по умолчанию: <папка скрипта>\results
  [switch]   $NoXlsx
)

$ErrorActionPreference = 'Stop'

# powershell.exe -File передаёт «-Only S16,S17» одной строкой — разбираем сами.
if ($Only) {
  $Only = @($Only | ForEach-Object { $_ -split '[,;\s]+' } | Where-Object { $_ } |
            ForEach-Object { $_.Trim().ToUpper() })
}
Add-Type -AssemblyName System.Data

# ---------- подготовка ----------
# Windows PowerShell 5.1 при запуске через -File оставляет $PSScriptRoot пустым в param(),
# поэтому папку результатов вычисляем здесь.
if (-not $OutRoot) {
  $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
  $OutRoot = Join-Path $scriptDir 'results'
}
$sqlPath = (Resolve-Path $SqlFile).Path
$stamp   = Get-Date -Format 'yyyy-MM-dd_HHmm'
$base    = [IO.Path]::GetFileNameWithoutExtension($sqlPath)
$outDir  = Join-Path $OutRoot "$base`_$stamp"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$logPath = Join-Path $outDir '_log.txt'
$utf8Bom = New-Object System.Text.UTF8Encoding($true)

function Write-Log([string]$msg) {
  $line = '{0:HH:mm:ss}  {1}' -f (Get-Date), $msg
  Write-Host $line
  [IO.File]::AppendAllText($logPath, $line + [Environment]::NewLine, $utf8Bom)
}

$csb = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
$csb['Data Source']        = $Server
$csb['Initial Catalog']    = $Database
$csb['Application Name']   = 'lk-verification-export'   # виден в мониторинге SQL Server
$csb['ApplicationIntent']  = 'ReadOnly'
$csb['Connect Timeout']    = 30
if ($SqlLogin) {
  $cred = Get-Credential -Message "SQL-вход к $Server"
  $csb['User ID']  = $cred.UserName
  $csb['Password'] = $cred.GetNetworkCredential().Password
} else {
  $csb['Integrated Security'] = $true
}

# ---------- разбор скрипта ----------
$text    = Get-Content -LiteralPath $sqlPath -Raw -Encoding UTF8
$batches = [regex]::Split($text, '(?im)^[ \t]*GO[ \t]*(?:--[^\r\n]*)?\r?$')

function Get-CodeOnly([string]$s) {
  $s = [regex]::Replace($s, '/\*[\s\S]*?\*/', ' ')   # блочные комментарии
  $s = [regex]::Replace($s, '--[^\r\n]*', ' ')       # строчные комментарии
  $s = [regex]::Replace($s, "N?'(?:[^']|'')*'", "''")  # строковые литералы
  return $s
}
$forbidden = '(?i)\b(INSERT|UPDATE|DELETE|MERGE|CREATE|ALTER|DROP|TRUNCATE|EXEC|EXECUTE|GRANT|DENY|REVOKE|BACKUP|RESTORE|DBCC|KILL|SHUTDOWN|RECONFIGURE|sp_executesql|INTO)\b'

function Format-Cell($v) {
  if ($v -is [DBNull] -or $null -eq $v) { return '' }
  if ($v -is [datetime])  { return $v.ToString('yyyy-MM-dd HH:mm:ss.fff') }
  if ($v -is [byte[]])    { return '0x' + (($v | ForEach-Object { $_.ToString('X2') }) -join '') }
  if ($v -is [decimal] -or $v -is [double] -or $v -is [single]) {
    return $v.ToString([Globalization.CultureInfo]::GetCultureInfo('ru-RU'))   # запятая — для Excel
  }
  return [string]$v
}
function Quote([string]$s) { '"' + $s.Replace('"', '""') + '"' }

function Save-Csv([System.Data.DataTable]$t, [string]$path) {
  $sw = New-Object IO.StreamWriter($path, $false, $utf8Bom)
  try {
    $sw.WriteLine((($t.Columns | ForEach-Object { Quote $_.ColumnName }) -join ';'))
    foreach ($r in $t.Rows) {
      $sw.WriteLine((($r.ItemArray | ForEach-Object { Quote (Format-Cell $_) }) -join ';'))
    }
  } finally { $sw.Close() }
}

# ---------- выполнение ----------
$conn = New-Object System.Data.SqlClient.SqlConnection($csb.ConnectionString)
$messages = New-Object System.Collections.Generic.List[string]
$conn.add_InfoMessage({ param($s, $e) $messages.Add($e.Message) })
$conn.FireInfoMessageEventOnUserErrors = $false
for ($try = 1; $try -le 3; $try++) {
  try { $conn.Open(); break }
  catch {
    if ($try -eq 3) { throw }
    Write-Host ("Подключение не удалось (попытка {0} из 3): {1}" -f $try, $_.Exception.GetBaseException().Message)
    Start-Sleep -Seconds 5
  }
}
Write-Log "Подключено: $Server / $Database, вход: $(if ($SqlLogin) {'SQL'} else {'Windows'}), файл: $base"

$summary = New-Object System.Collections.Generic.List[object]
$tables  = New-Object System.Collections.Generic.List[object]   # для xlsx
$idx = 0
foreach ($b in $batches) {
  $code = Get-CodeOnly $b
  if ($code.Trim() -eq '') { continue }                         # пакет из одних комментариев
  $idx++
  $m = [regex]::Match($b, '(?m)^\s*S(\d+)\s*[\[\(]')
  $label = if ($m.Success) { 'S{0:D2}' -f [int]$m.Groups[1].Value } else { 'B{0:D2}' -f $idx }
  $short = if ($m.Success) { 'S' + [int]$m.Groups[1].Value } else { $label }

  if ($Only -and -not ($Only -contains $short -or $Only -contains $label)) {
    # служебные пакеты без метки (SET NOCOUNT ON) выполняем всегда
    if ($m.Success) { continue }
  }

  $hit = [regex]::Match($code, $forbidden)
  if ($hit.Success) {
    Write-Log "$label  SKIPPED: найдено «$($hit.Value)» — выполнять только вручную в SSMS"
    $summary.Add([pscustomobject]@{ Block=$label; Status='SKIPPED'; ResultSets=0; Rows=0; Seconds=0; Note="keyword $($hit.Value)" })
    continue
  }

  $messages.Clear()
  $cmd = $conn.CreateCommand()
  $cmd.CommandText    = $b
  $cmd.CommandTimeout = $TimeoutSec
  $ds = New-Object System.Data.DataSet
  $sw = [Diagnostics.Stopwatch]::StartNew()
  try {
    (New-Object System.Data.SqlClient.SqlDataAdapter($cmd)).Fill($ds) | Out-Null
    $sw.Stop()
    $n = 0; $rows = 0
    foreach ($t in $ds.Tables) {
      $n++; $rows += $t.Rows.Count
      $name = "{0}_{1}" -f $label, $n
      Save-Csv $t (Join-Path $outDir "$name.csv")
      $tables.Add([pscustomobject]@{ Name = $name; Table = $t })
    }
    $note = ($messages -join ' | ')
    Write-Log ("{0}  OK: наборов {1}, строк {2}, {3:N1} c{4}" -f $label, $n, $rows, $sw.Elapsed.TotalSeconds, $(if ($note) { "; сообщения: $note" } else { '' }))
    $summary.Add([pscustomobject]@{ Block=$label; Status='OK'; ResultSets=$n; Rows=$rows; Seconds=[math]::Round($sw.Elapsed.TotalSeconds,1); Note=$note })
  } catch {
    $sw.Stop()
    $err = $_.Exception.GetBaseException().Message -replace '\s+', ' '
    Write-Log "$label  ERROR ($([math]::Round($sw.Elapsed.TotalSeconds,1)) c): $err"
    $summary.Add([pscustomobject]@{ Block=$label; Status='ERROR'; ResultSets=0; Rows=0; Seconds=[math]::Round($sw.Elapsed.TotalSeconds,1); Note=$err })
  }
}
$conn.Close()
if ($Only -and -not ($summary | Where-Object { $_.Block -match '^S\d' })) {
  Write-Log ("ВНИМАНИЕ: ни один блок не совпал с -Only {0}" -f ($Only -join ','))
}

# ---------- сводка ----------
$sumTable = New-Object System.Data.DataTable
'Block','Status','ResultSets','Rows','Seconds','Note' | ForEach-Object { [void]$sumTable.Columns.Add($_) }
foreach ($s in $summary) { [void]$sumTable.Rows.Add($s.Block,$s.Status,$s.ResultSets,$s.Rows,$s.Seconds,$s.Note) }
Save-Csv $sumTable (Join-Path $outDir '_summary.csv')

# ---------- Excel (по желанию) ----------
if (-not $NoXlsx -and $tables.Count -gt 0) {
  $xlsx = Join-Path $outDir "$base`_$stamp.xlsx"
  $all  = @([pscustomobject]@{ Name = '_summary'; Table = $sumTable }) + $tables
  if (Get-Module -ListAvailable -Name ImportExcel) {
    Import-Module ImportExcel
    foreach ($x in $all) {
      $cols = $x.Table.Columns | ForEach-Object { $_.ColumnName }
      $x.Table.Rows | Select-Object -Property $cols |
        Export-Excel -Path $xlsx -WorksheetName $x.Name -AutoSize -FreezeTopRow -BoldTopRow
    }
    Write-Log "Excel (ImportExcel): $xlsx"
  } else {
    try {
      $excel = New-Object -ComObject Excel.Application
      $excel.Visible = $false; $excel.DisplayAlerts = $false
      $wb = $excel.Workbooks.Add()
      while ($wb.Worksheets.Count -gt 1) { $wb.Worksheets.Item($wb.Worksheets.Count).Delete() }
      $first = $true
      foreach ($x in $all) {
        $ws = if ($first) { $wb.Worksheets.Item(1) } else { $wb.Worksheets.Add([Type]::Missing, $wb.Worksheets.Item($wb.Worksheets.Count)) }
        $first = $false
        $ws.Name = $x.Name
        $t = $x.Table; $rc = $t.Rows.Count + 1; $cc = [math]::Max($t.Columns.Count, 1)
        $arr = New-Object 'object[,]' $rc, $cc
        for ($c = 0; $c -lt $t.Columns.Count; $c++) { $arr[0, $c] = $t.Columns[$c].ColumnName }
        for ($r = 0; $r -lt $t.Rows.Count; $r++) {
          for ($c = 0; $c -lt $t.Columns.Count; $c++) {
            $v = $t.Rows[$r][$c]
            $arr[($r + 1), $c] = if ($v -is [int] -or $v -is [long] -or $v -is [int16] -or $v -is [byte] -or $v -is [decimal] -or $v -is [double]) { [double]$v } else { "'" + (Format-Cell $v) }
          }
        }
        $ws.Range($ws.Cells.Item(1,1), $ws.Cells.Item($rc,$cc)).Value2 = $arr
        $ws.Rows.Item(1).Font.Bold = $true
        [void]$ws.UsedRange.Columns.AutoFit()
      }
      $wb.SaveAs($xlsx, 51)   # 51 = xlsx
      $wb.Close($false); $excel.Quit()
      [void][Runtime.InteropServices.Marshal]::ReleaseComObject($excel)
      Write-Log "Excel (COM): $xlsx"
    } catch {
      Write-Log "Excel не создан (нет модуля ImportExcel и Excel): CSV достаточно."
    }
  }
}

# ---------- архив для передачи ----------
$zip = "$outDir.zip"
Compress-Archive -Path (Join-Path $outDir '*') -DestinationPath $zip -Force
Write-Log "Готово. Передать файл: $zip"
