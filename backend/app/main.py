from __future__ import annotations

import os
import re
from pathlib import Path
from urllib.parse import urlparse, unquote

import httpx
from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from pydantic import BaseModel, HttpUrl

app = FastAPI(title="Music Collecter API", version="1.1.0")
DOWNLOAD_ROOT = Path(os.getenv("MUSIC_COLLECTER_DOWNLOADS", "downloads")).resolve()
DOWNLOAD_ROOT.mkdir(parents=True, exist_ok=True)

AUDIO_TYPES = {
    "audio/mpeg": ".mp3",
    "audio/mp4": ".m4a",
    "audio/x-m4a": ".m4a",
    "audio/aac": ".aac",
    "audio/ogg": ".ogg",
    "audio/flac": ".flac",
    "audio/wav": ".wav",
    "audio/x-wav": ".wav",
}


class UrlRequest(BaseModel):
    url: HttpUrl


class DownloadResponse(BaseModel):
    status: str
    filename: str
    size: int
    content_type: str


def safe_filename(value: str, fallback: str = "track") -> str:
    value = unquote(value).strip()
    value = re.sub(r"[\\/:*?\"<>|\x00-\x1f]", "_", value)
    value = re.sub(r"\s+", " ", value).strip(" .")
    return value[:180] or fallback


def validate_source(url: str) -> None:
    parsed = urlparse(url)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise HTTPException(status_code=400, detail="Only valid HTTP(S) media URLs are supported.")


@app.get("/health")
def health():
    return {"status": "ok", "service": "music-collecter", "version": "1.1.0"}


@app.post("/analyze")
async def analyze(request: UrlRequest):
    url = str(request.url)
    validate_source(url)
    try:
        async with httpx.AsyncClient(follow_redirects=True, timeout=15) as client:
            response = await client.head(url)
            content_type = response.headers.get("content-type", "").split(";", 1)[0].lower()
            length = response.headers.get("content-length")
        supported = content_type in AUDIO_TYPES or Path(urlparse(url).path).suffix.lower() in AUDIO_TYPES.values()
        return {
            "url": url,
            "host": urlparse(url).netloc,
            "content_type": content_type or "unknown",
            "size": int(length) if length and length.isdigit() else None,
            "supported": supported,
            "message": "Direct audio media is ready to download." if supported else "The URL does not identify an authorized direct audio resource.",
        }
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=502, detail=f"Unable to inspect URL: {exc}") from exc


@app.post("/download", response_model=DownloadResponse)
async def download(request: UrlRequest):
    url = str(request.url)
    validate_source(url)
    try:
        async with httpx.AsyncClient(follow_redirects=True, timeout=None) as client:
            async with client.stream("GET", url) as response:
                response.raise_for_status()
                content_type = response.headers.get("content-type", "").split(";", 1)[0].lower()
                suffix = AUDIO_TYPES.get(content_type) or Path(urlparse(str(response.url)).path).suffix.lower()
                if suffix not in AUDIO_TYPES.values():
                    raise HTTPException(status_code=415, detail="The URL is not a supported direct audio resource.")

                name = Path(unquote(urlparse(str(response.url)).path)).name
                stem = safe_filename(Path(name).stem if name else "track")
                filename = f"{stem}{suffix}"
                target = DOWNLOAD_ROOT / filename
                counter = 1
                while target.exists():
                    target = DOWNLOAD_ROOT / f"{stem} ({counter}){suffix}"
                    counter += 1

                size = 0
                with target.open("wb") as output:
                    async for chunk in response.aiter_bytes(1024 * 1024):
                        output.write(chunk)
                        size += len(chunk)

        return DownloadResponse(status="completed", filename=target.name, size=size, content_type=content_type)
    except HTTPException:
        raise
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=502, detail=f"Download failed: {exc}") from exc


@app.get("/files/{filename}")
def get_file(filename: str):
    safe = safe_filename(filename)
    target = (DOWNLOAD_ROOT / safe).resolve()
    if target.parent != DOWNLOAD_ROOT or not target.is_file():
        raise HTTPException(status_code=404, detail="File not found.")
    return FileResponse(target)
