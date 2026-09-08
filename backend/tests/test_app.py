from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


def test_health():
    response = client.get('/health')
    assert response.status_code == 200
    assert response.json()['status'] == 'ok'


def test_invalid_url_is_rejected():
    response = client.post('/analyze', json={'url': 'not-a-url'})
    assert response.status_code == 422


def test_protected_source_is_not_supported():
    response = client.post('/analyze', json={'url': 'https://music.youtube.com/watch?v=example'})
    assert response.status_code == 200
    assert response.json()['supported'] is False
