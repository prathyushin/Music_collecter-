from __future__ import annotations

import os
import re
from pathlib import Path
from urllib.parse import unquote, urlparse

import httpx
from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from pydantic import BaseModel, HttpUrl

app = FastAPI(title="Music Collecter API", version="1.2.1")
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
    "audio/webm": ".webm",
}

PROTECTED_PLATFORM_HOSTS = {
    "youtube.com",
    "www.youtube.com",
    "m.youtube.com",
    "music.youtube.com",
    "youtu.be",
    "www.youtu.be",
}


class UrlRequest(BaseModel):
    url: HttpUrl


class DownloadResponse(BaseModel):
    status: str
    filename: str
    size: int
    content_type: str
    download_url: str


def safe_filename(value: str, fallback: str = "track") -> str:
    value = unquote(value).strip()
    value = re.sub(r"[\\/:*?\"<>|\x00-\x1f]", "_", value)
    value = re.sub(r"\s+", " ", value).strip(" .")
    return value[:180] or fallback


def validate_source(url: str) -> None:
    parsed = urlparse(url)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise HTTPException(status_code=400, detail="Only valid HTTP(S) media URLs are supported.")


def is_protected_platform(url: str) -> bool:
    host = urlparse(url).hostname or ""
    return host.lower().rstrip(".") in PROTECTED_PLATFORM_HOSTS


def media_suffix(content_type: str, url: str) -> str | None:
    suffix = AUDIO_TYPES.get(content_type.lower())
    if suffix:
        return suffix
    candidate = Path(urlparse(url).path).suffix.lower()
    return candidate if candidate in AUDIO_TYPES.values() else None


def unique_target(stem: str, suffix: str) -> Path:
    target = DOWNLOAD_ROOT / f"{stem}{suffix}"
    counter = 1
    while target.exists():
        target = DOWNLOAD_ROOT / f"{stem} ({counter}){suffix}"
        counter += 1
    return target


@app.get("/health")
def health():
    return {"status": "ok", "service": "music-collecter", "version": app.version}


@app.post("/analyze")
async def analyze(request: UrlRequest):
    url = str(request.url)
    validate_source(url)

    if is_protected_platform(url):
        return {
            "url": url,
            "resolved_url": url,
            "host": urlparse(url).netloc,
            "content_type": "protected-platform-page",
            "size": None,
            "extension": None,
            "supported": False,
            "message": "This platform page is not a direct audio resource. Use an official or authorized download source instead.",
        }

    try:
        async with httpx.AsyncClient(follow_redirects=True, timeout=15) as client:
            response = await client.head(url)
            if response.status_code in {405, 501}:
                response = await client.get(url, headers={"Range": "bytes=0-0"})
            response.raise_for_status()
            content_type = response.headers.get("content-type", "").split(";", 1)[0].lower()
            length = response.headers.get("content-length")
            suffix = media_suffix(content_type, str(response.url))

        supported = suffix is not None
        return {
            "url": url,
            "resolved_url": str(response.url),
            "host": urlparse(str(response.url)).netloc,
            "content_type": content_type or "unknown",
            "size": int(length) if length and length.isdigit() else None,
            "extension": suffix,
            "supported": supported,
            "message": "Direct audio media is ready to download." if supported else "The URL does not identify an authorized direct audio resource.",
        }
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=502, detail=f"Unable to inspect URL: {exc}") from exc


@app.post("/download", response_model=DownloadResponse)
async def download(request: UrlRequest):
    url = str(request.url)
    validate_source(url)
    if is_protected_platform(url):
        raise HTTPException(status_code=403, detail="Protected platform pages cannot be downloaded by this service.")

    temporary: Path | None = None
    try:
        async with httpx.AsyncClient(follow_redirects=True, timeout=None) as client:
            async with client.stream("GET", url) as response:
                response.raise_for_status()
                content_type = response.headers.get("content-type", "").split(";", 1)[0].lower()
                resolved_url = str(response.url)
                suffix = media_suffix(content_type, resolved_url)
                if suffix is None:
                    raise HTTPException(status_code=415, detail="The URL is not a supported direct audio resource.")

                name = Path(unquote(urlparse(resolved_url).path)).name
                stem = safe_filename(Path(name).stem if name else "track")
                target = unique_target(stem, suffix)
                temporary = target.with_name(f".{target.name}.part")

                size = 0
                with temporary.open("wb") as output:
                    async for chunk in response.aiter_bytes(1024 * 1024):
                        output.write(chunk)
                        size += len(chunk)
                temporary.replace(target)

        return DownloadResponse(
            status="completed",
            filename=target.name,
            size=size,
            content_type=content_type,
            download_url=f"/files/{target.name}",
        )
    except HTTPException:
        if temporary and temporary.exists():
            temporary.unlink(missing_ok=True)
        raise
    except (httpx.HTTPError, OSError) as exc:
        if temporary and temporary.exists():
            temporary.unlink(missing_ok=True)
        raise HTTPException(status_code=502, detail=f"Download failed: {exc}") from exc


@app.get("/files/{filename}")
def get_file(filename: str):
    safe = safe_filename(filename)
    target = (DOWNLOAD_ROOT / safe).resolve()
    if target.parent != DOWNLOAD_ROOT or not target.is_file():
        raise HTTPException(status_code=404, detail="File not found.")
    return FileResponse(target)
