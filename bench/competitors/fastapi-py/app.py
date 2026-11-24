"""FastAPI contender: strict Pydantic model, 201 created, 400 mapped."""

from fastapi import Depends, FastAPI, Request, Response
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse, PlainTextResponse
from pydantic import BaseModel, Field, StrictBool, StrictInt, StrictStr

app = FastAPI(openapi_url=None, docs_url=None, redoc_url=None)


class CreateUser(BaseModel):
    name: StrictStr = Field(min_length=1)
    age: StrictInt
    active: StrictBool


@app.exception_handler(RequestValidationError)
async def validation_400(request: Request, exc: RequestValidationError):
    return PlainTextResponse("Bad Request", status_code=400)


@app.get("/plaintext", response_class=PlainTextResponse)
async def plaintext():
    return "Hello, World!"


@app.get("/json")
async def json_msg():
    return {"message": "Hello, World!"}


def frame_bench_hook(response: Response):
    response.headers["X-Frame-Bench"] = "1"
@app.get("/users/{uid}", dependencies=[Depends(frame_bench_hook)])
async def get_user(uid: str, role: str = ""):
    # NOTE: return a dict (not JSONResponse) so the dependency-injected
    # response carrying X-Frame-Bench is the one actually sent.
    return {"id": uid, "role": role}


@app.post("/users", status_code=201)
async def create_user(u: CreateUser):
    return {"created": True, "name": u.name, "age": u.age}
