#!/usr/bin/env python3
import fcntl
import json
import logging
from logging.handlers import RotatingFileHandler
import os
from pathlib import Path
import pwd
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time


SCRIPT = Path(__file__).resolve()


def atomic_json(path, value):
    fd, name = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def paths(app_root):
    etc = Path(os.environ.get("TRIM_PKGETC", app_root / "etc"))
    runtime = etc / "runtime.json"
    saved = json.loads(runtime.read_text()) if runtime.exists() else {}
    share = os.environ.get("TRIM_DATA_SHARE_PATHS", "").split(":")[0]
    var = Path(os.environ.get("TRIM_PKGVAR", app_root / "var"))
    data = Path(share or saved.get("data_root") or
                (app_root / "shares/audiocpp" if (app_root / "shares/audiocpp").is_dir() else var / "data"))
    return {
        "root": app_root, "etc": etc, "var": var, "data": data,
        "dest": Path(os.environ.get("TRIM_APPDEST", app_root / "target")),
        "user": os.environ.get("TRIM_USERNAME", saved.get("username", "audiocpp")),
        "port": int(os.environ.get("TRIM_SERVICE_PORT", saved.get("port", 58009))),
    }


def drop_privileges(user):
    account = pwd.getpwnam(user)
    if os.geteuid() == 0:
        os.initgroups(user, account.pw_gid)
        os.setgid(account.pw_gid)
        os.setuid(account.pw_uid)
    elif os.geteuid() != account.pw_uid:
        raise PermissionError(f"请使用 sudo 或应用用户 {user} 执行")


def process_identity(pid):
    raw = Path(f"/proc/{pid}/stat").read_text()
    ticks = raw[raw.rfind(")") + 2:].split()[19]
    return [ticks, Path("/proc/sys/kernel/random/boot_id").read_text().strip()]


def checked_pidfd(p):
    pidfile = p["var"] / "audiocpp.pid"
    try:
        record = json.loads(pidfile.read_text())
        if not isinstance(record, dict) or not isinstance(record.get("pid"), int) or record["pid"] <= 1:
            return None
        pid = record["pid"]
        fd = os.pidfd_open(pid)
        try:
            cmd = Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0")
            expected = [os.fsencode(SCRIPT), b"run", os.fsencode(p["root"])]
            if process_identity(pid) != record.get("identity") or cmd[1:4] != expected:
                os.close(fd)
                return None
            if select.select([fd], [], [], 0)[0]:
                os.close(fd)
                return None
            return fd
        except BaseException:
            os.close(fd)
            raise
    except (OSError, ValueError, KeyError):
        return None


def running(p):
    fd = checked_pidfd(p)
    if fd is None:
        return False
    os.close(fd)
    return True


def migrate_config(source):
    value = json.loads(source.read_text(encoding="utf-8"))
    def absolute(obj, key):
        text = obj.get(key)
        if isinstance(text, str) and text and text != "embedded" and not Path(text).is_absolute():
            obj[key] = str((source.parent / text).resolve())
    for key in ("models_root", "voice_dir", "model_spec_override"):
        absolute(value, key)
    for model in value.get("models", []):
        for key in ("path", "model_spec_override"):
            absolute(model, key)
        for preset in model.get("voice_presets", {}).values():
            absolute(preset, "voice_ref")
        if isinstance(model.get("default_voice_preset"), dict):
            absolute(model["default_voice_preset"], "voice_ref")
    return value


def install(p):
    for folder in (p["etc"], p["var"], p["data"] / "models/silero_vad",
                   p["data"] / "voices", p["data"] / "logs"):
        folder.mkdir(parents=True, exist_ok=True)
    config = p["data"] / "server.json"
    if config.exists():
        json.loads(config.read_text(encoding="utf-8"))
    elif (p["etc"] / "server.json").exists():
        atomic_json(config, migrate_config(p["etc"] / "server.json"))
    else:
        template = json.loads((p["dest"] / "etc/server.json.template").read_text(encoding="utf-8"))
        def render(value):
            if isinstance(value, str):
                return value.replace("__DATA_ROOT__", str(p["data"]))
            if isinstance(value, list):
                return [render(item) for item in value]
            if isinstance(value, dict):
                return {key: render(item) for key, item in value.items()}
            return value
        atomic_json(config, render(template))
    vad = p["dest"] / "assets/silero_vad/silero_vad_16k.safetensors"
    if not vad.is_file() or vad.stat().st_size == 0:
        raise FileNotFoundError(f"缺少 VAD：{vad}")
    target = p["data"] / "models/silero_vad" / vad.name
    if not target.exists():
        shutil.copyfile(vad, target)
    voices = p["dest"] / "assets/demo_voices"
    for name in ("demo_1_man.wav", "demo_2_man.wav", "demo_3_woman.wav", "demo_4_woman.wav", "prompt_text"):
        if not (voices / name).is_file() or (voices / name).stat().st_size == 0:
            raise FileNotFoundError(f"缺少参考音频资产：{voices / name}")
    for src in voices.iterdir():
        dst = p["data"] / "voices" / src.name
        if src.is_file() and not dst.exists():
            shutil.copyfile(src, dst)
    atomic_json(p["etc"] / "runtime.json", {
        "data_root": str(p["data"]), "port": p["port"], "username": p["user"],
    })
    if os.geteuid() == 0:
        account = pwd.getpwnam(p["user"])
        for root in (p["data"], p["var"]):
            os.chown(root, account.pw_uid, account.pw_gid)
            for directory, dirs, files in os.walk(root):
                for name in dirs + files:
                    os.chown(Path(directory) / name, account.pw_uid, account.pw_gid, follow_symlinks=False)
        os.chown(p["etc"] / "runtime.json", account.pw_uid, account.pw_gid)
    drop_privileges(p["user"])
    with (p["data"] / "logs/provision-launch.log").open("w") as out:
        subprocess.Popen([sys.executable, str(p["dest"] / "bin/provision-models.py"),
                          str(config), str(p["dest"] / "bin"), str(p["data"] / "logs")],
                         stdin=subprocess.DEVNULL, stdout=out, stderr=out, start_new_session=True)
    print(f"初始化完成，后台下载状态见 {p['data']}/logs/model-download.status；失败可重试 download-models。")
    return 0


def run(p):
    with (p["var"] / "server.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        logger = logging.getLogger("server")
        logger.setLevel(logging.INFO)
        handler = RotatingFileHandler(p["data"] / "logs/server.log", maxBytes=10 * 1024 * 1024,
                                      backupCount=3, encoding="utf-8")
        handler.setFormatter(logging.Formatter("%(asctime)s %(message)s"))
        logger.addHandler(handler)
        env = os.environ.copy()
        env["LD_LIBRARY_PATH"] = str(p["dest"] / "bin") + ":" + env.get("LD_LIBRARY_PATH", "")
        config = json.loads((p["data"] / "server.json").read_text(encoding="utf-8"))
        child = subprocess.Popen([str(p["dest"] / "bin/audiocpp_server"), "--no-ui", "--log",
                                  "--host", config.get("host", "0.0.0.0"),
                                  "--port", str(p["port"]), "--backend", "vulkan",
                                  "--config", str(p["data"] / "server.json")],
                                 cwd=p["dest"] / "bin", env=env,
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        stopping = None
        def stop(signum, frame):
            nonlocal stopping
            if stopping is None:
                stopping = time.monotonic()
                child.terminate()
        signal.signal(signal.SIGTERM, stop)
        signal.signal(signal.SIGINT, stop)
        pidfile = p["var"] / "audiocpp.pid"
        atomic_json(pidfile, {"pid": os.getpid(), "identity": process_identity(os.getpid())})
        try:
            while child.poll() is None:
                if stopping is not None and time.monotonic() - stopping > 15:
                    child.kill()
                if select.select([child.stdout], [], [], 0.2)[0]:
                    block = os.read(child.stdout.fileno(), 65536)
                    if block:
                        logger.info("%s", block.decode(errors="replace").rstrip())
            remaining = child.stdout.read()
            if remaining:
                logger.info("%s", remaining.decode(errors="replace").rstrip())
            return child.returncode
        finally:
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()
            pidfile.unlink(missing_ok=True)
            logger.removeHandler(handler)
            handler.close()


def start(p):
    if running(p):
        return 0
    json.loads((p["data"] / "server.json").read_text(encoding="utf-8"))
    if not os.access(p["dest"] / "bin/audiocpp_server", os.X_OK):
        raise FileNotFoundError("缺少 audiocpp_server 可执行文件")
    with (p["data"] / "logs/service-launch.log").open("w") as out:
        child = subprocess.Popen([sys.executable, str(SCRIPT), "run", str(p["root"])],
                                 stdin=subprocess.DEVNULL, stdout=out, stderr=out, start_new_session=True)
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        if child.poll() is not None:
            raise RuntimeError("服务启动失败，请查看共享 logs/server.log 和 service-launch.log")
        time.sleep(0.1)
    if not running(p):
        raise RuntimeError("服务未登记 PID，请查看 service-launch.log")
    return 0


def stop(p):
    fd = checked_pidfd(p)
    if fd is None:
        return 0
    try:
        try:
            signal.pidfd_send_signal(fd, signal.SIGTERM)
        except ProcessLookupError:
            return 0
        if not select.select([fd], [], [], 20)[0]:
            raise RuntimeError("服务未能停止；拒绝盲目清除 PID 或启动第二个实例")
    finally:
        os.close(fd)
    return 0


def diagnose(p):
    print(f"user={pwd.getpwuid(os.getuid()).pw_name} groups={os.getgroups()}")
    print(f"config={p['data']}/server.json logs={p['data']}/logs port={p['port']}")
    print(f"running={running(p)}")
    nodes = sorted(Path("/dev/dri").glob("renderD*"))
    for node in nodes:
        print(f"{node}: read/write={os.access(node, os.R_OK | os.W_OK)}")
    if not nodes:
        print("未发现 renderD 节点；请检查 NAS 驱动和 BIOS，Vulkan 不会自动回退 CPU。")
    return 0


def main():
    action = sys.argv[1]
    p = paths(Path(sys.argv[2]).resolve())
    if action == "install":
        return install(p)
    drop_privileges(p["user"])
    if action == "status":
        return 0 if running(p) else 3
    if action == "diagnose":
        return diagnose(p)
    if action == "download-models":
        os.execv(sys.executable, [sys.executable, str(p["dest"] / "bin/provision-models.py"),
                                 str(p["data"] / "server.json"), str(p["dest"] / "bin"),
                                 str(p["data"] / "logs")])
    if action == "run":
        return run(p)
    if action not in ("start", "stop", "restart"):
        raise ValueError("用法：main start|stop|restart|status|download-models|diagnose")
    with (p["var"] / "service-control.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if action in ("stop", "restart"):
            stop(p)
        return start(p) if action in ("start", "restart") else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError, KeyError, IndexError) as exc:
        message = f"audio.cpp: {exc}"
        print(message, file=sys.stderr)
        if os.environ.get("TRIM_TEMP_LOGFILE"):
            Path(os.environ["TRIM_TEMP_LOGFILE"]).write_text(message + "\n")
        sys.exit(1)
