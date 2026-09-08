from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, HttpUrl
from urllib.parse import urlparse

app = FastAPI(title='Music Collecter API', version='1.0.0')

class AnalyzeRequest(BaseModel):
    url: HttpUrl

@app.get('/health')
def health():
    return {'status': 'ok', 'service': 'music-collecter'}

@app.post('/analyze')
def analyze(request: AnalyzeRequest):
    parsed = urlparse(str(request.url))
    host = parsed.netloc.lower()
    # This endpoint intentionally does not extract protected YouTube media.
    # Adapters can be added for sources that explicitly permit downloading.
    return {
        'url': str(request.url),
        'host': host,
        'supported': False,
        'message': 'No protected-source downloader is enabled. Use an authorized media source adapter.'
    }

@app.post('/download')
def download():
    raise HTTPException(status_code=501, detail='Downloading is available only through authorized source adapters.')
