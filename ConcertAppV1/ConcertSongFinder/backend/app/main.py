import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from app.config import get_settings
from app.routes import concerts, lyrics, setlists
from app.services import http_client

logger = logging.getLogger("concert_song_finder.app")
settings = get_settings()


@asynccontextmanager
async def lifespan(_: FastAPI):
    yield
    await http_client.close_shared_client()


app = FastAPI(title="ConcertSongFinder Backend", version="0.1.0", lifespan=lifespan)
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
async def health() -> dict:
    return {"status": "ok"}


@app.exception_handler(HTTPException)
async def http_error(_: Request, exc: HTTPException) -> JSONResponse:
    # Normalize every HTTP error to the flat {"code", "message"} contract
    # instead of FastAPI's default {"detail": ...} envelope.
    detail = exc.detail
    if isinstance(detail, dict) and "code" in detail:
        content = detail
    else:
        content = {
            "code": "backend_error",
            "message": str(detail) if detail else "The backend could not complete the request.",
        }
    return JSONResponse(status_code=exc.status_code, content=content)


@app.exception_handler(Exception)
async def unhandled_error(request: Request, exc: Exception) -> JSONResponse:
    # Log the traceback for observability, but never echo raw media,
    # transcripts, lyrics, or provider keys back to the client.
    logger.exception("Unhandled backend error on %s %s", request.method, request.url.path)
    return JSONResponse(
        status_code=500,
        content={"code": "backend_error", "message": "The backend could not complete the request."},
    )
