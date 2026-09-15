from __future__ import annotations

import ipaddress
import re
import socket
from pathlib import Path
from urllib.parse import unquote, urljoin, urlparse

import httpx
from fastapi import FastAPI, HTTPException
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, HttpUrl

app = FastAPI(title="Music Collecter API", version="2.0.0")

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
    "youtube.com", "www.youtube.com", "m.youtube.com",
    "music.youtube.com", "youtu.be", "www.youtu.be",
}
MAX_DOWNLOAD_BYTES = 100 * 1024 * 1024
MAX_REDIRECTS = 4


class UrlRequest(BaseModel):
    url: HttpUrl


def safe_filename(value: str, fallback: str = "track") -> str:
    value = unquote(value).strip()
    value = re.sub(r"[\\/:*?\"<>|\x00-\x1f]", "_", value)
    value = re.sub(r"\s+", " ", value).strip(" .")
    return value[:180] or fallback


def validate_url(url: str) -> None:
    parsed = urlparse(url)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        raise HTTPException(status_code=400, detail="Only valid HTTP(S) media URLs are supported.")
    host = parsed.hostname.lower().rstrip(".")
    if host in {"localhost", "localhost.localdomain"}:
        raise HTTPException(status_code=400, detail="Local network addresses are not supported.")
    try:
        addresses = {item[4][0] for item in socket.getaddrinfo(host, parsed.port or (443 if parsed.scheme == "https" else 80), type=socket.SOCK_STREAM)}
    except OSError as exc:
        raise HTTPException(status_code=502, detail="The source host could not be resolved.") from exc
    for address in addresses:
        ip = ipaddress.ip_address(address)
        if ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_multicast or ip.is_reserved or ip.is_unspecified:
            raise HTTPException(status_code=400, detail="Private or local network sources are not supported.")


def is_protected_platform(url: str) -> bool:
    host = urlparse(url).hostname or ""
    return host.lower().rstrip(".") in PROTECTED_PLATFORM_HOSTS


def media_suffix(content_type: str, url: str) -> str | None:
    suffix = AUDIO_TYPES.get(content_type.lower())
    if suffix:
        return suffix
    candidate = Path(urlparse(url).path).suffix.lower()
    return candidate if candidate in AUDIO_TYPES.values() else None


def filename_from_url(url: str, suffix: str) -> str:
    name = Path(unquote(urlparse(url).path)).name
    stem = Path(name).stem if name else "track"
    return safe_filename(stem) + suffix


@app.get("/health")
def health():
    return {"status": "ok", "service": "music-collecter", "version": app.version}


@app.post("/analyze")
async def analyze(request: UrlRequest):
    original = str(request.url)
    validate_url(original)
    if is_protected_platform(original):
        return {"supported": False, "message": "This platform page is not a direct audio resource. Use an official or authorized download source instead."}

    current = original
    try:
        async with httpx.AsyncClient(timeout=httpx.Timeout(15.0, connect=8.0), follow_redirects=False) as client:
            for _ in range(MAX_REDIRECTS + 1):
                validate_url(current)
                response = await client.head(current)
                if response.status_code in {301, 302, 303, 307, 308}:
                    location = response.headers.get("location")
                    if not location:
                        raise HTTPException(status_code=502, detail="Source returned an invalid redirect.")
                    current = urljoin(current, location)
                    continue
                if response.status_code in {405, 501}:
                    response = await client.get(current, headers={"Range": "bytes=0-0"})
                response.raise_for_status()
                content_type = response.headers.get("content-type", "").split(";", 1)[0].lower()
                suffix = media_suffix(content_type, str(response.url))
                length = response.headers.get("content-length")
                supported = suffix is not None and (not length or int(length) <= MAX_DOWNLOAD_BYTES)
                return {
                    "url": original,
                    "resolved_url": str(response.url),
                    "content_type": content_type or "unknown",
                    "size": int(length) if length and length.isdigit() else None,
                    "extension": suffix,
                    "supported": supported,
                    "message": "Direct audio media is ready to download." if supported else "Only direct authorized audio files up to 100 MB are supported.",
                }
            raise HTTPException(status_code=508, detail="Too many redirects.")
    except HTTPException:
        raise
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=502, detail=f"Unable to inspect URL: {exc}") from exc


@app.post("/download")
async def download(request: UrlRequest):
    original = str(request.url)
    validate_url(original)
    if is_protected_platform(original):
        raise HTTPException(status_code=403, detail="Protected platform pages cannot be downloaded by this service.")

    client = httpx.AsyncClient(timeout=httpx.Timeout(None, connect=15.0), follow_redirects=False)
    current = original
    response: httpx.Response | None = None
    try:
        for _ in range(MAX_REDIRECTS + 1):
            validate_url(current)
            response = await client.send(httpx.Request("GET", current), stream=True)
            if response.status_code in {301, 302, 303, 307, 308}:
                location = response.headers.get("location")
                await response.aclose()
                if not location:
                    raise HTTPException(status_code=502, detail="Source returned an invalid redirect.")
                current = urljoin(current, location)
                continue
            response.raise_for_status()
            break
        else:
            raise HTTPException(status_code=508, detail="Too many redirects.")

        content_type = response.headers.get("content-type", "").split(";", 1)[0].lower()
        suffix = media_suffix(content_type, str(response.url))
        if suffix is None:
            raise HTTPException(status_code=415, detail="The URL is not a supported direct audio resource.")
        length = response.headers.get("content-length")
        if length and length.isdigit() and int(length) > MAX_DOWNLOAD_BYTES:
            raise HTTPException(status_code=413, detail="The media file is larger than the 100 MB limit.")

        filename = filename_from_url(str(response.url), suffix)

        async def stream_body():
            size = 0
            try:
                async for chunk in response.aiter_bytes(1024 * 1024):
                    size += len(chunk)
                    if size > MAX_DOWNLOAD_BYTES:
                        raise RuntimeError("The media file exceeded the 100 MB limit.")
                    yield chunk
            finally:
                await response.aclose()
                await client.aclose()

        return StreamingResponse(
            stream_body(),
            media_type=content_type,
            headers={
                "Content-Disposition": f'attachment; filename="{filename}"',
                "X-Music-Collecter-Filename": filename,
            },
        )
    except HTTPException:
        if response is not None:
            await response.aclose()
        await client.aclose()
        raise
    except (httpx.HTTPError, OSError) as exc:
        if response is not None:
            await response.aclose()
        await client.aclose()
        raise HTTPException(status_code=502, detail=f"Download failed: {exc}") from exc
