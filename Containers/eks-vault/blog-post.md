# Your App Doesn't Need to Know About Vault

### Dynamic Postgres credentials on EKS with the Vault Agent Injector

---

## The problem with the way we usually ship database credentials

The typical path for a service to get a database password on Kubernetes looks
something like this: someone creates a `Secret` with the password in it, mounts
it as an env var, the app reads `os.environ["DB_PASS"]`, and everyone moves on.

That single password then lives, unchanged, for the life of the service —
probably months, probably years. It is base64-encoded (not encrypted) in etcd.
Every pod that ever had it still *has* it, at least in logs, core dumps, and
developer laptops. Rotating it means a coordinated redeploy. Revoking it for
one misbehaving pod is impossible — the credential doesn't belong to the pod,
it belongs to the Kubernetes Secret.

We can do better. HashiCorp Vault's database secrets engine can mint a fresh,
short-lived Postgres user *per pod*, auto-rotate it while the pod runs, and
revoke it when the pod dies. And with the Vault Agent Injector, you can do all
of this without the app ever opening a Vault client. From the app's point of
view, it just reads a file.

That last part is the one I want to focus on.

---

## The pattern in one sentence

A mutating webhook adds a sidecar to your pod; the sidecar authenticates to
Vault, fetches a secret, writes it to a `tmpfs` volume at `/vault/secrets/…`,
and keeps it fresh. Your app reads the file.

```
  ┌─────────────────────────────────────────┐
  │ Pod                                     │
  │                                         │
  │  ┌──────────────┐    ┌───────────────┐  │
  │  │ your app     │    │ vault-agent   │──┼──► Vault (K8s auth → DB engine)
  │  │              │    │ sidecar       │  │
  │  │  reads file  │◄───┤ writes file   │  │
  │  └──────┬───────┘    └──────┬────────┘  │
  │         │                   │           │
  │         └──── tmpfs ────────┘           │
  │        /vault/secrets/db-creds.txt      │
  └─────────────────────────────────────────┘
```

Three things to appreciate here:

1. The app does not import a Vault SDK. It opens a file. If you rip Vault out
   tomorrow and replace it with something else that writes the same file, the
   app does not notice.
2. The file lives on a `tmpfs` volume scoped to that pod. When the pod dies,
   the credential dies with it.
3. The sidecar renews the lease and re-renders the file on a schedule. If you
   give the DB role a 1-hour TTL, the username and password in that file
   change every hour. No app restart required.

The rest of this post walks through building it on EKS end to end. The
runnable version — with commands you can copy — is in the companion
[`README.md`](./README.md).

---

## What you're going to build

- An EKS cluster (any size, this is a lab)
- Vault running in-cluster via Helm, with the Agent Injector enabled
- Postgres running in-cluster, with a `postgres` superuser Vault can use as a
  root credential to mint new users on demand
- A tiny Python Flask app with one route. It connects to Postgres using
  credentials it reads from `/vault/secrets/db-creds.txt`. It has no awareness
  of Vault.

Picking **in-cluster Vault + Kubernetes auth** keeps the whole thing in one
`kubectl apply`-able blast radius. It is not how I would run this in prod —
I'll come back to that at the end.

---

## Step 1 — Vault, by Helm

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm install vault hashicorp/vault \
  --namespace vault --create-namespace \
  --set "server.dev.enabled=true" \
  --set "server.dev.devRootToken=root" \
  --set "injector.enabled=true"
```

`server.dev.enabled=true` means Vault boots unsealed, in-memory, with a known
root token. That is a terrible idea in production and a wonderful idea in a
lab. The thing we actually care about is `injector.enabled=true`, which stands
up a mutating admission webhook. From now on, any pod with the right
annotations gets a `vault-agent` sidecar grafted in at admission time.

Verify:

```bash
kubectl -n vault get pods
# vault-0                            1/1  Running
# vault-agent-injector-xxxxx         1/1  Running
```

![Vault and the Agent Injector running in the vault namespace](./screenshots/01-vault-pods.png)
*Vault and the Agent Injector pods, up and ready to mutate things.*

---

## Step 2 — Teach Vault to trust Kubernetes

We want pods to authenticate to Vault using their ServiceAccount JWT. Vault's
Kubernetes auth method does exactly that: it takes the JWT, asks the cluster's
TokenReview API "is this a real token for this ServiceAccount?", and if so,
issues a Vault token bound to a policy.

Inside the Vault pod:

```bash
vault auth enable kubernetes
vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc.cluster.local"
```

Recent Vault versions pick up Vault's own pod ServiceAccount token and the
in-cluster CA automatically, so no extra flags are required. On older versions
you'd pass `token_reviewer_jwt` and `kubernetes_ca_cert` explicitly.

---

## Step 3 — A Postgres to point at

Before Vault can mint users, there has to be a Postgres for it to mint them
in. For a lab, a single-pod StatefulSet is enough:

```yaml
# postgres.yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
  namespace: app
spec:
  serviceName: postgres
  replicas: 1
  selector: { matchLabels: { app: postgres } }
  template:
    metadata: { labels: { app: postgres } }
    spec:
      containers:
        - name: postgres
          image: postgres:16
          env:
            - { name: POSTGRES_PASSWORD, value: "rootpw" }   # demo only
            - { name: POSTGRES_DB,       value: "appdb" }
          ports: [{ containerPort: 5432 }]
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: app
spec:
  selector: { app: postgres }
  ports: [{ port: 5432, targetPort: 5432 }]
```

```bash
kubectl create namespace app
kubectl apply -f postgres.yaml
kubectl -n app rollout status statefulset/postgres
```

The `postgres` superuser with password `rootpw` is what Vault will use as its
root credential to issue new short-lived users. Hardcoded root passwords in a
manifest are obviously only acceptable because this is throwaway. In prod
this would be RDS with an IAM-managed master credential — same engine config,
different connection URL.

Service DNS from inside the cluster: `postgres.app.svc.cluster.local:5432`.
Vault will connect there in the next step.

![Postgres pod and service in the app namespace](./screenshots/02-db-pods-ready.png)
*The Postgres pod ready to accept a connection from Vault.*

---

## Step 4 — The database secrets engine

This is where it gets interesting. We tell Vault:

- "Here is how to connect to Postgres as a superuser."
- "Here is a *role* that defines what a Vault-issued user is allowed to do and
  how long it lives."

```bash
vault secrets enable database

vault write database/config/appdb \
  plugin_name=postgresql-database-plugin \
  allowed_roles="app-role" \
  connection_url="postgresql://{{username}}:{{password}}@postgres.app.svc.cluster.local:5432/appdb?sslmode=disable" \
  username="postgres" \
  password="rootpw"

vault write database/roles/app-role \
  db_name=appdb \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; \
                       GRANT ALL PRIVILEGES ON DATABASE appdb TO \"{{name}}\";" \
  default_ttl="1m" \
  max_ttl="5m"
```

A 60-second TTL is aggressive on purpose — it makes the rotation visible
during the demo. Production values are usually measured in hours.

Now anyone with `read` on `database/creds/app-role` can ask Vault for a brand
new Postgres user. You can try it manually:

```bash
vault read database/creds/app-role
# Key                Value
# ---                -----
# lease_id           database/creds/app-role/xxxxxxxx
# lease_duration     1m
# username           v-kubernet-app-role-abcd1234-...
# password           A1b2C3d4...
```

That username didn't exist 5 seconds ago. Peek at Postgres and you'll see it:

```sql
SELECT rolname FROM pg_roles WHERE rolname LIKE 'v-kubernet-%';
```

When the lease expires, Vault executes a revoke statement and that role
disappears. The lifecycle is Vault's problem now, not yours.

---

## Step 5 — Policy and binding

We don't want any random pod in the cluster to be able to request these
credentials. Define a policy and bind it to a specific ServiceAccount:

```bash
vault policy write app-policy - <<EOF
path "database/creds/app-role" {
  capabilities = ["read"]
}
EOF

vault write auth/kubernetes/role/app-role \
  bound_service_account_names=app-sa \
  bound_service_account_namespaces=app \
  policies=app-policy \
  ttl=1h
```

Translation: a pod running as ServiceAccount `app-sa` in namespace `app` can
log into Vault and will be handed a token that can read
`database/creds/app-role`. Anything else — wrong namespace, wrong SA, no SA —
gets a 403.

---

## Step 6 — The app, which knows nothing

Here is the whole app, in Python:

```python
import os
from flask import Flask
import psycopg

SECRET = "/vault/secrets/db-creds.txt"

def load_creds():
    creds = {}
    with open(SECRET) as f:
        for line in f:
            k, v = line.strip().split("=", 1)
            creds[k] = v
    return creds

app = Flask(__name__)

@app.get("/")
def index():
    c = load_creds()
    with psycopg.connect(
        host=c["DB_HOST"], port=c["DB_PORT"], dbname=c["DB_NAME"],
        user=c["DB_USER"], password=c["DB_PASS"],
    ) as conn, conn.cursor() as cur:
        cur.execute("SELECT current_user, now();")
        row = cur.fetchone()
    return {"db_user": row[0], "db_time": row[1].isoformat()}
```

Count the Vault imports: zero. The word "vault" does not appear. The app reads
a plain text file that happens to live in a well-known place. If a reviewer on
your team asks "how does this app get its DB password?", the answer is "from a
file" and you can leave it there.

The Vault-shaped magic is entirely in the pod spec:

```yaml
metadata:
  annotations:
    vault.hashicorp.com/agent-inject: "true"
    vault.hashicorp.com/role: "app-role"
    vault.hashicorp.com/agent-inject-secret-db-creds.txt: "database/creds/app-role"
    vault.hashicorp.com/agent-inject-template-db-creds.txt: |
      {{- with secret "database/creds/app-role" -}}
      DB_USER={{ .Data.username }}
      DB_PASS={{ .Data.password }}
      DB_HOST=postgres.app.svc.cluster.local
      DB_PORT=5432
      DB_NAME=appdb
      {{- end }}
spec:
  serviceAccountName: app-sa
```

Four annotations and a ServiceAccount. That's the full contract between the
app team and the platform team.

- `agent-inject: "true"` tells the webhook "yes, please modify this pod."
- `role` picks the Vault Kubernetes auth role it should log in as.
- `agent-inject-secret-<filename>` says "fetch this Vault path."
- `agent-inject-template-<filename>` is a Go template that renders into the
  file. This is where the shape of the credentials file is decided.

At admission time, the mutating webhook injects two containers: an
`init container` that does the first render before the app starts, and a
sidecar that keeps renewing the lease and re-rendering the file.

---

## Step 7 — Watching it rotate

First, confirm the webhook actually injected the sidecar:

```bash
kubectl -n app get pod -l app=demo-app \
  -o jsonpath='{.items[0].spec.containers[*].name}'
# app vault-agent
```

![Pod listing with both the app container and the vault-agent sidecar](./screenshots/03-app-sidecar-container.png)
*Two containers in the pod — the app, and the `vault-agent` sidecar it doesn't know about.*

Exec into the pod and tail the file:

```bash
kubectl exec -n app <pod> -c app -- cat /vault/secrets/db-creds.txt
# DB_USER=v-kubernet-app-role-abcd1234-...
# DB_PASS=A1b2C3d4...
```

![Rendered /vault/secrets/db-creds.txt with injected DB_USER and DB_PASS](./screenshots/04-creds-injected.png)
*The credentials file inside the app container. No Vault client, no SDK — just a file.*

Wait a minute. Run it again. Different username, different password. Hit the
app's HTTP endpoint and you'll see the `current_user` in the response change
too — the connection pool opened a fresh connection with the new credentials.

If you want to be dramatic about it:

```bash
watch -n 5 "kubectl exec -n app <pod> -c app -- cat /vault/secrets/db-creds.txt"
```

![Two snapshots of the credentials file one minute apart, showing DB_USER and DB_PASS have changed](./screenshots/05-db-creds-auto-renew.png)
*Same pod, one minute apart. The app kept running; the credentials did not.*

---

## The part nobody tells you: apps that reload

A credential changing under a long-lived connection pool is only partly
useful. The sidecar wrote a new file, but your app might still be holding
sockets authenticated with the old user — which Vault has just revoked.

You have three options, roughly in increasing order of effort:

1. **Open per-request connections** (what the demo app does). Simple, fine for
   low-throughput services, terrible for anything that needs a pool.
2. **Signal on change.** The Vault Agent can run a command or send a signal
   when the template re-renders:
   ```yaml
   vault.hashicorp.com/agent-inject-command-db-creds.txt: "kill -HUP 1"
   ```
   Your app needs to handle `SIGHUP` by flushing its pool.
3. **Watch the file yourself.** Use `inotify` / `fsnotify` to reload the pool
   when the mtime changes. More code in the app, but no reliance on signals.

Whichever you pick, test it with a TTL short enough to make failures loud.

---

## Gotchas I've hit

- **Lease TTL vs connection lifetime.** If your pool keeps a connection open
  for an hour and your lease is 15 minutes, Vault will revoke the user out
  from under the pool and every subsequent query will fail. Match them.
- **Clock skew.** Kubernetes auth cares about the `exp` on the SA JWT. If your
  nodes are badly out of sync with Vault you'll see weird auth failures.
- **Pod startup time.** The `vault-agent-init` container has to fetch the
  first secret before the app starts. If Vault is unreachable, your pod
  wedges in `Init` forever. Put a liveness probe on the init container's
  behaviour, or at the very least an alert on `PodInitializing` time.
- **Secret zero.** Who unseals Vault? In a lab, dev mode. In prod, AWS KMS
  auto-unseal — but then the pod's IAM role is the real root of trust, so
  treat that IAM role like you'd treat a Vault root token.
- **`allowed_roles` on the DB config.** If you add a new DB role later and
  forget to update `allowed_roles`, Vault will refuse to issue it. The error
  message is helpful; the first time you hit it, it will not feel helpful.

---

## What I'd change for production

The lab shortcuts are the obvious ones, but worth being explicit:

- **Vault in HA mode** (Raft, 3 or 5 nodes) with **KMS auto-unseal**. Dev mode
  is for demos only.
- **Vault in its own cluster or in HCP Vault**, not in the same EKS cluster as
  the apps it serves. Cross-account, cross-cluster, cross-region, depending on
  how paranoid you are.
- **RDS or Aurora**, not an in-cluster Postgres. The database engine works
  identically; the connection URL changes.
- **Audit logs** to CloudWatch or S3. Every secret read is logged; you want
  that.
- **AppRole or IRSA + AWS auth** for workloads that live outside the cluster,
  so you don't have two parallel auth stories.
- **Sensible TTLs.** 1 minute is a demo. 1 hour is a defensible default. Tune
  from there.

---

## Why this pattern is worth the setup

The thing I keep coming back to is that the app doesn't know. It reads a
file. Every argument about "how do we rotate the DB password without a
redeploy" or "what happens if this pod gets compromised" or "can we give each
service its own DB user" collapses into "the file changed" or "the lease got
revoked." The complexity moves from scattered application code into one
central, auditable place — which is exactly where it belongs.

Shipping a new service now looks like: create a ServiceAccount, add four
annotations, read a file. The platform team owns the rest.

That is a nice place to be.

---

*Full step-by-step commands are in [`README.md`](./README.md). If you break
something interesting, the troubleshooting section at the bottom is where I
captured the mistakes I made while writing this.*
