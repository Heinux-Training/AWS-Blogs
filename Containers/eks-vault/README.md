# EKS + Vault Agent Injector + Dynamic Postgres Credentials

Follow-along lab for `blog-post.md`. Builds:

- An EKS cluster
- Vault (in-cluster, dev mode) with the Agent Injector
- Postgres (in-cluster)
- Vault database engine issuing short-lived Postgres users
- A demo app that reads its DB creds from `/vault/secrets/db-creds.txt` and
  has no knowledge of Vault

## Layout

```
eks-vault/
├── README.md               <- you are here
├── blog-post.md
├── app/
│   ├── app.py              <- Flask app, reads creds from a file
│   └── requirements.txt
├── manifests/
│   ├── postgres.yaml       <- Postgres StatefulSet + Service + namespace
│   └── app.yaml            <- ServiceAccount, Deployment, Service, Vault annotations
├── vault/
│   ├── values.yaml         <- Helm values for Vault (dev mode)
│   └── configure.sh        <- enables K8s auth, DB engine, policy, role
└── screenshots/            <- drop PNGs here; blog-post.md references them by name
    └── README.md           <- which image to capture at which step
```

---

## 0. Prerequisites

```bash
export AWS_REGION="<YOUR_REGION>"           # e.g. ap-southeast-1
export CLUSTER_NAME="<YOUR_CLUSTER_NAME>"   # e.g. vault-demo
```

You need `aws`, `eksctl`, `kubectl`, `helm` locally. Run everything from the
`eks-vault/` directory.

---

## 1. Create the EKS cluster

Pick a Kubernetes version explicitly — `eksctl`'s built-in default lags behind
what EKS actually supports, so unset it and you get something stale. Check
what's currently supported in your region first:

```bash
aws eks describe-cluster-versions --region "$AWS_REGION" \
  --query 'clusterVersions[?clusterVersionStatus==`standard-support`].clusterVersion' \
  --output table
```

Pick the newest version shown, then:

```bash
export K8S_VERSION="1.36"   # adjust to whatever the command above returned

# If eksctl rejects this version as unknown, upgrade eksctl first:
#   brew upgrade eksctl    (or re-download the binary)
#
# Heads-up: EKS deprecated the AL2 (Amazon Linux 2) AMIs starting with K8s 1.33.
# For 1.33+ you MUST pass --node-ami-family AmazonLinux2023 (or Bottlerocket).
# Without it you get:
#   "AMI Type AL2_x86_64 is only supported for kubernetes versions 1.32 or earlier"

eksctl create cluster \
  --name "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --version "$K8S_VERSION" \
  --node-ami-family AmazonLinux2023 \
  --nodes 2 \
  --node-type t3.medium \
  --managed

kubectl get nodes
kubectl version --short
```

---

## 2. Install Vault (dev mode) + Agent Injector

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

helm install vault hashicorp/vault \
  -n vault --create-namespace \
  -f vault/values.yaml

kubectl -n vault rollout status statefulset/vault
kubectl -n vault get pods
# vault-0                              1/1  Running
# vault-agent-injector-xxxxxxxxx-yyy   1/1  Running
```

---

## 3. Deploy Postgres

```bash
kubectl apply -f manifests/postgres.yaml
kubectl -n app rollout status statefulset/postgres
```

`manifests/postgres.yaml` also creates the `app` namespace.

---

## 4. Configure Vault

Copy the configure script into the Vault pod and run it:

```bash
kubectl -n vault cp vault/configure.sh vault-0:/tmp/configure.sh
kubectl -n vault exec -it vault-0 -- sh /tmp/configure.sh
```

This enables Kubernetes auth, enables the database secrets engine, points it
at the in-cluster Postgres, creates `app-role` with a 1-minute TTL (so you
can see rotation), writes the `app-policy`, and binds ServiceAccount
`app/app-sa` to that policy.

---

## 5. Deploy the app

The app's Python source lives in `app/app.py`; we ship it into the cluster as
a ConfigMap, then apply the Deployment:

```bash
kubectl -n app create configmap app-code \
  --from-file=app/app.py \
  --from-file=app/requirements.txt

kubectl apply -f manifests/app.yaml
kubectl -n app rollout status deploy/demo-app
```

Confirm the sidecar got injected:

```bash
kubectl -n app get pod -l app=demo-app \
  -o jsonpath='{.items[0].spec.containers[*].name}'
# Expect: app vault-agent
```

---

## 6. See the magic

```bash
POD=$(kubectl -n app get pod -l app=demo-app -o jsonpath='{.items[0].metadata.name}')

# The injected file
kubectl -n app exec "$POD" -c app -- cat /vault/secrets/db-creds.txt

# The app using it
kubectl -n app port-forward svc/demo-app 8080:80 &
curl -s http://localhost:8080/ | jq
# {"db_user": "v-kubernet-app-role-...", "db_time": "..."}
```

Watch rotation (TTL is 1m):

```bash
watch -n 5 "kubectl -n app exec $POD -c app -- cat /vault/secrets/db-creds.txt"
```

Username and password change roughly every minute. `app.py` never touches
Vault.

---

## 7. Updating the app

If you edit `app/app.py`:

```bash
kubectl -n app create configmap app-code \
  --from-file=app/app.py \
  --from-file=app/requirements.txt \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n app rollout restart deploy/demo-app
```

---

## 8. Cleanup

```bash
eksctl delete cluster --name "$CLUSTER_NAME" --region "$AWS_REGION"
```

---

## Troubleshooting

- **Sidecar not injected** — check the pod has `vault.hashicorp.com/agent-inject: "true"` and the injector pod is `Running` in the `vault` namespace.
- **`permission denied` from Vault** — ServiceAccount name/namespace in the `auth/kubernetes/role/app-role` binding must match the pod exactly (`app-sa` in `app`).
- **`connection refused` to Postgres** — Postgres DNS (`postgres.app.svc.cluster.local`) must resolve from the Vault pod. Confirm Postgres is `Ready`.
- **Secret file is empty / pod stuck Init** — `kubectl -n app logs <pod> -c vault-agent-init` will show template render or auth errors.
- **Dev-mode Vault reset** — if `vault-0` restarts, all config is gone; re-run `vault/configure.sh`.
