from pydantic import Field
from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    # BaseSettings moved to the separate pydantic-settings package in pydantic
    # 2, and env="..." was replaced by validation_alias.
    db_url: str = Field(..., validation_alias="DATABASE_URL")


settings = Settings()
