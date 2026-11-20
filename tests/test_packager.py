import fcntl
import hashlib
import http.server
import importlib.util
import io
import json
import os
from pathlib import Path
import pwd
import select
import signal
import shutil
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import release
import check_payload


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


models = load("models", "payload/bin/provision-models.py")
service = load("service", "payload/bin/service.py")


class Versions(unittest.TestCase):
    def test_all_event_origins(self):
        for event in ("schedule", "workflow_dispatch", "push"):
            result = release.resolve({"GITHUB_EVENT_NAME": event, "CALL_BASE": "0.9.5", "IN_REV": "000"}, [])
            self.assertEqual(result["ref"], "v0.9.5")
            self.assertEqual(result["kind"], "release")
        self.assertEqual(release.resolve({"GITHUB_REF": "refs/tags/v0.9.4-002"}, [])["version"], "0.9.4-002")

    def test_revision_uses_maximum(self):
        result = release.resolve({"IN_REF": "v0.9.4"}, ["v0.9.4-002", "v0.9.4-010", "v1.0.0-999"])
        self.assertEqual(result["version"], "0.9.4-011")
        self.assertEqual(result["kind"], "preview")

    def test_invalid_versions_are_rejected(self):
        for tag in ("v0.9.4", "v0.9.2-drama3-base-small-000", "v01.2.3-001", "v0.9.4-1000", "v0.9.4-0"):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                release.parse_tag(tag)
        for base in ("", "0.9.5\nevil=1", "0.9.5;touch x", "0.9.5-beta"):
            with self.assertRaises(ValueError):
                release.resolve({"CALL_BASE": base, "IN_REV": "000"}, [])
        with self.assertRaises(ValueError):
            release.next_revision("0.9.4", ["v0.9.4-999"])


class Publication(unittest.TestCase):
    def setUp(self):
        self.tag = "v0.9.5-000"
        self.asset = {"name": "audiocpp_0.9.5-000_x86.fpk", "size": 42, "state": "uploaded",
                      "digest": "sha256:" + "a" * 64, "browser_download_url": "fixture:asset"}
        self.current = {"draft": False, "prerelease": False, "assets": [self.asset],
                        "tag_name": self.tag, "target_commitish": "sha"}
        self.index = {"apps": {"audiocpp": {"releases": {"0.9.5-000": {"packages": {"x86": {
            "sha256": "a" * 64, "size": 42, "download_url": "fixture:asset"}}}}}}}

    def detect(self, current, index=None, force="false", commit="sha", existing=None):
        with patch.object(release, "api", side_effect=[{"draft": False, "prerelease": False}, {}, [[current] if current else []]]), \
                patch.object(release, "release", return_value=current), \
                patch.object(release.subprocess, "check_output", return_value=commit):
            return release.detect("owner/repo", "0.9.5", force,
                                  existing if existing is not None else [self.tag], index or {}, "sha")

    def test_tag_without_release_rebuilds(self):
        self.assertEqual(self.detect(None)["action"], "build")
        self.assertEqual(self.detect(None)["rev"], "000")
        self.assertEqual(self.detect(None, commit="older-sha")["rev"], "001")

    def test_asset_without_index_only_syncs(self):
        self.assertEqual(self.detect(self.current)["action"], "sync")

    def test_complete_publication_is_noop(self):
        self.assertEqual(self.detect(self.current, self.index)["action"], "none")

    def test_draft_with_asset_only_syncs(self):
        self.current["draft"] = True
        self.assertEqual(self.detect(self.current, self.index)["action"], "sync")

    def test_force_increments(self):
        self.assertEqual(self.detect(self.current, self.index, force="true")["rev"], "001")

    def test_draft_without_git_tag_is_not_rebuilt(self):
        self.current["draft"] = True
        self.assertEqual(self.detect(self.current, existing=[])["action"], "sync")
        self.assertEqual(self.detect(self.current, existing=[], force="true")["rev"], "001")

    def test_annotated_tag_must_resolve_to_build_commit(self):
        ref = {"object": {"type": "tag", "sha": "tag-object"}}
        commit = {"object": {"type": "commit", "sha": "build-sha"}}
        with patch.object(release, "api", side_effect=[ref, commit]):
            release.assert_tag_sha("owner/repo", self.tag, "build-sha")
        with patch.object(release, "api", side_effect=[ref, commit]), self.assertRaises(ValueError):
            release.assert_tag_sha("owner/repo", self.tag, "different-sha")

    def test_corrupt_draft_is_not_published(self):
        self.current["draft"] = True
        with patch.object(release, "release", return_value=self.current), \
                patch.object(release, "download_asset", return_value=(Path("fixture"), "a" * 64)), \
                patch.object(check_payload, "check_fpk", side_effect=ValueError("invalid package")), \
                patch.object(release.subprocess, "run") as run, self.assertRaises(ValueError):
            release.publish("owner/repo", self.tag, "sha", Path("missing"))
        run.assert_not_called()

    def test_asset_digest_and_size_are_checked(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            path = folder / self.asset["name"]
            path.write_bytes(b"payload")
            self.asset.update(size=7, digest=None)
            with patch.object(release.subprocess, "run"):
                _, digest = release.download_asset("owner/repo", self.tag, self.asset, folder)
                self.assertEqual(digest, hashlib.sha256(b"payload").hexdigest())
                self.asset["digest"] = "sha256:" + "a" * 64
                with self.assertRaises(ValueError):
                    release.download_asset("owner/repo", self.tag, self.asset, folder)
                self.asset["size"] = 8
                with self.assertRaises(ValueError):
                    release.download_asset("owner/repo", self.tag, self.asset, folder)

    def test_missing_or_changed_indexed_asset_fails_closed(self):
        with self.assertRaises(ValueError):
            self.detect(None, self.index)
        self.asset["digest"] = "sha256:" + "b" * 64
        with self.assertRaises(ValueError):
            self.detect(self.current, self.index)

    def test_zero_byte_upload_placeholder_is_recoverable(self):
        self.asset.update(state="starter", size=0)
        self.assertEqual(self.detect(self.current)["action"], "build")

    def test_digest_null_is_absent_not_a_hash(self):
        self.assertIsNone(release.digest_of({"digest": None}))
        self.assertIsNone(release.digest_of({}))
        with self.assertRaises(ValueError):
            release.digest_of({"digest": "null"})

    def test_non_404_errors_are_not_treated_as_missing_release(self):
        for code in (403, 429, 500, 504):
            with patch.object(release.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "", f"(HTTP {code})")):
                with self.assertRaises(RuntimeError):
                    release.api("fixture", optional=True)
        with patch.object(release.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "", "(HTTP 404)")):
            self.assertIsNone(release.api("fixture", optional=True))

    def test_latest_filters_special_and_prerelease_versions(self):
        versions = [{"tag_name": tag, "draft": False, "prerelease": pre} for tag, pre in
                    [("v0.9.6", False), ("v0.9.7-drama", False), ("v0.9.8", True), ("v0.9.5", False)]]
        with patch.object(release, "api", side_effect=[[versions], {}, [[]]]):
            result = release.detect("owner/repo", "", "false", [], {}, "sha")
        self.assertEqual(result["base"], "0.9.6")

    def test_published_asset_is_never_uploaded_again(self):
        with patch.object(release, "release", return_value=self.current), patch.object(release.subprocess, "run") as run:
            release.publish("owner/repo", self.tag, "sha", Path("missing"))
            run.assert_not_called()


class Downloads(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.content = b"GGUF" + b"verified model content" * 8
        cls.requests = []
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                cls.requests.append((self.path, self.headers.get("Range")))
                if self.path.startswith("/missing/"):
                    self.send_error(404)
                    return
                body = b"<html>not a model</html>" if self.path.startswith("/html/") else cls.content
                start = int(self.headers["Range"][6:-1]) if self.headers.get("Range") else 0
                self.send_response(206 if start else 200)
                if start:
                    self.send_header("Content-Range", f"bytes {start}-{len(body)-1}/{len(body)}")
                self.send_header("Content-Length", str(len(body) - start))
                self.end_headers()
                self.wfile.write(body[start:])
            def log_message(self, *args):
                pass
        cls.http = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        cls.thread = threading.Thread(target=cls.http.serve_forever, daemon=True)
        cls.thread.start()
        cls.base = f"http://127.0.0.1:{cls.http.server_port}"

    @classmethod
    def tearDownClass(cls):
        cls.http.shutdown()
        cls.http.server_close()
        cls.thread.join()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / "bin").mkdir()
        (self.root / "etc").mkdir()
        self.dest = self.root / "models/model.gguf"
        self.spec = {"filename": "model.gguf", "size": len(self.content),
                     "sha256": hashlib.sha256(self.content).hexdigest(), "hf": "model", "modelscope": "model"}
        (self.root / "etc/models.lock.json").write_text(json.dumps({"cosyvoice3": self.spec}))
        self.config = self.root / "server.json"
        self.config.write_text(json.dumps({"models_root": "unused-root", "models": [
            {"family": "cosyvoice3", "path": "models/model.gguf"}]}))
        self.env = {"AUDIOCPP_MODEL_SOURCE": "modelscope", "AUDIOCPP_MS_BASE_URL": self.base + "/ok",
                    "AUDIOCPP_HF_BASE_URL": self.base + "/ok", "AUDIOCPP_HF_MIRROR_BASE_URL": self.base + "/ok"}
        self.requests.clear()

    def run_download(self):
        with patch.dict(os.environ, self.env):
            return models.provision(self.config, self.root / "bin", self.root / "logs")

    def test_download_and_verified_skip(self):
        self.assertEqual(self.run_download(), 0)
        self.assertEqual(self.dest.read_bytes(), self.content)
        self.requests.clear()
        self.assertEqual(self.run_download(), 0)
        self.assertEqual(self.requests, [])

    def test_zero_byte_file_is_replaced(self):
        self.dest.parent.mkdir()
        self.dest.touch()
        self.assertEqual(self.run_download(), 0)
        self.assertEqual(self.dest.read_bytes(), self.content)

    def test_html_response_fails_and_preserves_original(self):
        self.env.update({key: self.base + "/html" for key in self.env if key.endswith("BASE_URL")})
        self.dest.parent.mkdir()
        self.dest.write_bytes(b"old damaged file")
        self.assertEqual(self.run_download(), 1)
        self.assertEqual((self.root / "logs/model-download.status").read_text().strip(), "failed")
        self.assertEqual(self.dest.read_bytes(), b"old damaged file")

    def test_cross_source_partial_never_mixes(self):
        self.dest.parent.mkdir()
        url = self.base + "/missing/model"
        identity = hashlib.sha256((url + self.spec["sha256"]).encode()).hexdigest()[:20]
        self.dest.with_name(self.dest.name + "." + identity + ".part").write_bytes(b"GGUFOLD!")
        self.dest.with_suffix(".gguf.part").write_bytes(b"legacy partial")
        self.env["AUDIOCPP_MS_BASE_URL"] = self.base + "/missing"
        self.assertEqual(self.run_download(), 0)
        self.assertEqual(self.dest.read_bytes(), self.content)
        self.assertIn(("/missing/model", "bytes=8-"), self.requests)
        self.assertIn(("/ok/model", None), self.requests)

    def test_same_source_resume_is_verified(self):
        self.dest.parent.mkdir()
        identity = hashlib.sha256((self.base + "/ok/model" + self.spec["sha256"]).encode()).hexdigest()[:20]
        partial = self.dest.with_name(self.dest.name + "." + identity + ".part")
        partial.write_bytes(self.content[:8])
        self.assertEqual(self.run_download(), 0)
        self.assertIn(("/ok/model", "bytes=8-"), self.requests)

    def test_all_sources_missing_returns_failure(self):
        self.env.update({key: self.base + "/missing" for key in self.env if key.endswith("BASE_URL")})
        self.assertEqual(self.run_download(), 1)

    def test_lock_does_not_overwrite_other_task_status(self):
        (self.root / "logs").mkdir()
        (self.root / "logs/model-download.status").write_text("running\n")
        with (self.root / ".model-download.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertEqual(self.run_download(), 75)
        self.assertEqual((self.root / "logs/model-download.status").read_text(), "running\n")

    def test_custom_filename_is_not_downloaded_as_default(self):
        self.config.write_text(json.dumps({"models": [{"family": "cosyvoice3", "path": "custom.gguf"}]}))
        self.assertEqual(self.run_download(), 1)
        self.assertEqual(self.requests, [])
        self.assertFalse((self.root / "custom.gguf").exists())


class Lifecycle(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="audiocpp test '")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        shutil.copytree(ROOT / "app/cmd", self.root / "cmd")
        shutil.copytree(ROOT / "payload", self.root / "target")
        for folder in ("etc", "var", "shares/audiocpp/logs", "target/assets/demo_voices", "target/assets/silero_vad"):
            (self.root / folder).mkdir(parents=True, exist_ok=True)
        for name in ("demo_1_man.wav", "demo_2_man.wav", "demo_3_woman.wav", "demo_4_woman.wav", "prompt_text"):
            (self.root / "target/assets/demo_voices" / name).write_bytes(b"fixture")
        (self.root / "target/assets/silero_vad/silero_vad_16k.safetensors").write_bytes(b"fixture")
        self.user = pwd.getpwuid(os.getuid()).pw_name
        (self.root / "etc/runtime.json").write_text(json.dumps({"username": self.user,
                                                               "data_root": str(self.root / "shares/audiocpp")}))
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("TRIM_")}
        with patch.dict(os.environ, self.env, clear=True):
            self.p = service.paths(self.root)

    def cmd(self, action):
        return subprocess.run(["bash", str(self.root / "cmd/main"), action], env=self.env,
                              capture_output=True, text=True, timeout=30)

    def install(self):
        with patch.object(service.subprocess, "Popen") as popen:
            result = service.install(self.p)
            self.assertEqual(result, 0)
            return popen.call_args.args[0]

    def test_ssh_status_needs_no_trim_environment(self):
        self.assertEqual(self.cmd("status").returncode, 3)

    def test_old_config_migrates_relative_paths(self):
        config = {"host": "127.0.0.1", "models_root": "../models", "voice_dir": "voices", "models": [
            {"family": "custom", "path": "custom.gguf", "voice_presets": {"a": {"voice_ref": "voice.wav"}}}]}
        old = self.root / "etc/server.json"
        old.write_text(json.dumps(config))
        self.install()
        active = json.loads((self.p["data"] / "server.json").read_text())
        self.assertEqual(active["models"][0]["path"], str(self.root / "etc/custom.gguf"))
        self.assertEqual(active["models"][0]["voice_presets"]["a"]["voice_ref"], str(self.root / "etc/voice.wav"))
        self.assertEqual(json.loads(old.read_text()), config)
        self.assertEqual(active["host"], "127.0.0.1")

    def test_existing_shared_config_is_byte_preserved(self):
        path = self.p["data"] / "server.json"
        original = '{ "models": [], "custom": "保留配置" }\n'
        path.write_text(original)
        self.install()
        self.assertEqual(path.read_text(), original)

    def test_render_escapes_special_path_and_defaults(self):
        self.install()
        config = json.loads((self.p["data"] / "server.json").read_text())
        self.assertEqual(config["models_root"], str(self.p["data"] / "models"))
        self.assertFalse(config["models"][1]["default_request_options"]["keep_tags"])

    def test_install_io_failure_does_not_launch_download(self):
        p = dict(self.p)
        blocker = self.root / "blocker"
        blocker.write_text("file")
        p["data"] = blocker / "data"
        with patch.object(service.subprocess, "Popen") as popen, self.assertRaises(OSError):
            service.install(p)
        popen.assert_not_called()

    def test_install_and_manual_download_share_logs(self):
        args = self.install()
        self.assertEqual(args[-1], str(self.p["data"] / "logs"))
        (self.p["dest"] / "bin/provision-models.py").write_text("import sys; print(sys.argv[-1])\n")
        result = self.cmd("download-models")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(self.p["data"] / "logs"))

    def test_unrelated_pid_is_not_running_or_killed(self):
        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
        try:
            (self.p["var"] / "audiocpp.pid").write_text(json.dumps({"pid": child.pid, "identity": service.process_identity(child.pid)}))
            self.assertEqual(self.cmd("status").returncode, 3)
            self.assertEqual(self.cmd("stop").returncode, 0)
            self.assertIsNone(child.poll())
        finally:
            child.terminate()
            child.wait()

    def test_stale_start_time_never_matches(self):
        (self.p["var"] / "audiocpp.pid").write_text(json.dumps({"pid": os.getpid(), "identity": ["wrong", "boot"]}))
        self.assertFalse(service.running(self.p))

    def test_missing_runtime_asset_blocks_install(self):
        (self.p["dest"] / "assets/demo_voices/demo_3_woman.wav").unlink()
        with patch.object(service.subprocess, "Popen") as popen, self.assertRaises(FileNotFoundError):
            service.install(self.p)
        popen.assert_not_called()

    def test_download_error_exit_reaches_ssh_caller(self):
        (self.p["dest"] / "bin/provision-models.py").write_text("import sys; sys.exit(75)\n")
        self.assertEqual(self.cmd("download-models").returncode, 75)

    def test_upgrade_stops_downloader_and_child_only(self):
        ready = self.root / "child.pid"
        script = self.p["dest"] / "bin/provision-models.py"
        script.write_text("import pathlib, subprocess, sys, time\n"
                          "child=subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'])\n"
                          f"pathlib.Path({str(ready)!r}).write_text(str(child.pid))\n"
                          "time.sleep(60)\n")
        child = subprocess.Popen([sys.executable, str(script)])
        unrelated = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
        fd = None
        try:
            deadline = time.monotonic() + 5
            while not ready.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(ready.exists())
            fd = os.pidfd_open(int(ready.read_text()))
            result = subprocess.run(["bash", str(self.root / "cmd/upgrade_init")], env=self.env,
                                    capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            child.wait(timeout=5)
            self.assertTrue(select.select([fd], [], [], 0)[0])
            self.assertIsNone(unrelated.poll())
        finally:
            if child.poll() is None:
                child.terminate()
            child.wait()
            unrelated.terminate()
            unrelated.wait()
            if fd is not None:
                if not select.select([fd], [], [], 0)[0]:
                    signal.pidfd_send_signal(fd, signal.SIGTERM)
                os.close(fd)

    def test_start_stop_and_log_capture(self):
        binary = self.p["dest"] / "bin/audiocpp_server"
        binary.write_text(f"#!{sys.executable}\nimport time\nprint('fixture server started', flush=True)\ntime.sleep(90)\n")
        binary.chmod(0o755)
        (self.p["data"] / "server.json").write_text('{"models": []}')
        try:
            result = self.cmd("start")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.cmd("status").returncode, 0)
            self.assertEqual(self.cmd("start").returncode, 0)
            self.assertIn("fixture server started", (self.p["data"] / "logs/server.log").read_text())
        finally:
            self.cmd("stop")
        self.assertEqual(self.cmd("status").returncode, 3)


class Moo(unittest.TestCase):
    def test_idempotence_and_immutable_versions(self):
        with tempfile.TemporaryDirectory() as tmp:
            temp = Path(tmp)
            index = temp / "moo.json"
            data = json.loads((ROOT / "moo.json").read_text())
            data["apps"]["audiocpp"]["releases"] = {}
            data["apps"]["audiocpp"].pop("version", None)
            index.write_text(json.dumps(data))
            fpk = temp / "test.fpk"
            def write_fpk(version, extra=""):
                content = f"appname = audiocpp\nversion = {version}\nplatform = x86\n{extra}".encode()
                with tarfile.open(fpk, "w:gz") as archive:
                    item = tarfile.TarInfo("manifest")
                    item.size = len(content)
                    archive.addfile(item, io.BytesIO(content))
            def update():
                return subprocess.run([sys.executable, str(ROOT / "tools/update_moo_json.py"), "--file", str(index),
                                       "--repo", "owner/repo", "--tag", "v0.9.5-000", "--fpk", str(fpk)],
                                      text=True, capture_output=True)
            write_fpk("0.9.5-000")
            self.assertEqual(update().returncode, 0)
            original = index.read_bytes()
            self.assertEqual(update().returncode, 0)
            self.assertEqual(index.read_bytes(), original)
            write_fpk("0.9.5-000", "description=changed\n")
            self.assertNotEqual(update().returncode, 0)
            self.assertEqual(index.read_bytes(), original)
            write_fpk("0.9.4-999")
            self.assertNotEqual(update().returncode, 0)
            self.assertEqual(index.read_bytes(), original)


class Syntax(unittest.TestCase):
    def test_shell_and_json(self):
        for folder in ("app/cmd", "scripts", "payload/bin"):
            for path in (ROOT / folder).iterdir():
                if path.is_file() and path.read_bytes().startswith((b"#!/bin/bash", b"#!/usr/bin/env bash")):
                    subprocess.run(["bash", "-n", str(path)], check=True)
        for path in list((ROOT / "payload/etc").iterdir()) + [ROOT / "moo.json", ROOT / "app/config/privilege", ROOT / "app/config/resource"]:
            json.loads(path.read_text())

    def test_required_stage_assets_fail_closed(self):
        with tempfile.TemporaryDirectory() as tmp, self.assertRaises(ValueError):
            check_payload.check_stage(Path(tmp))

    def test_archive_traversal_is_rejected(self):
        with tempfile.TemporaryFile() as stream:
            with tarfile.open(fileobj=stream, mode="w") as archive:
                item = tarfile.TarInfo("../escape")
                archive.addfile(item, io.BytesIO())
            stream.seek(0)
            with tarfile.open(fileobj=stream) as archive, self.assertRaises(ValueError):
                check_payload.archive_members(archive)


if __name__ == "__main__":
    unittest.main()
