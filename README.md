# A/D DevOps console

Консольная утилита для DevOps-роли в Attack-Defense: состояние сервисов,
логи, бэкапы, восстановление, полный pre-game бэкап и staging для теста фиксов.

Ничего не хардкодит: сервисы берутся из `docker compose`, пути и параметры — из конфига,
объёмы — из `docker volume ls` по метке проекта, порты — из `docker compose config`.

## Требования
- Python 3.8+
- Docker + Docker Compose v2 (`docker compose ...`)
- Права на чтение проекта; для бэкапа `/etc/...` и volumes — root
- Для бэкапа volumes нужен образ с `tar` (по умолчанию `alpine:3.20`, можно заменить)

## Запуск
```bash
python3 devops.py                 # меню, при первом запуске спросит настройки
python3 devops.py --config /path/config.json
```
На Windows:
```powershell
python devops\devops.py
```
Если в консоли кракозябры: `chcp 65001`.

## Меню
1. **Состояние сервера** — `docker compose ps`, health, рестарты, порты, load/RAM/disk, `docker system df`.
2. **Последний вывод** — `docker compose logs --tail N` по выбранному сервису или всем.
3. **Список бэкапов** — имя, дата, размер, число сервисов.
4. **Бэкап всех сервисов** — файлы проекта + `compose config` + `docker ps/images/volumes` + volumes.
5. **Восстановление** — выбор бэкапа, опциональный safety-бэкап, `compose down`, возврат файлов,
   опционально volumes, `compose up -d --build`, проверка `ps`.
6. **Полный бэкап сервера** — то же + `system-info.txt` (df/free/ss/версии) и архивы `extra_paths`.
7. **Staging** — копия проекта (или бэкапа) в отдельной папке, published-порты сдвигаются на
   `staging_port_offset`, `container_name` убирается, запуск `docker compose -p <prefix>-<ts> up -d --build`.
   Тестируешь фикс на других портах, прод не трогаешь.

## Порядок перед игрой
1. `7)` staging из текущего проекта → убедиться, что копия поднимается.
2. `6)` полный бэкап сервера (метка `pregame`).
3. Фиксы сначала на staging, проверка checker-ом/курлом.
4. Деплой фикса на прод (rsync/scp + `docker compose up -d --build`).
5. Если прод сломался — `5)` откат из бэкапа.

## Конфиг
`config.example.json` → скопировать в `config.json` и поправить:
```json
{
  "project_dir": "/srv/ad",
  "compose_file": "docker-compose.yml",
  "backup_dir": "/srv/ad-backups",
  "docker_cmd": ["docker"],
  "tail_lines": 200,
  "volume_backup_image": "alpine:3.20",
  "backup_exclude": [".git", "__pycache__", "node_modules", ".venv", "venv"],
  "extra_paths": ["/etc/nginx"],
  "pre_backup_commands": ["pg_dumpall -U postgres > /srv/ad/dump.sql"],
  "staging_dir": "/srv/ad-staging",
  "staging_port_offset": 10000,
  "staging_project_prefix": "adstage"
}
```
- `docker_cmd` — можно указать обёртку/полный путь (`["/usr/bin/docker"]`, `["sudo","docker"]`).
- `pre_backup_commands` — любые команды перед снимком (дампы БД), выполняются в `project_dir`, лог в бэкапе.
- `extra_paths` — что ещё архивировать в полный бэкап (конфиги nginx, сертификаты и т.п.).
- Относительные пути в конфиге считаются от папки конфига; `compose_file` — от `project_dir`.

## CLI без меню (для скриптов и cron)
```bash
python3 devops.py status
python3 devops.py tail --service web
python3 devops.py backups
python3 devops.py backup --label nightly
python3 devops.py backup --full --label pregame
python3 devops.py restore --name 20261111-120000_pregame
python3 devops.py staging --backup 20261111-120000_pregame
```

## Что важно знать
- `restore` по умолчанию **не удаляет** файлы, которых нет в бэкапе (спросит отдельно).
- `restore` не трогает volumes, если не подтвердить; при подтверждении они перезаписываются.
- `staging` требует Docker Compose v2 (`docker compose config --format json`).
- Staging-порты — только опубликованные; внутренние сети и имена контейнеров свои у проекта `-p`.
- Бэкап — это папка с `meta.json`, `project/`, `compose.resolved.yml`, `volumes/*.tgz`; можно копировать/архивировать целиком.
- Секреты из `.env` попадают в бэкап: храни его с ограниченными правами (`chmod 700`).
