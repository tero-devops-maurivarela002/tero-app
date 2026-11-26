import time
from contextlib import asynccontextmanager

from fastapi import FastAPI
from prometheus_fastapi_instrumentator import Instrumentator
from app.config import settings
from app.router import router
from app import jsonlog

jsonlog.configure()


# "lifespan" reemplaza a @app.on_event("startup"), que está deprecado desde
# que se actualizó FastAPI/Starlette por las vulnerabilidades de DEVOPS-32.
@asynccontextmanager
async def lifespan(app: FastAPI):
    if settings.cart_persistence_provider == "postgres":
        from app.postgres_service import PostgresCartService
        app.state.cart_service = PostgresCartService()
    else:
        from app.service import InMemoryCartService
        app.state.cart_service = InMemoryCartService()
    yield


app = FastAPI(title="Cart Service", lifespan=lifespan)


@app.middleware("http")
async def json_access_log(request, call_next):
    start = time.perf_counter()
    response = await call_next(request)
    jsonlog.log_request(request.method, request.url.path, response.status_code,
                        (time.perf_counter() - start) * 1000)
    return response


@app.get("/topology")
def topology():
    return {"provider": settings.cart_persistence_provider}


@app.get("/health")
def health():
    return {"status": "UP"}


app.include_router(router)
Instrumentator().instrument(app).expose(app, endpoint="/metrics")
