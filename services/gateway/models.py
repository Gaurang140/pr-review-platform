from pydentic_settings import BaseSettings

class settings(BaseSettings):
    github_webhook_secret: str = ""

    class Config:
        env_file = ".env"