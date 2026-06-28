[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$scriptVersion = "0.5.1"

param([string]$expectedVersion = "")
if ($expectedVersion -ne "" -and $expectedVersion -ne $scriptVersion) {
    Write-Host "ОШИБКА: Версия программы не совпадает с версией в EMS.bat" -ForegroundColor Red
    Write-Host "Требуется версия: $expectedVersion, текущая: $scriptVersion" -ForegroundColor Red
    Write-Host "Скачайте актуальную версию или обновите оба файла." -ForegroundColor Yellow
    Pause
    exit 1
}

$Host.UI.RawUI.WindowTitle = "EMS Sorter v$scriptVersion"

$ConfigFile = Join-Path $PSScriptRoot "config.ini"
$StatsFile  = Join-Path $PSScriptRoot "stats.ini"
$LogFile    = Join-Path $PSScriptRoot "session.log"
$ProcessedDb = Join-Path $PSScriptRoot "processed_hashes.txt"

# Единый порядок категорий (используется во всех меню)
$categoryOrder = @(
    "PMP_CITY",
    "PMP_SUBURB",
    "TABLETS_ELSH",
    "TABLETS_PBSS",
    "NIGHT_CITY",
    "NIGHT_SUBURB",
    "VAX_ELSH",
    "VAX_PBSS",
    "CERT_ELSH",
    "CERT_PBSS",
    "CERT_ELSH_NIGHT",
    "CERT_PBSS_NIGHT"
)

$weights = @{
    "PMP_CITY"          = 3
    "PMP_SUBURB"        = 5
    "TABLETS_ELSH"      = 1
    "TABLETS_PBSS"      = 2
    "NIGHT_CITY"        = 6
    "NIGHT_SUBURB"      = 8
    "VAX_ELSH"          = 3
    "VAX_PBSS"          = 5
    "CERT_ELSH"         = 3
    "CERT_PBSS"         = 5
    "CERT_ELSH_NIGHT"   = 6
    "CERT_PBSS_NIGHT"   = 9
}

# Имена для отображения
$categoryNames = @{
    "PMP_CITY"          = "ПМП день город"
    "PMP_SUBURB"        = "ПМП день пригород"
    "TABLETS_ELSH"      = "Таблетки ELSH"
    "TABLETS_PBSS"      = "Таблетки PBSS"
    "NIGHT_CITY"        = "ПМП ночь город"
    "NIGHT_SUBURB"      = "ПМП ночь пригород"
    "VAX_ELSH"          = "Вакцины ELSH"
    "VAX_PBSS"          = "Вакцины PBSS"
    "CERT_ELSH"         = "Мед.справки ELSH день"
    "CERT_PBSS"         = "Мед.справки PBSS день"
    "CERT_ELSH_NIGHT"   = "Мед.справки ELSH ночь"
    "CERT_PBSS_NIGHT"   = "Мед.справки PBSS ночь"
}

function Initialize-Files {
    if (-not (Test-Path $ConfigFile)) {
        $defaultConfig = @"
FIRST_RUN=1
SCREENSHOT_PATH=
"@
        foreach ($key in $categoryOrder) {
            $defaultConfig += "`n$key="
        }
        $defaultConfig += @"
SECOND_WEEK_PATH=
BRIEFING_PATH=
"@
        Set-Content -Path $ConfigFile -Value $defaultConfig -Encoding UTF8
    }

    if (-not (Test-Path $StatsFile)) {
        $defaultStats = ""
        foreach ($key in $categoryOrder) {
            $defaultStats += "${key}_COUNT=0`n"
        }
        Set-Content -Path $StatsFile -Value $defaultStats -Encoding UTF8
    }
}

function Load-Ini {
    param($Path)
    $data = @{}
    if (-not (Test-Path $Path)) { return $data }
    foreach ($line in Get-Content $Path -Encoding UTF8) {
        if ($line -match '^([^=]+)=(.*)$') {
            $data[$Matches[1].Trim()] = $Matches[2].Trim()
        }
    }
    return $data
}

function Save-Ini {
    param($Path, $Data)
    $lines = @()
    foreach ($key in $Data.Keys) {
        $lines += "$key=$($Data[$key])"
    }
    $lines | Set-Content -Path $Path -Encoding UTF8
}

function Get-ProcessedHashes {
    $hashes = @{}
    if (Test-Path $ProcessedDb) {
        foreach ($line in Get-Content $ProcessedDb -ErrorAction SilentlyContinue) {
            if (-not [string]::IsNullOrWhiteSpace($line)) { $hashes[$line.Trim()] = $true }
        }
    }
    return $hashes
}

function Save-ProcessedHash {
    param($Hash)
    Add-Content -Path $ProcessedDb -Value $Hash -Encoding UTF8
}

function Write-Log {
    param($Text)
    $time = Get-Date -Format "dd.MM.yyyy HH:mm:ss"
    Add-Content -Path $LogFile -Value "[$time] $Text" -Encoding UTF8
}

function Find-NvidiaFolder {
    $candidates = @(
        "$env:USERPROFILE\Videos",
        "$env:USERPROFILE\Pictures",
        "$env:LOCALAPPDATA"
    )
    foreach ($root in $candidates) {
        if (-not (Test-Path $root)) { continue }
        try {
            $found = Get-ChildItem -Path $root -Directory -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match "NVIDIA|Screenshots|Desktop" } |
                Select-Object -First 1
            if ($found) { return $found.FullName }
        } catch { }
    }
    return $null
}

function Show-Banner {
    Clear-Host
    Write-Host ""
    Write-Host "========================================================="
    Write-Host "                  EMS SORTER v$scriptVersion"
    Write-Host "                    MAJESTIC RP"
    Write-Host "========================================================="
    Write-Host ""
}

function FirstRunWizard {
    Show-Banner
    Write-Host "ПЕРВЫЙ ЗАПУСК" -ForegroundColor Cyan
    Write-Host ""
    $cfg = Load-Ini $ConfigFile

    $auto = Find-NvidiaFolder
    if ($auto) {
        Write-Host "Найдена папка скриншотов: $auto"
        $ans = Read-Host "Использовать её? (Y/N)"
        if ($ans -eq "Y") {
            $cfg["SCREENSHOT_PATH"] = $auto
        } else {
            Write-Host "Введите путь к папке со скриншотами вручную:"
            $cfg["SCREENSHOT_PATH"] = Read-Host
        }
    } else {
        Write-Host "Введите путь к папке со скриншотами:"
        $cfg["SCREENSHOT_PATH"] = Read-Host
    }

    Write-Host "`nНастройка папок назначения (можно оставить пустыми или указать 0, если категория не используется):"
    foreach ($key in $categoryOrder) {
        Write-Host "$($categoryNames[$key]) :"
        $cfg[$key] = Read-Host
    }

    Write-Host "`nНастройка папки 'Вторая неделя' (куда будут перемещаться файлы при R2):"
    $cfg["SECOND_WEEK_PATH"] = Read-Host "Введите путь (0 - отключить функцию)"

    Write-Host "`nНастройка папки для Брифингов (внутри будут создаваться папки с датой):"
    $cfg["BRIEFING_PATH"] = Read-Host "Введите путь (0 - отключить функцию)"

    $cfg["FIRST_RUN"] = "0"
    Save-Ini $ConfigFile $cfg
    Write-Host "`nНастройка завершена. Нажмите любую клавишу..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

# --- Автоматическая синхронизация (только добавление) ---
function AutoSync-StatsWithFolders {
    $cfg = Load-Ini $ConfigFile
    $stats = Load-Ini $StatsFile
    $changed = $false

    foreach ($key in $categoryOrder) {
        $folder = $cfg[$key]
        if ([string]::IsNullOrWhiteSpace($folder) -or $folder -eq "0") { continue }
        if (-not (Test-Path $folder)) { continue }
        $realCount = (Get-ChildItem -Path $folder -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match "^\.(png|jpg|jpeg)$" }).Count
        $storedCount = [int]$stats["${key}_COUNT"]
        if ($realCount -gt $storedCount) {
            $stats["${key}_COUNT"] = $realCount
            $changed = $true
        }
    }
    if ($changed) {
        Save-Ini $StatsFile $stats
        Write-Log "Автосинхронизация: обновлены счётчики (только добавление)"
    }
}

# --- Полная принудительная синхронизация (выравнивание) ---
function FullSync-StatsWithFolders {
    Write-Host "`n🔄 Принудительная синхронизация статистики с папками..." -ForegroundColor Cyan
    $cfg = Load-Ini $ConfigFile
    $stats = Load-Ini $StatsFile
    $changed = $false

    foreach ($key in $categoryOrder) {
        $folder = $cfg[$key]
        if ([string]::IsNullOrWhiteSpace($folder) -or $folder -eq "0") {
            $realCount = 0
        } else {
            if (-not (Test-Path $folder)) {
                $realCount = 0
            } else {
                $realCount = (Get-ChildItem -Path $folder -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match "^\.(png|jpg|jpeg)$" }).Count
            }
        }
        $storedCount = [int]$stats["${key}_COUNT"]
        if ($realCount -ne $storedCount) {
            Write-Host "  ${key}: $storedCount → $realCount" -ForegroundColor Yellow
            $stats["${key}_COUNT"] = $realCount
            $changed = $true
        }
    }
    if ($changed) {
        Save-Ini $StatsFile $stats
        Write-Host "`n✅ Статистика полностью синхронизирована с папками." -ForegroundColor Green
        Write-Log "Ручная синхронизация: счётчики приведены к реальному количеству файлов"
    } else {
        Write-Host "`n✅ Статистика уже актуальна." -ForegroundColor Green
    }
    Start-Sleep -Seconds 2
}

function Get-Stats {
    $stats = Load-Ini $StatsFile
    $totalCount = 0
    $totalScore = 0
    $details = @{}
    foreach ($key in $categoryOrder) {
        $cnt = [int]$stats["${key}_COUNT"]
        $score = $cnt * $weights[$key]
        $totalCount += $cnt
        $totalScore += $score
        $details[$key] = @{ Count = $cnt; Score = $score }
    }
    return @{ TotalCount = $totalCount; TotalScore = $totalScore; Details = $details }
}

function Add-Score {
    param($CategoryKey, $Count = 1)
    $stats = Load-Ini $StatsFile
    $countKey = "${CategoryKey}_COUNT"
    $currentCount = [int]$stats[$countKey]
    $stats[$countKey] = $currentCount + $Count
    Save-Ini $StatsFile $stats
    Write-Log "Добавлено $Count скриншотов в ${CategoryKey} (теперь: $($currentCount+$Count))"
}

function Show-Stats {
    AutoSync-StatsWithFolders
    $data = Get-Stats
    Show-Banner
    Write-Host "СТАТИСТИКА (накопленные баллы и количество скриншотов)" -ForegroundColor Cyan
    Write-Host ""
    foreach ($key in $categoryOrder) {
        $cnt = $data.Details[$key].Count
        $scr = $data.Details[$key].Score
        Write-Host ("{0,-28} : {1,3} шт. → {2,5} баллов" -f $categoryNames[$key], $cnt, $scr)
    }
    Write-Host ""
    Write-Host ("══════════════════════════════════════════════════════════" -f "")
    Write-Host ("ВСЕГО СКРИНОВ : {0}" -f $data.TotalCount) -ForegroundColor Yellow
    Write-Host ("ИТОГО БАЛЛОВ  : {0}" -f $data.TotalScore) -ForegroundColor Green
    Write-Host ""
    Pause
}

function Show-Config {
    $cfg = Load-Ini $ConfigFile
    Show-Banner
    Write-Host "ТЕКУЩИЕ НАСТРОЙКИ"
    Write-Host ""
    Write-Host "Папка скриншотов (источник)    : $($cfg['SCREENSHOT_PATH'])"
    Write-Host "Папка 'Вторая неделя'          : $($cfg['SECOND_WEEK_PATH'])"
    Write-Host "Папка для Брифингов            : $($cfg['BRIEFING_PATH'])"
    Write-Host ""
    foreach ($key in $categoryOrder) {
        Write-Host ("{0,-28} : {1}" -f $categoryNames[$key], $cfg[$key])
    }
    Write-Host ""
    Pause
}

function Configure-Paths {
    $cfg = Load-Ini $ConfigFile
    while ($true) {
        Show-Banner
        Write-Host "НАСТРОЙКА ПУТЕЙ"
        Write-Host ""
        Write-Host "[1]  Папка скриншотов (источник)"
        $i = 2
        foreach ($key in $categoryOrder) {
            Write-Host ("[$i]  {0}" -f $categoryNames[$key])
            $i++
        }
        $baseIndex = $i
        Write-Host "[$baseIndex] Папка 'Вторая неделя'"
        $baseIndex++
        Write-Host "[$baseIndex] Папка для Брифингов"
        Write-Host ""
        Write-Host "[0] Назад"
        $choice = Read-Host "Выберите пункт"
        if ($choice -eq "0") { break }
        $choiceNum = [int]$choice
        if ($choiceNum -eq 1) {
            $path = Read-Host "Введите путь (0 - отключить)"
            $cfg["SCREENSHOT_PATH"] = $path
        } elseif ($choiceNum -ge 2 -and $choiceNum -le ($categoryOrder.Count + 1)) {
            $idx = $choiceNum - 2
            $key = $categoryOrder[$idx]
            $path = Read-Host "Введите путь (0 - отключить)"
            $cfg[$key] = $path
        } elseif ($choiceNum -eq $baseIndex) {
            $path = Read-Host "Введите путь (0 - отключить)"
            $cfg["SECOND_WEEK_PATH"] = $path
        } elseif ($choiceNum -eq ($baseIndex + 1)) {
            $path = Read-Host "Введите путь (0 - отключить)"
            $cfg["BRIEFING_PATH"] = $path
        } else {
            Write-Host "Неверный выбор" -ForegroundColor Red
            Start-Sleep -Seconds 1
            continue
        }
        Save-Ini $ConfigFile $cfg
    }
}

function Reset-ScoresOnly {
    Write-Host ""
    Write-Host "⚠️  Вы уверены, что хотите ОБНУЛИТЬ все накопленные баллы и счётчики?" -ForegroundColor Yellow
    Write-Host "Скриншоты в папках НЕ будут удалены." -ForegroundColor Yellow
    $confirm = Read-Host "(Y/N)"
    if ($confirm -ne "Y") { return $false }
    $stats = Load-Ini $StatsFile
    foreach ($key in $categoryOrder) {
        $stats["${key}_COUNT"] = "0"
    }
    Save-Ini $StatsFile $stats
    Write-Host "✅ Баллы и счётчики сброшены." -ForegroundColor Green
    Write-Log "Ручной сброс баллов и счётчиков"
    return $true
}

# --- R2: Переместить все файлы в папку "Вторая неделя" и обнулить баллы ---
function MoveToSecondWeek {
    $cfg = Load-Ini $ConfigFile
    $secondWeekPath = $cfg["SECOND_WEEK_PATH"]
    if ([string]::IsNullOrWhiteSpace($secondWeekPath) -or $secondWeekPath -eq "0") {
        Write-Host "`n❌ Папка 'Вторая неделя' не настроена. Сначала настройте путь." -ForegroundColor Red
        Pause
        return
    }

    if (-not (Test-Path $secondWeekPath)) {
        New-Item -ItemType Directory -Path $secondWeekPath -Force | Out-Null
    }

    $dateFolder = Get-Date -Format "yyyy-MM-dd_HH-mm"
    $targetRoot = Join-Path $secondWeekPath $dateFolder
    New-Item -ItemType Directory -Path $targetRoot -Force | Out-Null

    Write-Host "`n📦 Перемещение всех скриншотов в '$targetRoot'..." -ForegroundColor Cyan

    $totalMoved = 0
    foreach ($key in $categoryOrder) {
        $folder = $cfg[$key]
        if ([string]::IsNullOrWhiteSpace($folder) -or $folder -eq "0") { continue }
        if (-not (Test-Path $folder)) { continue }

        $files = Get-ChildItem -Path $folder -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match "^\.(png|jpg|jpeg)$" }
        if ($files.Count -eq 0) { continue }

        $catFolder = Join-Path $targetRoot $categoryNames[$key]
        New-Item -ItemType Directory -Path $catFolder -Force | Out-Null

        foreach ($file in $files) {
            try {
                Move-Item -Path $file.FullName -Destination $catFolder -Force -ErrorAction Stop
                $totalMoved++
                Write-Host "  Перемещён: $($file.Name) → $($categoryNames[$key])" -ForegroundColor Green
            } catch {
                Write-Host "  ❌ Ошибка перемещения $($file.Name)" -ForegroundColor Red
                Write-Log "Ошибка перемещения $($file.FullName) во вторую неделю"
            }
        }
    }

    Write-Host "`n✅ Перемещено файлов: $totalMoved" -ForegroundColor Green
    Write-Log "R2: перемещено $totalMoved файлов в $targetRoot"

    Write-Host "`nОбнуление счётчиков..." -ForegroundColor Yellow
    Reset-ScoresOnly | Out-Null
    FullSync-StatsWithFolders

    Write-Host "`nГотово. Все файлы перемещены, баллы обнулены." -ForegroundColor Green
    Pause
}

# --- Режим Брифинг ---
function Start-Briefing {
    $cfg = Load-Ini $ConfigFile
    $briefingRoot = $cfg["BRIEFING_PATH"]
    if ([string]::IsNullOrWhiteSpace($briefingRoot) -or $briefingRoot -eq "0") {
        Write-Host "`n❌ Папка для Брифингов не настроена. Сначала настройте путь." -ForegroundColor Red
        Pause
        return
    }

    if (-not (Test-Path $briefingRoot)) {
        New-Item -ItemType Directory -Path $briefingRoot -Force | Out-Null
    }

    # Создаём папку брифинга с датой и временем
    $dateStr = Get-Date -Format "dd.MM.yyyy-HH.mm"
    $briefingFolder = "Брифинг-$dateStr"
    $briefingPath = Join-Path $briefingRoot $briefingFolder
    New-Item -ItemType Directory -Path $briefingPath -Force | Out-Null

    Write-Host "`n📂 Создан Брифинг: $briefingPath" -ForegroundColor Cyan

    # Создаём внутри папки брифинга подпапки для всех категорий
    foreach ($key in $categoryOrder) {
        $catFolder = Join-Path $briefingPath $categoryNames[$key]
        New-Item -ItemType Directory -Path $catFolder -Force | Out-Null
    }

    # Цикл выбора категории внутри брифинга
    while ($true) {
        Show-Banner
        Write-Host "БРИФИНГ: $briefingFolder" -ForegroundColor Cyan
        Write-Host "Выберите категорию для работы (или M для возврата в главное меню):" -ForegroundColor Yellow
        Write-Host ""
        $i = 1
        foreach ($key in $categoryOrder) {
            Write-Host "[$i] $($categoryNames[$key])"
            $i++
        }
        Write-Host ""
        Write-Host "[0] Выйти из брифинга в главное меню"
        Write-Host ""
        $choice = Read-Host "Выберите пункт"
        if ($choice -eq "0") {
            Write-Host "Выход из брифинга..." -ForegroundColor Yellow
            return
        }
        $idx = [int]$choice - 1
        if ($idx -lt 0 -or $idx -ge $categoryOrder.Count) {
            Write-Host "Неверный выбор" -ForegroundColor Red
            Pause
            continue
        }
        $selectedKey = $categoryOrder[$idx]
        $targetFolder = Join-Path $briefingPath $categoryNames[$selectedKey]

        Write-Host "`nЗапуск режима Брифинг для категории $($categoryNames[$selectedKey])" -ForegroundColor Cyan
        Write-Host "Целевая папка: $targetFolder" -ForegroundColor Gray

        # Запускаем ватчер в режиме брифинга
        Start-Watcher -TargetFolder $targetFolder -ModeName "Брифинг: $($categoryNames[$selectedKey])" -CategoryKey $selectedKey -BriefingMode $true

        # После выхода из ватчера проверяем причину
        if ($global:LastExitReason -eq "MainMenu") {
            Write-Host "Возврат в главное меню..." -ForegroundColor Yellow
            return
        }
        # Если BriefingMenu – просто продолжаем цикл выбора категорий
        # Если что-то другое – тоже продолжаем
    }
}

# --- Основная функция слежения (общая для всех режимов) ---
function Start-Watcher {
    param(
        $TargetFolder,
        $ModeName,
        $CategoryKey,
        [switch]$BriefingMode = $false
    )

    $cfg = Load-Ini $ConfigFile
    $SourceFolder = $cfg["SCREENSHOT_PATH"]

    if (-not (Test-Path $SourceFolder)) {
        Write-Host "`n❌ Папка скриншотов не найдена: $SourceFolder" -ForegroundColor Red
        Pause
        return
    }

    if ([string]::IsNullOrWhiteSpace($TargetFolder) -or $TargetFolder -eq "0") {
        Write-Host "`n❌ Папка назначения не настроена для этой категории." -ForegroundColor Red
        Pause
        return
    }

    if (-not (Test-Path $TargetFolder)) {
        New-Item -ItemType Directory -Path $TargetFolder -Force | Out-Null
    }

    $processed = @{}
    Get-ChildItem -Path $SourceFolder -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { -not $_.FullName.StartsWith($TargetFolder,[System.StringComparison]::OrdinalIgnoreCase) } |
        ForEach-Object { $processed[$_.FullName] = $true }

    Show-Banner
    Write-Host "Режим: $ModeName"
    Write-Host ""
    Write-Host "✅ Отслеживание запущено (проверка каждую секунду)"
    Write-Host "📂 Источник: $SourceFolder"
    Write-Host "📂 Назначение: $TargetFolder"
    Write-Host "🗑️  Исходные файлы будут УДАЛЕНЫ после перемещения"
    Write-Host ""
    Write-Host "🟢 Ожидание новых скриншотов..."
    if ($BriefingMode) {
        Write-Host "Для выхода в главное меню нажмите B, для возврата в меню брифинга нажмите M"
    } else {
        Write-Host "Для выхода в главное меню нажмите B"
    }
    Write-Host ""

    $sessionCount = 0
    $processedHashes = Get-ProcessedHashes
    $stopLoop = $false

    $handler = [ConsoleCancelEventHandler]{
        param($sender, $e)
        $e.Cancel = $true
        Write-Host "`n`n" -NoNewline
        Write-Host "❓ Завершить работу? (Y/N)" -ForegroundColor Cyan
        $ans = Read-Host
        if ($ans -eq "Y") {
            $global:LastExitReason = "ExitProgram"
            $stopLoop = $true
        } else {
            Write-Host "❓ Выйти в главное меню? (Y/N)" -ForegroundColor Cyan
            $ans2 = Read-Host
            if ($ans2 -eq "Y") {
                $global:LastExitReason = "MainMenu"
                $stopLoop = $true
            } else {
                Write-Host "▶️ Продолжаем отслеживание..." -ForegroundColor Green
            }
        }
    }
    try { [Console]::CancelKeyPress.Add($handler) } catch {}

    while (-not $stopLoop) {
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq 'B' -or $key.KeyChar -eq 'B' -or $key.KeyChar -eq 'b' -or $key.KeyChar -eq 'И') {
                Write-Host "`n" -NoNewline
                Write-Host "❓ Выйти в главное меню? (Y/N)" -ForegroundColor Cyan
                $ans = Read-Host
                if ($ans -eq "Y") {
                    $global:LastExitReason = "MainMenu"
                    $stopLoop = $true
                } else {
                    Write-Host "▶️ Продолжаем отслеживание..." -ForegroundColor Green
                }
                continue
            }
            if ($BriefingMode -and ($key.Key -eq 'M' -or $key.KeyChar -eq 'M' -or $key.KeyChar -eq 'm' -or $key.KeyChar -eq 'Ь')) {
                Write-Host "`n" -NoNewline
                Write-Host "❓ Вернуться в меню выбора категорий брифинга? (Y/N)" -ForegroundColor Cyan
                $ans = Read-Host
                if ($ans -eq "Y") {
                    $global:LastExitReason = "BriefingMenu"
                    $stopLoop = $true
                } else {
                    Write-Host "▶️ Продолжаем отслеживание..." -ForegroundColor Green
                }
                continue
            }
        }

        Start-Sleep -Milliseconds 500

        $currentFiles = Get-ChildItem -Path $SourceFolder -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { -not $_.FullName.StartsWith($TargetFolder,[System.StringComparison]::OrdinalIgnoreCase) }
        foreach ($file in $currentFiles) {
            if (-not $processed.ContainsKey($file.FullName)) {
                $processed[$file.FullName] = $true
                $ext = $file.Extension.ToLower()
                if ($ext -notin @(".png", ".jpg", ".jpeg")) { continue }

                try {
                    $sourceHash = (Get-FileHash -Path $file.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
                    if ($processedHashes.ContainsKey($sourceHash)) {
                        Write-Log "Пропущен дубликат: $($file.Name)"
                        continue
                    }
                } catch {}

                $dest = Join-Path $TargetFolder $file.Name

                $moved = $false
                for ($attempt = 1; $attempt -le 10; $attempt++) {
                    try {
                        Move-Item -Path $file.FullName -Destination $dest -Force -ErrorAction Stop
                        if (Test-Path $dest) {
                            $moved = $true
                            break
                        }
                    } catch {
                        Start-Sleep -Milliseconds 500
                    }
                }

                if (-not $moved) {
                    Write-Host "`n❌ Ошибка переноса $($file.Name)" -ForegroundColor Red
                    Write-Log "Ошибка переноса $($file.FullName)"
                    continue
                }

                if ((Test-Path $dest) -and (-not (Test-Path $file.FullName))) {
                    Add-Score -CategoryKey $CategoryKey -Count 1
                    $sessionCount++
                    try {
                        $destHash = (Get-FileHash -Path $dest -Algorithm SHA256).Hash
                        $processedHashes[$destHash] = $true
                        Save-ProcessedHash $destHash
                    } catch {}
                } else {
                    Write-Host "`n❌ Файл не найден в папке назначения, баллы не начислены" -ForegroundColor Red
                    Write-Log "Файл не найден после перемещения: $dest"
                    continue
                }

                Write-Host ""
                Write-Host "✅ [ПЕРЕМЕЩЁН] $($file.Name)  →  $ModeName"
                Write-Host "📊 За смену: $sessionCount"
                Write-Log "$ModeName -> $($file.Name) (перемещён, баллы начислены)"

                $stats = Get-Stats
                Write-Host "💰 Всего скриншотов: $($stats.TotalCount) | Всего баллов: $($stats.TotalScore)"
            }
        }
    }

    try { [Console]::CancelKeyPress.Remove($handler) } catch {}
    if ($global:LastExitReason -eq "ExitProgram") {
        Write-Host "🔚 Завершение программы..." -ForegroundColor Red
        Write-Log "Выход из программы"
        exit
    }
    # В остальных случаях просто возвращаем управление
    Write-Host "🔁 Возврат..." -ForegroundColor Yellow
    Start-Sleep -Seconds 1
}

# ==================== ГЛАВНЫЙ ЦИКЛ ====================
Initialize-Files

$cfg = Load-Ini $ConfigFile
if ($cfg["FIRST_RUN"] -eq "1") {
    FirstRunWizard
}

AutoSync-StatsWithFolders
$global:LastExitReason = "MainMenu"

while ($true) {
    AutoSync-StatsWithFolders
    $stats = Get-Stats
    Show-Banner
    Write-Host "ОБЩИЙ СЧЁТ: $($stats.TotalCount) скриншотов → $($stats.TotalScore) баллов" -ForegroundColor Green
    Write-Host ""
    Write-Host "========================================================="
    Write-Host ""
    $i = 1
    foreach ($key in $categoryOrder) {
        Write-Host ("[$i]  {0}" -f $categoryNames[$key])
        $i++
    }
    Write-Host ""
    Write-Host "[13] Настройки путей"
    Write-Host "[14] Показать настройки"
    Write-Host "[15] Статистика (детально)"
    Write-Host "[16] Принудительная синхронизация статистики с папками"
    Write-Host "[17] Брифинг (создать новый брифинг)"
    Write-Host ""
    Write-Host "[R1] Сбросить ТОЛЬКО баллы и счётчики (файлы останутся)"
    Write-Host "[R2] Переместить ВСЕ файлы во Вторую неделю и обнулить баллы"
    Write-Host "[0] Выход"
    Write-Host ""
    $choice = Read-Host "Выберите пункт"

    $cfg = Load-Ini $ConfigFile
    switch ($choice) {
        "1"  { Start-Watcher $cfg["PMP_CITY"] "ПМП день город" "PMP_CITY" }
        "2"  { Start-Watcher $cfg["PMP_SUBURB"] "ПМП день пригород" "PMP_SUBURB" }
        "3"  { Start-Watcher $cfg["TABLETS_ELSH"] "Таблетки ELSH" "TABLETS_ELSH" }
        "4"  { Start-Watcher $cfg["TABLETS_PBSS"] "Таблетки PBSS" "TABLETS_PBSS" }
        "5"  { Start-Watcher $cfg["NIGHT_CITY"] "ПМП ночь город" "NIGHT_CITY" }
        "6"  { Start-Watcher $cfg["NIGHT_SUBURB"] "ПМП ночь пригород" "NIGHT_SUBURB" }
        "7"  { Start-Watcher $cfg["VAX_ELSH"] "Вакцины ELSH" "VAX_ELSH" }
        "8"  { Start-Watcher $cfg["VAX_PBSS"] "Вакцины PBSS" "VAX_PBSS" }
        "9"  { Start-Watcher $cfg["CERT_ELSH"] "Мед.справки ELSH день" "CERT_ELSH" }
        "10" { Start-Watcher $cfg["CERT_PBSS"] "Мед.справки PBSS день" "CERT_PBSS" }
        "11" { Start-Watcher $cfg["CERT_ELSH_NIGHT"] "Мед.справки ELSH ночь" "CERT_ELSH_NIGHT" }
        "12" { Start-Watcher $cfg["CERT_PBSS_NIGHT"] "Мед.справки PBSS ночь" "CERT_PBSS_NIGHT" }
        "13" { Configure-Paths }
        "14" { Show-Config }
        "15" { Show-Stats }
        "16" { FullSync-StatsWithFolders }
        "17" { Start-Briefing }
        "R1" { Reset-ScoresOnly; Start-Sleep -Seconds 2 }
        "R2" { MoveToSecondWeek }
        "0"  {
            Write-Log "Выход из программы"
            exit
        }
        default {
            Write-Host "Неверный выбор" -ForegroundColor Red
            Start-Sleep -Seconds 1
        }
    }
}