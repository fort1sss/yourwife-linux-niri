# yourwife-linux-niri

Як запустити **Your Wife** (Steam, app 3339420, аніме-компаньйон для робочого столу) на **Linux + niri (Wayland)** так, щоб вона виглядала й поводилась майже як на Windows.

*English: scripts, niri rules, a shader and a small niri patch that make the Windows desktop-pet "Your Wife" usable on Linux/niri via Proton: transparent background, follows you across workspaces, eyes follow the cursor over the whole screen, no Steam hover glitches, and a CLI instead of the broken tray menu.*

## Що виправлено

| Проблема на Linux | Рішення |
|---|---|
| Чорне вікно замість героїні (Godot D3D12 не створює swapchain під Proton) | `game/override.cfg` перемикає гру на Vulkan |
| Чорний фон замість прозорого (вікна Wine 24-бітні, альфа-канал губиться) | параметр Wine `HKCU\Software\Wine\X11 Driver\ScreenDepth = "32"` (ставить `install.sh`): вікна гри стають ARGB і прозорість передається точно, як на Windows, включно з напівпрозорими частинами моделей. Запасний варіант: `game/linux_key.gd` малює фон #FF00FF, а шейдер `niri/magenta-key.frag` ([niri-shaders](https://github.com/Sileyesi/niri-shaders)) вирізає його |
| Героїня прив'язана до одного робочого столу niri | `bin/niri-pin` переносить її за тобою на кожен стіл |
| Очі не стежать за курсором (Wayland не дає програмам бачити курсор, Wine не оновлює позицію) | патч niri `niri msg cursor-position` + `bin/yw-gaze`: 30 разів/с шле у вікно гри синтетичний X MotionNotify |
| Наведення на героїню відкриває меню Steam (усі X-вікна в xwayland-satellite лежать у (0,0)) | окремий X-сервер для гри: `xwayland-satellite :2` + параметри запуску `DISPLAY=:2 %command%` |
| При зміні розміру героїня обрізається, видно чорні/сірі смуги, вона двоїться або стрибає між двома розмірами | niri перевизначає розмір X-вікна, тож гра не може змінити його сама. `linux_key.gd` повідомляє бажаний розмір, `yw-gaze` (inotify) ставить ширину, висоту й зсув однією командою niri (ріст «від ніг», у межах екрана); поки вікно не доросло, гра малює героїню в масштабі справжнього вікна; фон X-вікна й колір заливки Godot — повністю прозорі; правило `no-resize-animation` (з патчу niri) вимикає анімацію зміни розміру лише для гри |
| Гра з кожною зміною розміру «виїжджала» за екран і ховалась | `linux_key.gd` тримає уявлення гри про позицію вікна в (0,0) — реальним місцем керує niri |
| Зміна героїні чи розміру через налаштування вимагала перезапуску гри | `linux_key.gd` приймає команди від `yourwife` прямо в запущеній грі; при зміні героїні стара плавно зникає, нова плавно з'являється (замість «замерзлого» кадру на 1–3 с завантаження) |
| Меню в треї не працює (кліки по треєві Wine не доходять) | `bin/yourwife`: вибір героїні, розмір, «поверх усіх вікон», старт/стоп |
| Біла смужка трею Wine | правило niri робить її невидимою |
| Сповіщення Steam вилазять будь-де | правило niri + `niri-pin` ставлять їх у правий нижній кут |

## Вимоги

- niri, зібраний з [niri-shaders](https://github.com/Sileyesi/niri-shaders) **з патчем** `patches/niri-yourwife.patch` (команда `niri msg cursor-position` і правило вікна `no-resize-animation`)
- `xwayland-satellite`, Python 3, `libX11`, `libXtst`
- Steam + Proton (перевірено на Proton Experimental 11)

## Встановлення

```bash
# 1. niri-shaders з патчем
git clone https://github.com/Sileyesi/niri-shaders && cd niri-shaders
git apply /шлях/до/yourwife-linux-niri/patches/niri-yourwife.patch
cargo build --release
sudo install -Dm755 -s target/release/niri /usr/local/bin/niri

# 2. Скрипти, правила niri, override.cfg + linux_key.gd для гри
/шлях/до/yourwife-linux-niri/install.sh
```

3. Steam → **Твоя дружина / Your Wife** → Властивості:
   - **Параметри запуску:** `DISPLAY=:2 %command%`
   - вимкни **оверлей Steam** (інакше на героїні з'являється табличка оверлея)
4. Вийди з сесії niri й зайди знову.

## Команда `yourwife`

Поки гра запущена, команди виконуються в ній миттєво, без перезапуску: `game/linux_key.gd` усередині гри читає їх з файлу `linux_cmd.txt` і викликає внутрішні функції гри. Якщо гра закрита, змінюються її налаштування й застосовуються при запуску.

```text
yourwife list                 усі героїні: 8 стандартних + з Майстерні Steam
yourwife char 1..8|ID|назва   вибрати героїню
yourwife size 0.55..4.5       розмір (1 = стандартний)
yourwife top on|off           поверх усіх вікон
yourwife lock on|off          клік крізь героїню
yourwife reset                стандартне місце, розмір і героїня 1
yourwife menu|settings|workshop|help   відкрити вікна гри
yourwife emotions             емоції (*.exp3.json поруч із моделлю) й анімації
yourwife expr НАЗВА|off       показати емоцію, напр. Happy
yourwife motion ГРУПА [N]     програти анімацію
yourwife fps 30|60            ліміт кадрів (30 ≈ удвічі менше навантаження на процесор)
yourwife start|stop|restart|status
```

Емоції: багато моделей з Майстерні мають файли `*.exp3.json` (формат VTube Studio), не прописані в `model3.json`, тож гра їх не використовує. `linux_key.gd` читає їх сам і утримує параметри моделі, доки не `expr off`.

## Налаштування

- `niri/yourwife.kdl`: правила вікна гри. Не вішай на гру глобальні шейдери niri-shaders (напр. `preset:dissolve` на всі вікна) — вони малюють через проміжний буфер і при зміні розміру дають сірі смуги; додай `exclude app-id="^steam_app_3339420$"`.
- Запасний режим прозорості (якщо `ScreenDepth=32` не спрацює): розкоментуй шейдер `magenta-key.frag` у `yourwife.kdl` і видали файл `linux_alpha` з теки гри в префіксі. `tolerance` — наскільки «пурпуровим» може бути колір моделі, щоб не ставати прозорим (0.3).
- `bin/yw-gaze`: `HEAD` — на якій висоті вікна голова героїні (частка від верху), `HZ` — частота оновлення.
- `bin/niri-pin`: список `PINNED` — app-id вікон, які їздять за тобою по столах.

## Обмеження

- Меню з трею не працює; меню, налаштування, Майстерню й довідку гри можна відкрити командами `yourwife menu|settings|workshop|help` або правим кліком по героїні.
- Шпалери з гри не працюють (на niri шпалери малює swaybg/swww).
- Над повноекранними вікнами героїню не видно (так niri показує плаваючі вікна).

## Ліцензія

Скрипти й конфіги — MIT. `patches/niri-yourwife.patch` змінює niri і поширюється на умовах його ліцензії (GPL-3.0-or-later).
Гра Your Wife належить її розробнику (HaHaHaGame); у репозиторії немає жодних файлів гри.
