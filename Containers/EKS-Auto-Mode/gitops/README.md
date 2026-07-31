# GitOps — app-of-apps for EKS Auto Mode

One parent Application (`root`) watches `gitops/apps/`. Every file in that directory is a
child Application. Adding a workload = committing one file there.

```
gitops/
├── root-app.yaml                  # THE parent app — the only thing you kubectl apply
├── projects/
│   └── platform.yaml              # AppProject the children belong to
├── apps/                          # <- root watches this dir; 1 file = 1 child app
│   ├── 00-projects.yaml           #    wave -1  → applies projects/
│   ├── 01-external-secrets.yaml   #    wave  0  → ESO (Helm)
│   ├── 02-repo-creds.yaml         #    wave  1  → Git SSH credentials
│   ├── 10-gpu-nodepool.yaml       #    wave  0  → GPU capacity
│   └── 20-gpu-test.yaml           #    wave 10  → GPU smoke test
└── manifests/                     # actual workloads, one dir per child app
    ├── repo-creds/
    │   ├── secretstore.yaml
    │   └── externalsecret-git-ssh.yaml
    ├── gpu-nodepool/
    │   ├── nodeclass.yaml
    │   └── nodepool.yaml
    └── gpu-test/
        ├── namespace.yaml
        ├── job-nvidia-smi.yaml
        └── deployment-gpu-burn.yaml
```

Filename prefixes (`00-`, `10-`, `20-`) are for humans; ordering is enforced by the
`argocd.argoproj.io/sync-wave` annotation inside each file.

## Bootstrap

Prereq: Argo CD installed per [../argocd/](../argocd/) (storage class → Helm values).
Then, instead of `argocd/bootstrap-app.yaml`, apply the parent from this tree:

```bash
kubectl apply -f Containers/EKS-Auto-Mode/gitops/root-app.yaml
kubectl -n argocd get applications -w
```

Expected: `root` → `projects` → `gpu-nodepool` → `gpu-test`, all Synced/Healthy.

## Verify GPU scheduling

```bash
# Pod is Pending while Auto Mode provisions a node — normal, takes 2-4 min.
kubectl -n gpu-test get pods -w

# Watch the node get created.
kubectl get nodeclaims -w
kubectl get nodes -l node-type=gpu -o wide

# The proof.
kubectl -n gpu-test logs job/gpu-smoke-test
kubectl get nodes -l node-type=gpu \
  -o jsonpath='{.items[*].status.allocatable.nvidia\.com/gpu}'
```

Once the Job completes, the node is idle and gets consolidated away after ~2 min
(`consolidateAfter` in the NodePool).

## SSH repo auth

Argo CD finds repo credentials by **label** on a Secret in `argocd`, not by name. The key
itself can't live in Git, so it sits in Secrets Manager and External Secrets Operator
materialises the Secret in-cluster:

```
Secrets Manager  argocd/github-deploy-key
      ↓  ESO (Pod Identity → eks-auto-argocd-external-secrets role)
Secret  argocd/git-ssh-creds   label: argocd.argoproj.io/secret-type=repo-creds
      ↓
Argo CD matches Secret.url as a PREFIX of each Application's repoURL
```

One-time setup (the only non-declarative part — a keypair AWS can't generate for you):

```bash
# 1. Generate a deploy key. No passphrase: Argo CD cannot prompt for one.
ssh-keygen -t ed25519 -C "argocd@eks-auto-argocd" -f ./argocd-deploy-key -N ""

# 2. Add the PUBLIC half to GitHub as a deploy key (read-only unless you need write-back):
#    repo → Settings → Deploy keys → Add deploy key → paste argocd-deploy-key.pub
#    Org-wide instead? Use a machine user's SSH key and skip per-repo deploy keys.

# 3. Push the PRIVATE half to Secrets Manager. --secret-string with file:// keeps the
#    newlines intact; a copy-pasted key with mangled newlines fails with
#    "invalid format" or "error creating SSH agent".
aws secretsmanager create-secret \
  --name argocd/github-deploy-key \
  --region ap-southeast-1 \
  --secret-string "$(jq -Rs '{sshPrivateKey: .}' < ./argocd-deploy-key)"

# 4. Delete the local copies.
shred -u ./argocd-deploy-key ./argocd-deploy-key.pub 2>/dev/null || \
  rm -f ./argocd-deploy-key ./argocd-deploy-key.pub

# 5. Bind the ESO service account to its IAM role (after ESO has synced).
eksctl create podidentityassociation -f ../eksctl/pod-identity.yaml
```

Then switch `repoURL` to the SSH form in `root-app.yaml` and every file in `apps/`:

```
https://github.com/Heinux-Training/AWS-Blogs.git   →   git@github.com:Heinux-Training/AWS-Blogs.git
```

Both spellings are already whitelisted in `projects/platform.yaml`. Argo CD treats them as
distinct URLs — mixing them means the SSH creds silently don't apply to the HTTPS ones.

Verify:

```bash
kubectl -n argocd get externalsecret git-ssh-creds       # want: SecretSynced
kubectl -n argocd get secret git-ssh-creds -o jsonpath='{.metadata.labels}'
argocd repocreds list                                    # want: your git@ prefix
```

Known-hosts: the `argo-cd` chart ships GitHub's host keys in `argocd-ssh-known-hosts-cm` by
default, so nothing extra is needed for GitHub. For a self-hosted Git server, add its key
via `configs.ssh.extraHosts` in [../argocd/values.yaml](../argocd/values.yaml) — otherwise
every sync fails with `Host key verification failed`.

**Chicken-and-egg:** the root app itself can't use SSH creds that the root app installs. Keep
`root-app.yaml`, `01-external-secrets.yaml` and `02-repo-creds.yaml` on HTTPS (fine — this
repo is public), or seed the Secret by hand once before switching everything to SSH.

## Adding an app

1. `mkdir gitops/manifests/my-app/` and put plain manifests, a Kustomize overlay, or a Helm
   chart ref in it.
2. Copy `apps/20-gpu-test.yaml` to `apps/30-my-app.yaml`, adjust `metadata.name`,
   `source.path`, `destination.namespace`, and the sync wave.
3. Commit. `root` picks it up on the next reconcile (≤3 min, or `argocd app sync root`).

## Things that bite

| Symptom | Cause |
| --- | --- |
| GPU pod Pending forever | Built-in `general-purpose` NodePool excludes accelerated families — you need the `gpu` NodePool. |
| Pod Pending with the NodePool present | Missing toleration for `nvidia.com/gpu=true:NoSchedule`. |
| `NodeClass not found` | Auto Mode uses `eks.amazonaws.com/v1` NodeClass, not `karpenter.k8s.aws/v1` `EC2NodeClass`. |
| Job re-sync fails "field is immutable" | Needs `argocd.argoproj.io/sync-options: Replace=true`. |
| Child app "project not found" | `projects` app must sync first — that's what wave `-1` is for. |
| `InsufficientInstanceCapacity` on g5/g6 | Spot capacity in the AZ; the NodePool falls back to on-demand, or widen `instance-size`. |
| SSH creds ignored / `authentication required` | Missing `argocd.argoproj.io/secret-type: repo-creds` label, or `url` isn't a prefix of the app's `repoURL`. |
| `Host key verification failed` | Non-GitHub host not in `argocd-ssh-known-hosts-cm`. |
| ESO app fails `annotations: Too long` | CRDs need `ServerSideApply=true` in syncOptions. |
| ExternalSecret stuck `SecretSyncedError` | Pod Identity association missing, or the Secrets Manager key/property name doesn't match. |

## Before you apply

Placeholders to check in the manifests:

- `repoURL` in `root-app.yaml` + every file in `apps/` — currently
  `https://github.com/Heinux-Training/AWS-Blogs.git` (public; no repo credential needed).
- `role: eks-auto-argocd-node` in `manifests/gpu-nodepool/nodeclass.yaml` — must match the
  node role Auto Mode created. Confirm with:
  `aws eks describe-cluster --name eks-auto-argocd --query 'cluster.computeConfig'`
- Region-specific instance families in `nodepool.yaml` (g5/g6 assume ap-southeast-1).
- G-instance vCPU quota — a fresh account often has 0 for spot g-family.
