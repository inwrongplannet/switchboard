from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    # Provider keys (optional — prefer adding via Admin UI / DB)
    GROQ_API_KEY: str = ""
    GOOGLE_API_KEY: str = ""
    ANTHROPIC_API_KEY: str = ""

    # Redis
    REDIS_URL: str = "redis://localhost:6379/0"

    # Gateway
    PORT: int = 8000
    HOST: str = "0.0.0.0"

    # Router
    SWITCHBOARD_PROVIDER: str = "groq"

    # SQLite config store
    SQLITE_DB_PATH: str = "data/switchboard.db"

    # Fernet encryption key for API keys at rest
    # Generate with: python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
    ENCRYPTION_KEY: str = ""

    # Gateway auth. Both are comma-separated so a token can be rotated without
    # a coordinated cutover: add the new one, migrate callers, drop the old.
    # Empty means the gateway refuses to start — see gateway/auth.py.
    # Generate with: python -c "import secrets; print(secrets.token_urlsafe(32))"
    ADMIN_TOKENS: str = ""      # guards /admin/* and the OpenAPI docs routes
    CLIENT_TOKENS: str = ""     # guards /v1/*; admin tokens work here too

    class Config:
        env_file = ".env"
        extra = "allow"


settings = Settings()
