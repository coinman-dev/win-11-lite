# Отчёт 3: Recall и AI-компоненты — что есть в наших образах и как это вырезать

**Дата:** 2026-09-10
**Проверено:** состав оригинального ISO (26100.1742), состав Full.Fast (26100.9168), документация Microsoft Policy CSP WindowsAI (обновлена 18.08.2026)

---

## 1. Что такое Recall

Функция делает снимки экрана каждые несколько секунд, прогоняет их через OCR, складывает в локальную зашифрованную базу и индексирует — чтобы потом можно было найти «что я видел на прошлой неделе». Плюс **Click to Do** — надстройка, которая по нажатию делает снимок экрана и предлагает действия над содержимым.

**Хронология:**

| Когда | Что |
|---|---|
| Май 2024 | Анонс. Исследователи (в т.ч. Kevin Beaumont) показали, что база снимков лежала практически в открытом виде и читалась любым процессом пользователя |
| Июнь 2024 | Microsoft отзывает функцию до переработки |
| Апрель 2025 | Выпуск в общую доступность для Copilot+ PC. Переделано: шифрование, VBS Enclave, обязательная аутентификация Windows Hello, opt-in |
| Апрель 2025, KB5055627 (26100.3915) | Появляются политики управления, в том числе для **IoT Enterprise LTSC** |
| 2025–2026 | Click to Do, Improved Search, Settings Agent, AI Fabric расползаются по системе |

**Обработка действительно локальная** — снимки не уходят в облако, это подтверждается и документацией, и независимыми разборами. Ваше опасение про «передаёт данные» в прямом смысле не подтверждается.

Но настоящая проблема в другом: **на диске появляется полный визуальный журнал всего, что вы делали**. Пароли в открытых полях, реквизиты, переписка, содержимое чужих документов. Любой, кто получит доступ к учётной записи — вредонос с правами пользователя, коллега за незаблокированным компьютером, изъятая машина — получает не текущее состояние, а всю историю за 90 дней. Шифрование защищает от чтения диска извне, но не от процесса, работающего под вашей учёткой после входа.

Так что решение «вырезать и заблокировать» — обоснованное, и я его в скрипт заложил.

---

## 2. Что уже есть в наших образах — проверено по составу

### 2.1. Оригинальный LTSC 26100.1742 (сентябрь 2024)

**Recall в образе уже присутствует** — как CBS-пакет:
```
Windows\servicing\Packages\UserExperience-Recall-Package~31bf3856ad364e35~amd64~~10.0.26100.1591.mum
```
Плюс сопутствующее:
```
Windows\SystemApps\MicrosoftWindows.Client.AIX_cw5n1h2txyewy\        (43 файла — AI Experiences)
Windows\SystemApps\Microsoft.Windows.AugLoop.CBS_8wekyb3d8bbwe\      (AugLoop)
Windows\InboxApps\Microsoft.Copilot_8wekyb3d8bbwe.msix               ← готовый установщик Copilot
Windows\WinSxS\amd64_microsoft-copilot_...\
Windows\WinSxS\amd64_userexperience-aix_...\
Windows\SystemApps\MicrosoftWindows.Client.Core_...\CopilotNudges\   ← «подсказки», подталкивающие к Copilot
Windows\PolicyDefinitions\WindowsCopilot.admx
```

То есть даже «чистый корпоративный LTSC» приезжает с Copilot внутри и с пакетом Recall.

### 2.2. Что добавляют обновления — видно по Full.Fast (26100.9168, август 2026)

Это тот же LTSC, но обновлённый почти до нашего целевого билда. Сравнение показывает, чего в 26100.1742 не было:

| Компонент | 26100.1742 | 26100.9168 |
|---|---:|---:|
| `Microsoft.AIFabric.CBS.*` (записей) | 4 | **57** |
| `SemanticSearch*` | 0 | **12** |
| `ClickToDo` | 0 | **4** |
| `RecallIcons.ttf` | нет | **есть** (иконки Recall в системном трее) |

Что именно приезжает в `Windows\SystemApps\Microsoft.AIFabric.CBS.1.6_8wekyb3d8bbwe\`:
```
Microsoft.Windows.AI.Generative.dll        генеративные модели
Microsoft.Windows.Vision.dll               компьютерное зрение
Microsoft.Windows.AI.ContentModeration.dll модерация контента
SemanticSearch.CBS.dll / .Public.dll       семантический поиск
CoPilotLibraryBroker.exe
NpuDetect\NPUDetect.dll                    определение NPU
workloads.json / workloads.365.json
```
Плюс `Windows\System32\WSAIFabricHost.dll` и рабочая папка `ProgramData\Microsoft\Windows\WSAIFabric\`.

**Вывод: накопительное обновление до 26100.9445 принесёт в наш образ AI-инфраструктуру, которой в исходном ISO не было.** Именно поэтому в скрипте удаления идут *после* интеграции обновлений — иначе смысла бы не имело.

Показательно: автор Full.Fast вырезал Defender, WinRE и Edge, но **AI Fabric оставил целиком** (57 записей на месте). Ещё один довод не доверять чужим сборкам.

### 2.3. Оговорка про Copilot+ PC

Сам Recall активируется только на Copilot+ PC — машинах с NPU от 40 TOPS. На обычном железе он не заработает даже будучи установленным. Но:

- **инфраструктура ставится всем** независимо от железа (что и видно в 26100.9168);
- политика `AllowRecallEnablement` **по умолчанию = 1**, то есть «Recall доступен»;
- Click to Do по умолчанию **включён** (`DisableClickToDo` = 0) и к Copilot+ не привязан так жёстко;
- требования к «Copilot+» Microsoft за два года пересматривала неоднократно.

Полагаться на то, что «у меня нет NPU, значит меня это не касается» — не стоит.

---

## 3. Политики: точные имена и значения по умолчанию

Все — в ветке `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsAI`, ADMX `WindowsCopilot.admx`.
Столбец «LTSC» — поддерживается ли на IoT Enterprise LTSC (по документации Microsoft).

| Политика | По умолчанию | Ставим | LTSC | Что делает |
|---|---:|---:|:---:|---|
| **`AllowRecallEnablement`** | **1 (доступен)** | **0** | ✅ | Ключевая. При 0 компонент Recall переводится в disabled **и его биты удаляются с устройства**; сохранённые снимки стираются. Требует перезагрузки |
| **`DisableAIDataAnalysis`** | 0 | **1** | ✅ | Снимки экрана не сохраняются; ранее сохранённые удаляются |
| **`DisableClickToDo`** | **0 (включён)** | **1** | ✅ | Убирает Click to Do и все точки входа в него |
| `AllowRecallExport` | 0 | 0 | ✅ | Запрет экспорта снимков (актуально для ЕЭЗ) |
| `DisableRecallDataProviders` | 0 | **1** | ✅ | Recall не получает доп. данные от App Actions |
| `DisableSettingsAgent` | 0 | **1** | ✅ | Отключает агентный AI-поиск в Параметрах |
| `RemoveMicrosoftCopilotApp` | — | **1** | ✅ | Удаляет приложение Copilot (Enterprise/Education/IoT LTSC; на Pro не работает) |
| `TurnOffWindowsCopilot` | 0 | **1** | ✅ | Ветка `...\Windows\WindowsCopilot`. Помечена deprecated, но продолжает работать |

AI в Paint — отдельная ветка `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint`:
`DisableCocreator`, `DisableGenerativeFill`, `DisableImageCreator` — все ставим в 1.

`DisableAIDataAnalysis`, `DisableClickToDo`, `DisableRecallDataProviders` и `TurnOffWindowsCopilot` действуют и на уровне пользователя — поэтому дублируются в `NTUSER.DAT` профиля по умолчанию, чтобы применялись к каждой новой учётной записи.

---

## 4. Что добавлено в скрипт (группа `AI`)

### Удаление CBS-пакетов
```
^UserExperience-Recall-Package
^UserExperience-AIX-  |  ^Microsoft-Windows-UserExperience-AIX
^Microsoft-Copilot-   |  ^Microsoft-Windows-Copilot-
```

### Удаление каталогов по маске
Имена меняются от билда к билду (`AIFabric.CBS.1.6` сегодня, завтра другая версия), поэтому ищем по шаблону:

| Где | Маска | Что |
|---|---|---|
| `Windows\SystemApps` | `MicrosoftWindows.Client.AIX_*` | AI Experiences |
| `Windows\SystemApps` | `Microsoft.AIFabric.CBS*` | AI Fabric с локальными моделями |
| `Windows\SystemApps` | `Microsoft.Windows.AugLoop.CBS_*` | AugLoop |
| `Windows\InboxApps` | `Microsoft.Copilot_*` | Установочный пакет Copilot |

### Политики
Полный набор из §3 — в `SOFTWARE`, плюс пользовательская часть в `NTUSER.DAT` профиля по умолчанию.

Группа входит в пресет `balanced`, то есть работает по умолчанию. Отключается через `-Keep AI`, если вдруг понадобится.

---

## 5. Честные ограничения

1. **Накопительные обновления могут вернуть часть файлов.** Recall и AI Fabric — компоненты Windows, а не сторонние программы. Следующий LCU способен положить их обратно. Что при этом **не откатывается — политики**: `AllowRecallEnablement=0` продолжает действовать и держать компонент выключенным, а по документации Microsoft ещё и выгружает его биты. Поэтому политики здесь важнее удаления файлов, а удаление — это про размер и гигиену образа.
2. **`sfc /scannow` восстановит удалённые системные файлы.** Ровно та же ситуация, что с Defender. Политики переживут и это.
3. **Полностью «запретить установку навсегда» нельзя** — можно лишь держать функцию выключенной штатными механизмами. Зато это именно поддерживаемый Microsoft путь: он документирован, не ломает обслуживание образа и не отваливается после обновлений.
4. Если однажды понадобится вернуть — достаточно снять политики; компонент доставится через Windows Update.

---

## Источники

- [Policy CSP — WindowsAI (Microsoft Learn, обновлено 18.08.2026)](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-windowsai) — точные имена политик, значения по умолчанию, поддержка IoT Enterprise LTSC
- [Recall overview — Windows apps (Microsoft Learn)](https://learn.microsoft.com/en-us/windows/apps/develop/windows-integration/recall/)
- [Microsoft finally ships Recall after year-long delay (Windows Central)](https://www.windowscentral.com/software-apps/windows-11/windows-recall-general-availability-2025-copilot)
- [Recall, Click to Do и AI-функции — что нового (Windows Central)](https://www.windowscentral.com/software-apps/windows-11/what-is-new-on-recall-click-to-do-search-for-copilot-pcs-running-windows-11)
- [Microsoft launches Recall to general availability — Click to Do and Improved Search (Tom's Hardware)](https://www.tomshardware.com/software/windows/microsoft-launches-recall-to-windows-11-general-availability-click-to-do-and-improved-search-also-coming)
- [How to disable Windows Recall — and why you should (Proton)](https://proton.me/business/blog/disable-windows-recall)
- [Enable or Disable Click to Do in Recall (NinjaOne)](https://www.ninjaone.com/blog/enable-or-disable-click-to-do-in-recall-in-windows-11/)
- [Как отключить 13 AI-функций в Windows 11 (windowslatest, 06.02.2026)](https://www.windowslatest.com/2026/02/06/how-i-disabled-13-ai-features-in-windows-11-safely-no-third-party-apps-needed/)
