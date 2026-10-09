#!/usr/bin/env python3
"""Blind Apple Silicon render helper for QuackAPI shellfs read_json route.

Streaming-only policy (user critical):
  - Never land PNG under ~/ComfyUI/output (or any Mac path).
  - Comfy SaveImageWebsocket → binary frames over ws → image_b64 in JSON stdout.
  - path is always empty. No Mac temp PNG, no delete-after-read dance.
"""
from __future__ import annotations

import argparse
import base64
import json
import random
import subprocess
import sys
import time
import uuid
import urllib.request
from pathlib import Path

try:
    import websocket  # websocket-client
except ImportError:  # pragma: no cover
    websocket = None

COMFY_HOST = "127.0.0.1"
COMFY_PORT = 8188
COMFY_HTTP = f"http://{COMFY_HOST}:{COMFY_PORT}"
COMFY_WS = f"ws://{COMFY_HOST}:{COMFY_PORT}/ws"
COMFY_DIR = Path("/Users/aloksubbarao/ComfyUI")
LOG = Path("/tmp/comfyui.log")
DEFAULT_MODEL = "lustifySDXLNSFWSFW_v20.safetensors"
DEFAULT_ENGINE = "mps"
WS_NODE_ID = "save_image_websocket_node"


def b64_decode_text(s: str) -> str:
    return base64.b64decode(s.encode("ascii")).decode("utf-8") if s else ""


def emit(
    ok: bool,
    prompt_id: str | None,
    model: str,
    engine: str,
    image_b64: str | None,
    error: str | None,
    *,
    stream: str = "comfy_ws",
) -> None:
    sys.stdout.write(
        json.dumps(
            {
                "ok": bool(ok),
                "path": "",  # never persist on Mac
                "prompt_id": prompt_id or "",
                "model": model,
                "engine": engine,
                "image_b64": image_b64 or "",
                "error": error or "",
                "stream": stream,
                "policy": "stream-only: SaveImageWebsocket → image_b64; zero Mac disk write",
            },
            ensure_ascii=False,
            separators=(",", ":"),
        )
        + "\n"
    )


def http_json(method: str, url: str, body: dict | None = None, timeout: float = 30.0):
    data = None if body is None else json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={"Content-Type": "application/json"} if body is not None else {},
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read()
        if not raw:
            return None
        return json.loads(raw.decode("utf-8"))


def comfy_up() -> bool:
    for path in ("/system_stats", "/"):
        try:
            req = urllib.request.Request(COMFY_HTTP + path, method="GET")
            with urllib.request.urlopen(req, timeout=2) as resp:
                if 200 <= resp.status < 300:
                    return True
        except Exception:
            continue
    return False


def ensure_comfy() -> str | None:
    if comfy_up():
        return None
    # Do NOT mkdir output/quack — streaming path never uses it.
    (COMFY_DIR / "temp").mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [str(COMFY_DIR / ".venv/bin/python"), str(COMFY_DIR / "service/comfy-service.py"), "start"],
        check=True,
    )
    deadline = time.time() + 180
    while time.time() < deadline:
        if comfy_up():
            return None
        time.sleep(2)
    return f"render engine failed to become ready on :8188; see {LOG}"


def save_image_websocket_available() -> bool:
    try:
        info = http_json("GET", f"{COMFY_HTTP}/object_info/SaveImageWebsocket", timeout=5) or {}
        return "SaveImageWebsocket" in info
    except Exception:
        return False


def workflow(prompt: str, negative: str, width: int, height: int, steps: int, seed: int, model: str) -> dict:
    # SaveImageWebsocket streams PNG bytes over the client websocket — no disk write.
    return {
        "3": {
            "class_type": "KSampler",
            "inputs": {
                "cfg": 7,
                "denoise": 1,
                "latent_image": ["5", 0],
                "model": ["4", 0],
                "negative": ["7", 0],
                "positive": ["6", 0],
                "sampler_name": "euler",
                "scheduler": "normal",
                "seed": seed,
                "steps": steps,
            },
        },
        "4": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": model}},
        "5": {
            "class_type": "EmptyLatentImage",
            "inputs": {"batch_size": 1, "height": height, "width": width},
        },
        "6": {"class_type": "CLIPTextEncode", "inputs": {"clip": ["4", 1], "text": prompt}},
        "7": {"class_type": "CLIPTextEncode", "inputs": {"clip": ["4", 1], "text": negative}},
        "8": {"class_type": "VAEDecode", "inputs": {"samples": ["3", 0], "vae": ["4", 2]}},
        WS_NODE_ID: {
            "class_type": "SaveImageWebsocket",
            "inputs": {"images": ["8", 0]},
        },
    }


def stream_via_websocket(wf: dict, timeout: float = 240.0) -> tuple[str | None, bytes | None, str | None]:
    """Queue prompt and collect SaveImageWebsocket binary frames. Returns (prompt_id, png_bytes, error)."""
    if websocket is None:
        return None, None, "websocket-client not installed in render python"

    client_id = uuid.uuid4().hex
    ws = websocket.WebSocket()
    try:
        ws.settimeout(30)
        ws.connect(f"{COMFY_WS}?clientId={client_id}")
    except Exception as e:
        return None, None, f"ws connect failed: {e}"

    try:
        try:
            resp = http_json(
                "POST",
                f"{COMFY_HTTP}/prompt",
                {"prompt": wf, "client_id": client_id},
                timeout=60,
            )
        except Exception as e:
            return None, None, f"queue failed: {e}"

        prompt_id = (resp or {}).get("prompt_id")
        if not prompt_id:
            return None, None, f"queue failed: {resp}"

        png_chunks: list[bytes] = []
        current_node = ""
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                ws.settimeout(max(1.0, min(30.0, deadline - time.time())))
                out = ws.recv()
            except Exception as e:
                # transient timeout — keep waiting until overall deadline
                if "timed out" in str(e).lower() or "timeout" in str(e).lower():
                    continue
                return prompt_id, None, f"ws recv failed: {e}"

            if isinstance(out, str):
                try:
                    message = json.loads(out)
                except Exception:
                    continue
                mtype = message.get("type")
                data = message.get("data") or {}
                if mtype == "executing" and data.get("prompt_id") == prompt_id:
                    node = data.get("node")
                    if node is None:
                        break  # done
                    current_node = node
                elif mtype == "execution_error" and data.get("prompt_id") == prompt_id:
                    return prompt_id, None, f"comfy execution_error: {json.dumps(data)[:500]}"
            else:
                # Binary preview/save frame: 8-byte header then image bytes
                if current_node == WS_NODE_ID and isinstance(out, (bytes, bytearray)) and len(out) > 8:
                    png_chunks.append(bytes(out[8:]))

        if not png_chunks:
            return prompt_id, None, "timeout/no websocket image frames (SaveImageWebsocket)"
        # Last chunk is the final full image (Comfy may send progressive previews)
        return prompt_id, png_chunks[-1], None
    finally:
        try:
            ws.close()
        except Exception:
            pass


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--prompt-b64", default="")
    ap.add_argument("--negative-b64", default="")
    ap.add_argument("--width", type=int, default=1024)
    ap.add_argument("--height", type=int, default=1024)
    ap.add_argument("--steps", type=int, default=20)
    ap.add_argument("--seed", nargs="?", default="0", const="0")
    ap.add_argument("--model", default=DEFAULT_MODEL)
    ap.add_argument("--ckpt", default="")  # back-compat alias for --model
    ap.add_argument("--engine", default=DEFAULT_ENGINE)
    ap.add_argument("--return-b64", type=int, default=1)
    # --keep-file retained as no-op for back-compat; streaming policy forbids Mac files.
    ap.add_argument("--keep-file", type=int, default=0)
    ap.add_argument("--timeout", type=int, default=240)
    args = ap.parse_args()

    prompt = b64_decode_text(args.prompt_b64)
    negative = b64_decode_text(args.negative_b64)
    model = args.model or args.ckpt or DEFAULT_MODEL
    engine = args.engine or DEFAULT_ENGINE
    seed_s = str(args.seed or "").strip()
    if not seed_s or seed_s == "0":
        seed = random.randint(0, 2**31 - 1)
    else:
        try:
            seed = int(seed_s)
        except ValueError:
            seed = random.randint(0, 2**31 - 1)

    err = ensure_comfy()
    if err:
        emit(False, None, model, engine, None, err)
        return 0

    if not save_image_websocket_available():
        emit(
            False,
            None,
            model,
            engine,
            None,
            "SaveImageWebsocket node missing; refusing disk SaveImage path",
            stream="blocked",
        )
        return 0

    if args.keep_file:
        # Explicitly refuse — user policy: zero Mac disk for this path
        emit(
            False,
            None,
            model,
            engine,
            None,
            "--keep-file forbidden: stream-only policy (image_b64 only; land on box)",
            stream="blocked",
        )
        return 0

    wf = workflow(prompt, negative, args.width, args.height, args.steps, seed, model)
    prompt_id, png, err2 = stream_via_websocket(wf, timeout=float(args.timeout))
    if err2 or not png:
        emit(False, prompt_id, model, engine, None, err2 or "no image bytes")
        return 0

    image_b64 = base64.b64encode(png).decode("ascii") if args.return_b64 else ""
    if not image_b64:
        emit(False, prompt_id, model, engine, None, "return-b64 disabled but stream-only requires image_b64")
        return 0

    emit(True, prompt_id, model, engine, image_b64, None)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
