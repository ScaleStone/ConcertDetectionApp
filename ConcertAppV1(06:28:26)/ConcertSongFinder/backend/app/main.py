from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from app.config import get_settings
from app.routes import concerts, lyrics, setlists

settings = get_settings()

app = FastAPI(title="ConcertSongFinder Backend", version="0.1.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.origins,
    allow_credentials=False,
    allow_methods=["GET", "POST"],
    allow_headers=["*"],
)

app.include_router(concerts.router)
app.include_router(setlists.router)
app.include_router(lyrics.router)


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}


@app.exception_handler(Exception)
async def normalized_error(_: Request, exc: Exception) -> JSONResponse:
    # Avoid logging raw media, transcripts, lyrics, or provider keys here.
    status_code = getattr(exc, "status_code", 500)
    detail = getattr(exc, "detail", None)
    if isinstance(detail, dict):
        return JSONResponse(status_code=status_code, content=detail)
    return JSONResponse(
        status_code=status_code,
        content={"code": "backend_error", "message": "The backend could not complete the request."},
    )
