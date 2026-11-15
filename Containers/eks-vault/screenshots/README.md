# Screenshots

Drop your captures in this folder with these filenames. The blog post
references them directly; once the PNGs exist, the images render inline.

| # | Filename | What to capture |
|---|---|---|
| 1 | `01-vault-pods-running.png` | Terminal: `kubectl -n vault get pods` showing `vault-0` and `vault-agent-injector-...` both `Running`. |
| 2 | `02-postgres-ready.png` | Terminal: `kubectl -n app get pods,svc` showing `postgres-0` Ready and the `postgres` service. |
| 3 | `03-vault-read-creds.png` | Terminal (inside vault-0 pod): output of `vault read database/creds/app-role` with the generated `username` and `password` visible. |
| 4 | `04-pod-two-containers.png` | Terminal: `kubectl -n app get pod -l app=demo-app -o jsonpath='{.items[0].spec.containers[*].name}'` output — or `kubectl describe pod` — showing both `app` and `vault-agent` containers. |
| 5 | `05-injected-file.png` | Terminal: `kubectl -n app exec <pod> -c app -- cat /vault/secrets/db-creds.txt` showing `DB_USER=v-kubernet-app-role-...` and friends. |
| 6 | `06-rotation.png` | Two side-by-side terminals (or a `watch` snapshot a minute apart) showing the `DB_USER` value has changed. Alternatively, two `curl` outputs against `/` with different `db_user` values. |

## Capture tips

- Use a dark terminal with large font — screenshots read better on blog layouts.
- Redact anything that looks like a real AWS account ID or ARN before publishing.
- 1600–2000px wide is a good target; the blog will scale it down.
