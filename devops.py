#!/usr/bin/env python3
"""A/D DevOps console.

Меню:
  1 состояние сервера
  2 последний вывод (tail логов)
  3 список бэкапов
  4 бэкап всех сервисов
  5 восстановление из бэкапа
  6 полный бэкап сервера (перед игрой)
  7 staging: тестовая копия из бэкапа / текущего проекта

Ничего не хардкодит: проект, compose-файл, сервисы, volumes и порты
берутся из конфига, docker compose и ответов на вопросы.
"""
import argparse
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_CONFIG = SCRIPT_DIR / "config.json"
CFG = {}
DOCKER = []


# ---------------------------------------------------------------- config
def resolve_paths(data, base):
    for key in ("project_dir", "backup_dir", "staging_dir"):
        if data.get(key):
            p = Path(data[key])
            data[key] = str((base / p).resolve() if not p.is_absolute() else p.resolve())
    cf = data.get("compose_file")
    if cf:
        p = Path(cf)
        data["compose_file"] = str((Path(data["project_dir"]) / p).resolve() if not p.is_absolute() else p.resolve())
    return data


def find_compose(project_dir):
    for name in ("docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml"):
        p = Path(project_dir) / name
        if p.exists():
            return p
    return None


def setup_wizard(path):
    print("Конфиг не найден, настроим один раз.\n")
    cwd = Path.cwd()
    proj = ask("Папка проекта (где docker-compose.yml)", str(cwd))
    proj = str(Path(proj).resolve())
    comp = find_compose(proj)
    comp = ask("Compose-файл", str(comp) if comp else "docker-compose.yml")
    if not Path(comp).is_absolute():
        comp = str((Path(proj) / comp).resolve())
    backup = ask("Папка для бэкапов", str(Path(proj) / ".devops-backups"))
    staging = ask("Папка для staging", str(Path(proj).parent / (Path(proj).name + "-staging")))
    docker_cmd = ask("Docker-команда (через пробел)", "docker").split()
    offset = ask("Смещение портов staging", "10000")
    extra = ask("Доп. пути для полного бэкапа (через ; , можно пусто)", "")
    data = {
        "project_dir": proj,
        "compose_file": comp,
        "backup_dir": backup,
        "staging_dir": staging,
        "docker_cmd": docker_cmd,
        "tail_lines": 200,
        "volume_backup_image": "alpine:3.20",
        "backup_exclude": [".git", "__pycache__", "node_modules", ".venv", "venv", ".devops-backups"],
        "extra_paths": [x.strip() for x in re.split(r"[;,]", extra) if x.strip()],
        "pre_backup_commands": [],
        "staging_port_offset": int(offset or 10000),
        "staging_project_prefix": "adstage",
    }
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
    print("\nСохранено: %s" % path)
    return load_config(path)


def load_config(path):
    path = Path(path).resolve()
    if not path.exists():
        return setup_wizard(path)
    data = json.loads(path.read_text(encoding="utf-8"))
    data = resolve_paths(data, path.parent)
    data.setdefault("docker_cmd", ["docker"])
    data.setdefault("tail_lines", 200)
    data.setdefault("volume_backup_image", "alpine:3.20")
    data.setdefault("backup_exclude", [".git", "__pycache__", "node_modules", ".venv", "venv"])
    data.setdefault("extra_paths", [])
    data.setdefault("pre_backup_commands", [])
    data.setdefault("staging_port_offset", 10000)
    data.setdefault("staging_project_prefix", "adstage")
    return data


# ---------------------------------------------------------------- helpers
def ask(prompt, default=""):
    suffix = " [%s]" % default if default else ""
    try:
        val = input("%s%s: " % (prompt, suffix)).strip()
    except EOFError:
        return default
    return val or default


def confirm(prompt, default=False):
    d = "Y/n" if default else "y/N"
    val = ask("%s (%s)" % (prompt, d), "")
    if not val:
        return default
    return val.lower() in ("y", "yes", "д", "да")


def run_cmd(cmd, cwd=None, input_text=None, timeout=None, quiet=False):
    try:
        r = subprocess.run(
            cmd, cwd=cwd, text=True, errors="replace", input=input_text,
            capture_output=True, timeout=timeout,
        )
    except FileNotFoundError:
        return subprocess.CompletedProcess(cmd, 127, "", "not found: %s" % cmd[0])
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(cmd, 124, "", "timeout")
    if not quiet and r.returncode != 0 and r.stderr.strip():
        pass
    return r


def compose_cmd(project_dir=None, compose_file=None, project_name=None):
    project_dir = project_dir or CFG["project_dir"]
    compose_file = compose_file or CFG["compose_file"]
    cmd = DOCKER + ["compose", "--project-directory", str(project_dir), "-f", str(compose_file)]
    if project_name:
        cmd += ["-p", project_name]
    return cmd


def compose(*args, project_dir=None, compose_file=None, project_name=None, timeout=None):
    return run_cmd(compose_cmd(project_dir, compose_file, project_name) + list(args),
                   cwd=project_dir or CFG["project_dir"], timeout=timeout)


def human_size(n):
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return "%.1f %s" % (n, unit) if unit != "B" else "%d B" % n
        n /= 1024.0


def dir_size(path):
    total = 0
    for root, _dirs, files in os.walk(path):
        for f in files:
            try:
                total += os.path.getsize(os.path.join(root, f))
            except OSError:
                pass
    return total


def parse_services_yaml(path):
    names = []
    in_services = False
    for line in Path(path).read_text(encoding="utf-8", errors="replace").splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if re.match(r"^services:\s*$", line):
            in_services = True
            continue
        if in_services:
            if re.match(r"^\S", line):
                break
            m = re.match(r"^  ([A-Za-z0-9_.-]+):\s*(#.*)?$", line)
            if m:
                names.append(m.group(1))
    return names


def services():
    def clean(text):
        return [x.strip() for x in text.splitlines()
                if re.fullmatch(r"[A-Za-z0-9_.-]+", x.strip() or "-")]

    r = compose("config", "--services")
    if r.returncode == 0:
        names = clean(r.stdout)
        if names:
            return names
    r = compose("ps", "--services")
    if r.returncode == 0:
        names = clean(r.stdout)
        if names:
            return names
    return parse_services_yaml(CFG["compose_file"])


def project_name():
    r = compose("config", "--format", "json")
    if r.returncode == 0:
        try:
            return json.loads(r.stdout).get("name") or Path(CFG["project_dir"]).name
        except Exception:
            pass
    return Path(CFG["project_dir"]).name


def git_commit(project_dir=None):
    r = run_cmd(["git", "-C", project_dir or CFG["project_dir"], "rev-parse", "--short", "HEAD"])
    return r.stdout.strip() if r.returncode == 0 else ""


# ---------------------------------------------------------------- 1. status
def show_status():
    print("\n=== Состояние сервера ===")
    print("Время:  %s" % datetime.now().strftime("%Y-%m-%d %H:%M:%S"))
    print("Хост:   %s" % socket.gethostname())
    print("Проект: %s" % CFG["project_dir"])
    print("Compose: %s" % CFG["compose_file"])

    r = run_cmd(DOCKER + ["version", "--format", "{{.Server.Version}}"])
    print("Docker: %s" % (r.stdout.strip() if r.returncode == 0 and r.stdout.strip() else "недоступен"))

    svcs = services()
    print("Сервисы (%d): %s" % (len(svcs), ", ".join(svcs) or "-"))

    ps_json = compose("ps", "--format", "json")
    rows = []
    if ps_json.returncode == 0 and ps_json.stdout.strip():
        try:
            data = json.loads(ps_json.stdout)
            rows = data if isinstance(data, list) else [data]
        except Exception:
            for line in ps_json.stdout.splitlines():
                line = line.strip()
                if not line:
                    continue
                try:
                    rows.append(json.loads(line))
                except Exception:
                    pass

    if rows:
        print("\n%-24s %-10s %-12s %-10s %s" % ("CONTAINER", "SERVICE", "STATE", "HEALTH", "PORTS"))
        for row in rows:
            ports = ""
            pubs = row.get("Publishers") or []
            ports = ", ".join("%s:%s->%s" % (p.get("URL", ""), p.get("PublishedPort", ""), p.get("TargetPort", ""))
                              for p in pubs if p.get("PublishedPort")) or "-"
            name = row.get("Name") or row.get("Names") or "-"
            print("%-24s %-10s %-12s %-10s %s" % (
                name, row.get("Service", "-"), row.get("State", "-"),
                row.get("Health", "-") or "-", ports))
    else:
        r = compose("ps")
        print("\n" + (r.stdout or r.stderr).strip())

    if os.path.exists("/proc/loadavg"):
        print("\nLoad:  %s" % Path("/proc/loadavg").read_text().strip())
    if os.path.exists("/proc/meminfo"):
        info = {}
        for line in Path("/proc/meminfo").read_text().splitlines():
            k, _, v = line.partition(":")
            info[k] = v.strip()
        print("RAM:   %s total, %s available" % (info.get("MemTotal", "?"), info.get("MemAvailable", "?")))
    try:
        du = shutil.disk_usage(CFG["project_dir"])
        print("Disk:  %.1f GB free of %.1f GB" % (du.free / 1e9, du.total / 1e9))
    except OSError:
        pass

    r = run_cmd(DOCKER + ["system", "df"])
    if r.returncode == 0 and r.stdout.strip():
        print("\n" + r.stdout.strip())


# ---------------------------------------------------------------- 2. logs
def show_tail():
    svcs = services()
    print("\nСервисы: " + ", ".join("%d) %s" % (i + 1, s) for i, s in enumerate(svcs)) if svcs else "Сервисы не найдены")
    choice = ask("Номер сервиса (Enter = все)", "")
    n = str(CFG["tail_lines"])
    targets = svcs
    if choice:
        try:
            targets = [svcs[int(choice) - 1]]
        except (ValueError, IndexError):
            print("Нет такого номера")
            return
    for svc in targets:
        print("\n=== %s (last %s lines) ===" % (svc, n))
        r = compose("logs", "--tail", n, "--no-color", svc)
        if r.returncode != 0:
            r = compose("logs", "--tail", n, svc)
        print((r.stdout or r.stderr).rstrip())


# ---------------------------------------------------------------- 3. backups
def list_backups():
    root = Path(CFG["backup_dir"])
    if not root.exists():
        return []
    items = []
    for p in sorted(root.iterdir()):
        if not p.is_dir():
            continue
        meta = p / "meta.json"
        if not meta.exists():
            continue
        try:
            data = json.loads(meta.read_text(encoding="utf-8"))
        except Exception:
            data = {}
        items.append({"path": p, "meta": data})
    items.sort(key=lambda x: x["path"].name)
    return items


def show_backups():
    items = list_backups()
    if not items:
        print("\nБэкапов нет: %s" % CFG["backup_dir"])
        return
    print("\n%-3s %-40s %-16s %-10s %-8s" % ("#", "ИМЯ", "КОГДА", "РАЗМЕР", "SERVICES"))
    for i, it in enumerate(items, 1):
        m = it["meta"]
        print("%-3d %-40s %-16s %-10s %-8s" % (
            i, it["path"].name, m.get("created", "?")[:16],
            human_size(m.get("size", dir_size(it["path"]))), len(m.get("services", []))))


def choose_backup(prompt="Номер бэкапа"):
    items = list_backups()
    if not items:
        print("Бэкапов нет")
        return None
    show_backups()
    val = ask(prompt, "")
    try:
        return items[int(val) - 1]
    except (ValueError, IndexError):
        print("Нет такого номера")
        return None


# ---------------------------------------------------------------- 4. backup
def copy_project(src, dst, exclude, backup_dir):
    backup_dir = Path(backup_dir).resolve()

    def ignore(path, names):
        skipped = set()
        for n in names:
            if n in exclude:
                skipped.add(n)
            elif (Path(path) / n).resolve() == backup_dir:
                skipped.add(n)
        return skipped

    shutil.copytree(src, dst, ignore=ignore, symlinks=True)


def backup_volumes(dest):
    pname = project_name()
    r = run_cmd(DOCKER + ["volume", "ls", "-q", "--filter",
                          "label=com.docker.compose.project=%s" % pname])
    if r.returncode != 0:
        print("  volumes: пропуск (docker volume ls недоступен)")
        return []
    vols = [x.strip() for x in r.stdout.splitlines() if x.strip()]
    if not vols:
        print("  volumes: не найдены для проекта %s" % pname)
        return []
    vdir = dest / "volumes"
    vdir.mkdir(exist_ok=True)
    image = CFG["volume_backup_image"]
    saved = []
    for vol in vols:
        print("  volume %s -> %s.tgz" % (vol, vol))
        res = run_cmd(DOCKER + ["run", "--rm",
                                "-v", "%s:/from:ro" % vol,
                                "-v", "%s:/to" % str(vdir.resolve()),
                                image, "sh", "-c", "tar czf /to/%s.tgz -C /from ." % vol])
        if res.returncode == 0 and (vdir / (vol + ".tgz")).exists():
            saved.append(vol)
        else:
            print("    ! не удалось: %s" % (res.stderr.strip().splitlines()[-1] if res.stderr.strip() else res.returncode))
    return saved


def run_pre_commands(dest):
    log = dest / "pre_backup.log"
    cmds = CFG.get("pre_backup_commands") or []
    if not cmds:
        return
    with open(log, "a", encoding="utf-8") as f:
        for cmd in cmds:
            print("  pre: %s" % cmd)
            f.write("\n$ %s\n" % cmd)
            r = subprocess.run(cmd, shell=True, cwd=CFG["project_dir"],
                               text=True, errors="replace", capture_output=True)
            f.write(r.stdout + r.stderr)


def create_backup(label="manual", full=False):
    ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    safe = re.sub(r"[^A-Za-z0-9_.-]+", "-", label or "backup").strip("-")[:40] or "backup"
    dest = Path(CFG["backup_dir"]) / ("%s_%s" % (ts, safe))
    Path(CFG["backup_dir"]).mkdir(parents=True, exist_ok=True)
    if dest.exists():
        print("Бэкап уже существует: %s" % dest)
        return None
    dest.mkdir(parents=True)
    print("\n=== Бэкап: %s ===" % dest.name)

    print("  копирую проект...")
    copy_project(CFG["project_dir"], dest / "project",
                 set(CFG["backup_exclude"]), CFG["backup_dir"])

    r = compose("config")
    (dest / "compose.resolved.yml").write_text(
        r.stdout if r.returncode == 0 else Path(CFG["compose_file"]).read_text(errors="replace"),
        encoding="utf-8")

    for name, cmd in (("containers.txt", DOCKER + ["ps", "-a"]),
                      ("images.txt", DOCKER + ["images"]),
                      ("volumes.txt", DOCKER + ["volume", "ls"])):
        res = run_cmd(cmd)
        (dest / name).write_text((res.stdout or "") + (res.stderr or ""), encoding="utf-8")

    print("  volumes...")
    saved_vols = backup_volumes(dest)

    run_pre_commands(dest)

    if full:
        print("  системный срез...")
        write_system_snapshot(dest)

    meta = {
        "created": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "label": label,
        "full": full,
        "host": socket.gethostname(),
        "project_dir": CFG["project_dir"],
        "compose_file": CFG["compose_file"],
        "git_commit": git_commit(),
        "services": services(),
        "volumes": saved_vols,
        "extra_paths": CFG["extra_paths"] if full else [],
        "size": dir_size(dest),
    }
    (dest / "meta.json").write_text(json.dumps(meta, indent=2, ensure_ascii=False), encoding="utf-8")
    print("готово: %s (%s)" % (dest, human_size(meta["size"])))
    return dest


def write_system_snapshot(dest):
    lines = ["time: %s" % datetime.now().isoformat(timespec="seconds"),
             "host: %s" % socket.gethostname(),
             "project: %s" % CFG["project_dir"]]
    if os.path.exists("/proc/uptime"):
        lines.append("uptime: %s" % Path("/proc/uptime").read_text().strip())
    cmds = [("docker version", DOCKER + ["version"]),
            ("docker ps -a", DOCKER + ["ps", "-a"]),
            ("docker images", DOCKER + ["images"]),
            ("docker volume ls", DOCKER + ["volume", "ls"]),
            ("df -h", ["df", "-h"]),
            ("free -m", ["free", "-m"]),
            ("ss -ltnp", ["ss", "-ltnp"])]
    for title, cmd in cmds:
        r = run_cmd(cmd)
        lines.append("\n### %s\n%s%s" % (title, r.stdout, r.stderr))
    (dest / "system-info.txt").write_text("\n".join(lines), encoding="utf-8")

    paths = [p for p in CFG["extra_paths"] if Path(p).exists()]
    if not paths:
        return
    if shutil.which("tar"):
        tar = dest / "system.tar.gz"
        r = run_cmd(["tar", "czf", str(tar)] + paths)
        if r.returncode != 0:
            print("    ! tar не смог: %s" % r.stderr.strip().splitlines()[-1:])
    else:
        out = dest / "system"
        out.mkdir(exist_ok=True)
        for p in paths:
            target = out / p.strip("/").replace("/", "_")
            try:
                if Path(p).is_dir():
                    shutil.copytree(p, target)
                else:
                    shutil.copy2(p, target)
            except OSError as e:
                print("    ! %s: %s" % (p, e))


# ---------------------------------------------------------------- 5. restore
def restore_volumes(backup_path):
    vdir = Path(backup_path) / "volumes"
    if not vdir.exists() or not any(vdir.glob("*.tgz")):
        return
    if not confirm("Восстановить volumes из бэкапа? Текущие данные будут перезаписаны", False):
        return
    image = CFG["volume_backup_image"]
    for tgz in sorted(vdir.glob("*.tgz")):
        vol = tgz.stem
        print("  volume %s" % vol)
        run_cmd(DOCKER + ["volume", "rm", "-f", vol])
        run_cmd(DOCKER + ["volume", "create", vol])
        r = run_cmd(DOCKER + ["run", "--rm",
                              "-v", "%s:/to" % vol,
                              "-v", "%s:/from:ro" % str(vdir.resolve()),
                              image, "sh", "-c", "tar xzf /from/%s -C /to" % tgz.name])
        if r.returncode != 0:
            print("    ! ошибка: %s" % (r.stderr.strip().splitlines()[-1] if r.stderr.strip() else r.returncode))


def restore_backup(item, delete_extra=False):
    src = item["path"]
    project = Path(CFG["project_dir"])
    print("\n=== Восстановление: %s ===" % src.name)
    print("  бэкап: %s" % item["meta"].get("created", "?"))
    print("  сервисы: %s" % ", ".join(item["meta"].get("services", []) or []) or "-")
    if not confirm("Точно восстановить? Текущие файлы проекта будут перезаписаны", False):
        print("отменено")
        return False

    if confirm("Сделать бэкап текущего состояния перед откатом?", True):
        create_backup("pre-restore")

    print("  останавливаю стек...")
    r = compose("down", timeout=300)
    if r.returncode != 0:
        print("  ! docker compose down: %s" % (r.stderr.strip().splitlines()[-1] if r.stderr.strip() else r.returncode))

    print("  возвращаю файлы...")
    srcdir = src / "project"
    exclude = set(CFG["backup_exclude"])
    if not srcdir.exists():
        print("  ! в бэкапе нет папки project")
        return False
    for entry in srcdir.iterdir():
        target = project / entry.name
        if entry.is_dir():
            shutil.copytree(entry, target, dirs_exist_ok=True, symlinks=True)
        else:
            shutil.copy2(entry, target)
    if delete_extra:
        keep = {p.name for p in srcdir.iterdir()} | exclude
        backup_dir_name = Path(CFG["backup_dir"]).name
        keep.add(backup_dir_name)
        for entry in project.iterdir():
            if entry.name in keep:
                continue
            print("  удаляю лишнее: %s" % entry.name)
            shutil.rmtree(entry, ignore_errors=True) if entry.is_dir() else entry.unlink(missing_ok=True)

    restore_volumes(src)

    print("  поднимаю стек...")
    r = compose("up", "-d", "--build", timeout=900)
    print((r.stdout or "").strip())
    if r.returncode != 0:
        print("  ! up: %s" % (r.stderr or "").strip()[-500:])
    r = compose("ps")
    print("\n" + (r.stdout or r.stderr).strip())
    return r.returncode == 0


# ---------------------------------------------------------------- 6. full backup
def full_backup():
    label = ask("Метка (Enter = pregame)", "pregame")
    create_backup(label, full=True)


# ---------------------------------------------------------------- 7. staging
def staging_from(backup_item=None):
    ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    root = Path(CFG["staging_dir"]) / ("stage-" + ts)
    root.parent.mkdir(parents=True, exist_ok=True)

    if backup_item:
        src_project = backup_item["path"] / "project"
        print("\n=== staging из бэкапа %s ===" % backup_item["path"].name)
    else:
        src_project = Path(CFG["project_dir"])
        print("\n=== staging из текущего проекта ===")

    if not src_project.exists():
        print("! нет папки: %s" % src_project)
        return
    print("  копирую в %s" % root)
    copy_project(src_project, root, set(CFG["backup_exclude"]), CFG["backup_dir"])

    comp = find_compose(root)
    if not comp:
        print("! compose-файл не найден в staging")
        return

    r = run_cmd(compose_cmd(root, comp) + ["config", "--format", "json"], cwd=root)
    if r.returncode != 0:
        print("! нужен docker compose v2 (config --format json)")
        print(r.stderr.strip()[-400:])
        return
    data = json.loads(r.stdout)

    offset = int(CFG["staging_port_offset"])
    mapping = []
    for sname, svc in (data.get("services") or {}).items():
        svc.pop("container_name", None)
        newports = []
        for p in svc.get("ports") or []:
            if isinstance(p, dict):
                pub = p.get("published")
                if pub:
                    old = str(pub)
                    p["published"] = str(int(old) + offset)
                    mapping.append((sname, old, p["published"]))
                newports.append(p)
            else:
                s = str(p)
                parts = s.split(":")
                if len(parts) >= 2 and parts[-2].isdigit():
                    old = parts[-2]
                    parts[-2] = str(int(old) + offset)
                    mapping.append((sname, old, parts[-2]))
                newports.append(":".join(parts))
        svc["ports"] = newports

    staging_compose = root / "docker-compose.staging.json"
    staging_compose.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")

    pname = "%s-%s" % (CFG["staging_project_prefix"], ts)
    print("  поднимаю проект %s (порты +%d)..." % (pname, offset))
    r = run_cmd(compose_cmd(root, staging_compose, pname) + ["up", "-d", "--build"],
                cwd=root, timeout=1800)
    print((r.stdout or "").strip()[-2000:])
    if r.returncode != 0:
        print("! up: %s" % (r.stderr or "").strip()[-500:])

    if mapping:
        print("\nПорты staging:")
        for svc, old, new in mapping:
            print("  %-12s %s -> %s" % (svc, old, new))
    r = run_cmd(compose_cmd(root, staging_compose, pname) + ["ps"], cwd=root)
    print("\n" + (r.stdout or r.stderr).strip())
    print("\nПроект: %s" % pname)


# ---------------------------------------------------------------- menu
def menu():
    while True:
        print("\n=== A/D DevOps ===")
        print("1) Состояние сервера")
        print("2) Последний вывод (tail логов)")
        print("3) Список бэкапов")
        print("4) Сделать бэкап всех сервисов")
        print("5) Восстановиться из бэкапа")
        print("6) Полный бэкап сервера (перед игрой)")
        print("7) Поднять staging для теста фиксов")
        print("0) Выход")
        try:
            choice = input("Выбор: ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            return
        if choice == "1":
            show_status()
        elif choice == "2":
            show_tail()
        elif choice == "3":
            show_backups()
        elif choice == "4":
            label = ask("Метка бэкапа", "manual")
            create_backup(label)
        elif choice == "5":
            item = choose_backup()
            if item:
                delete_extra = confirm("Удалять файлы, которых нет в бэкапе?", False)
                restore_backup(item, delete_extra)
        elif choice == "6":
            full_backup()
        elif choice == "7":
            item = None
            if confirm("Использовать бэкап? (нет = текущий проект)", True):
                item = choose_backup()
                if not item:
                    continue
            staging_from(item)
        elif choice == "0":
            return
        else:
            print("Нет такого пункта")


def main():
    global CFG, DOCKER
    ap = argparse.ArgumentParser(description="A/D DevOps console")
    ap.add_argument("--config", default=str(DEFAULT_CONFIG))
    sub = ap.add_subparsers(dest="cmd")

    sub.add_parser("status")
    t = sub.add_parser("tail")
    t.add_argument("--service", default=None)
    sub.add_parser("backups")
    b = sub.add_parser("backup")
    b.add_argument("--label", default="manual")
    b.add_argument("--full", action="store_true")
    r = sub.add_parser("restore")
    r.add_argument("--name", default=None)
    r.add_argument("--delete-extra", action="store_true")
    s = sub.add_parser("staging")
    s.add_argument("--backup", default=None)

    a = ap.parse_args()
    CFG = load_config(a.config)
    DOCKER = list(CFG["docker_cmd"])

    if a.cmd == "status":
        show_status()
    elif a.cmd == "tail":
        if a.service:
            print(compose("logs", "--tail", str(CFG["tail_lines"]), a.service).stdout)
        else:
            show_tail()
    elif a.cmd == "backups":
        show_backups()
    elif a.cmd == "backup":
        create_backup(a.label, full=a.full)
    elif a.cmd == "restore":
        items = list_backups()
        item = next((x for x in items if x["path"].name == a.name), None) if a.name else None
        if not item and a.name:
            print("Бэкап не найден: %s" % a.name)
            raise SystemExit(1)
        if not item:
            item = choose_backup()
        if item:
            restore_backup(item, a.delete_extra)
    elif a.cmd == "staging":
        item = None
        if a.backup:
            items = list_backups()
            item = next((x for x in items if x["path"].name == a.backup), None)
            if not item:
                print("Бэкап не найден: %s" % a.backup)
                raise SystemExit(1)
        staging_from(item)
    else:
        menu()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nвыход")
