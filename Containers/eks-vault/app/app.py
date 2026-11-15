"""
Demo app: reads Postgres credentials from /vault/secrets/db-creds.txt and
executes a trivial query. The app has no Vault SDK; it just reads a file.
The file is written and refreshed by the Vault Agent sidecar.
"""
import os
from flask import Flask
import psycopg

SECRET_FILE = os.environ.get("DB_CREDS_FILE", "/vault/secrets/db-creds.txt")


def load_creds():
    creds = {}
    with open(SECRET_FILE) as f:
        for line in f:
            line = line.strip()
            if not line or "=" not in line:
                continue
            k, v = line.split("=", 1)
            creds[k] = v
    return creds


app = Flask(__name__)


@app.get("/")
def index():
    c = load_creds()
    with psycopg.connect(
        host=c["DB_HOST"],
        port=c["DB_PORT"],
        dbname=c["DB_NAME"],
        user=c["DB_USER"],
        password=c["DB_PASS"],
    ) as conn, conn.cursor() as cur:
        cur.execute("SELECT current_user, now();")
        row = cur.fetchone()
    return {"db_user": row[0], "db_time": row[1].isoformat()}


@app.get("/healthz")
def healthz():
    return {"ok": True}


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
