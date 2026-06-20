# GodotDeploy

Шаблон Godot 4.6 для деплоя игры в Web одной командой.

- Ветка **`main`** — исходники проекта
- Ветка **`gh-pages`** — готовая игра для GitHub Pages

> В новом репозитории ветки `gh-pages` **ещё нет** — её создаёт `init` (пустую) или первый `deploy` (с игрой).

---

## Первый раз (5–10 минут)

### 1. Создай репозиторий

На GitHub: **Use this template** → создай репо → склонируй:

```bash
git clone https://github.com/ТВОЙ_НИК/ТВОЯ_ИГРА.git
cd ТВОЯ_ИГРА
```

### 2. Настрой Godot

1. Открой проект в **Godot 4.6**
2. **Editor → Manage Export Templates** → скачай **Web**
3. **Project → Project Settings → Application → Config → Name** — название игры

### 3. Настрой деплой

Дважды кликни **`deploy.bat`** или один раз для настройки:

```powershell
.\deploy.bat init
```

`init` создаст конфиг и **ветку `gh-pages` на GitHub** (пока с заглушкой).

Если Godot не находится сам — укажи путь в `deploy/deploy.local.json`:

```json
{
  "godot_path": "C:/Godot/Godot_v4.6-stable_win64.exe"
}
```

### 4. Включи GitHub Pages

Теперь ветка `gh-pages` уже есть. На GitHub:

**Settings → Pages → Branch: `gh-pages` → Folder: `/` → Save**

### 5. Первый деплой

Дважды кликни **`deploy.bat`** или:

```powershell
.\deploy.bat
```

Скрипт сам:

1. Подтянет последние изменения с GitHub
2. Увеличит версию (`0.1.0` → `0.1.1` → `0.1.2` …)
3. Закоммитит исходники в **`main`**
4. Соберёт Web-версию
5. Зальёт на **`gh-pages`** — там обновится README со списком изменений
6. Создаст тег `v0.1.1`

Версию вручную менять не нужно.

---

## Для команды

1. Клонирует репо
2. Ставит Godot 4.6 + Web Export Templates
3. `.\deploy.bat init` + путь к Godot
4. Правки → **`deploy.bat`**

---

## Если что-то не работает

| Проблема | Решение |
|----------|---------|
| Ветки `gh-pages` нет в Settings | Запусти `.\deploy.bat init` (нужен `origin`) |
| Godot не найден | Пропиши путь в `deploy/deploy.local.json` |
| Ошибка экспорта | Скачай Web Export Templates в Godot |
| Старая версия в браузере | Ctrl+F5 |
| Pages 404 | Подожди 1–2 мин после deploy |
| Конфликт README при deploy | Не редактируй `README.md` вручную — правки в `deploy/README.template.md` |

> **`README.md` в main** всегда берётся из `deploy/README.template.md` при `init` и `deploy` (README с GitHub при создании репо заменится автоматически).

---

## Linux / macOS

```bash
chmod +x deploy/deploy.sh
./deploy/deploy.sh init   # один раз
./deploy/deploy.sh        # деплой
```
