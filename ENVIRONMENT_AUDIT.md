# DeployX – Environment Audit Report

**Audit Date:** November 4, 2026
**Auditor:** Senior DevOps & Cloud Infrastructure Lead
**Classification:** Internal Infrastructure Assessment

---

## 1. Executive Summary

An exhaustive environment audit was conducted for the host machine and Ubuntu WSL2 runtime environment. The system is properly configured with modern containerization, container orchestration, and CLI tools. The primary operational constraint identified is the **3.5 GiB total RAM allocation in WSL2**, which requires disciplined pod resource limits, lightweight base container images, and efficient monitoring stack sizing to avoid out-of-memory (`OOMKilled`) failures.

---

## 2. Operating System & Kernel Specifications

| Component | Host System (Windows) | Guest Subsystem (WSL2) |
|---|---|---|
| **OS Distribution** | Microsoft Windows 11 | Ubuntu 26.04.1 LTS |
| **Kernel Version** | Windows NT 10.0 | Linux 6.18.33.1-microsoft-standard-WSL2 |
| **Architecture** | x86_64 | x86_64 / amd64 |
| **Shell Environment** | PowerShell 5.1 / 7+ | Bash 5.2+ (`/bin/bash`) |
| **WSL Version** | WSL2 (Virtualization Platform) | Running (`docker-desktop` + `Ubuntu`) |

---

## 3. System Compute & Storage Capacity

### 3.1 Memory Allocation (WSL2)
```text
               total        used        free      shared  buff/cache   available
Mem:           3.5Gi       1.3Gi        33Mi        64Mi       2.3Gi       2.2Gi
Swap:          1.0Gi       1.0Mi       1.0Gi
```
- **Total Physical Memory:** 3.5 GiB
- **Active Memory In-Use:** ~1.3 GiB (Kind node container + WSL background services)
- **Available Working Memory:** ~2.2 GiB
- **Swap Space:** 1.0 GiB (1.0 MiB in use, 1.0 GiB free)

> [!WARNING]
> **Memory Constraint:** Local Docker and Kind run inside a ~3.5 GiB WSL2 memory envelope. All Kubernetes deployments must enforce strict `resources.requests` and `resources.limits` to guarantee stability. Heavy LLMs or oversized monitoring stores will trigger swapping or kernel OOM-killer.

### 3.2 Disk Storage (WSL2)
```text
Filesystem      Size  Used Avail Use% Mounted on
/dev/sdd       1007G  2.1G  954G   1% /
```
- **Primary Disk Capacity:** 1007 GiB
- **Used Storage:** 2.1 GiB (1%)
- **Available Storage:** 954 GiB
- **Assessment:** Ample disk space for container image caching, build artifacts, and test logs.

---

## 4. Installed Toolchain Verification

| Tool | Version Detected | Status | Purpose in DeployX |
|---|---|---|---|
| **Docker Engine** | `29.9.2` (build `a82e528`) | Verified | Container runtime and build daemon |
| **Docker Compose** | `v5.6.1` | Verified | Multi-container local orchestration |
| **kubectl** | Client `v1.36.1` (Kustomize `v5.8.1`) | Verified | Kubernetes cluster administration |
| **Kind (Kubernetes in Docker)** | `v0.30.0` (`linux/amd64`) | Verified | Local multi-node / single-node K8s clusters |
| **Helm** | `v3.22.1` | Verified | Kubernetes package management |
| **Python** | `3.14.4` | Verified | Backend runtime and automation testing |
| **Git** | `2.53.0` | Verified | Version control and VCS metadata |
| **curl** | `/usr/bin/curl` | Verified | HTTP health-checking and API probing |
| **jq** | `/usr/bin/jq` | Verified | JSON parsing in shell automation scripts |
| **AWS CLI** | *Not installed in WSL* | Planned | Managed via AWS SDK / IaC configs / localstack |
| **Ollama** | *Not installed in WSL* | Planned (Opt) | Rule-based engine will serve as default; Ollama optional |

---

## 5. Kubernetes Cluster Inspection

### 5.1 Cluster Identity & Context
- **Cluster Name:** `deployx`
- **Active Context:** `kind-deployx`
- **Kubernetes Version:** `v1.34.0`
- **Container Runtime:** `containerd://2.1.3`
- **API Server Port Forward:** `127.0.0.1:33451 -> 6443/tcp`

### 5.2 Node Topology
```text
NAME                    STATUS   ROLES           AGE     VERSION   INTERNAL-IP   OS-IMAGE                         CONTAINER-RUNTIME
deployx-control-plane   Ready    control-plane   8m+     v1.34.0   172.18.0.2    Debian GNU/Linux 12 (bookworm)   containerd://2.1.3
```

### 5.3 Cluster Core System Pods
```text
NAMESPACE            NAME                                            READY   STATUS    RESTARTS
kube-system          coredns-66bc5c9577-pnkgb                        1/1     Running   0
kube-system          coredns-66bc5c9577-tdwhg                        1/1     Running   0
kube-system          etcd-deployx-control-plane                      1/1     Running   0
kube-system          kindnet-fgf7m                                   1/1     Running   0
kube-system          kube-apiserver-deployx-control-plane            1/1     Running   0
kube-system          kube-controller-manager-deployx-control-plane   1/1     Running   1
kube-system          kube-proxy-crphq                                1/1     Running   0
kube-system          kube-scheduler-deployx-control-plane            1/1     Running   1
local-path-storage   local-path-provisioner-7b8c8ddbd6-9kmnz         1/1     Running   0
```
- **Cluster Health Status:** **HEALTHY & READY**. Core DNS, etcd, control plane API server, proxy, and dynamic local-path storage provisioner are operational.

---

## 6. Security & Credential Isolation Audit

1. **Credential Scrubbing:** No cloud credentials, API tokens, `.env` files, or SSH keys are present in the project workspace.
2. **Kubeconfig Security:** The kubeconfig is isolated in standard user directories (`~/.kube/config`).
3. **Container Isolation:** The local Docker daemon runs under standard user permissions within WSL2.
4. **Network Exposure:** The Kind cluster API is bound strictly to `127.0.0.1:33451`, preventing unauthorized external network ingress.

---

## 7. Resource Budgeting & Optimization Strategy

To ensure high performance within the 3.5 GiB RAM threshold:

| Workload | Replicas | CPU Request / Limit | Memory Request / Limit | Strategy |
|---|---|---|---|---|
| **DeployX Backend (Blue)** | 2 | `50m` / `200m` | `64Mi` / `128Mi` | Alpine / slim Python container |
| **DeployX Backend (Green)** | 2 | `50m` / `200m` | `64Mi` / `128Mi` | Alpine / slim Python container |
| **DeployX Frontend** | 1 | `25m` / `100m` | `32Mi` / `64Mi` | Lightweight static Nginx |
| **Prometheus Server** | 1 | `100m` / `250m` | `128Mi` / `256Mi` | 6h retention, minimal scrapes |
| **Grafana Dashboard** | 1 | `50m` / `150m` | `64Mi` / `128Mi` | Minimal plugins, SQLite backend |
| **Buffer / System Reserve** | - | - | `~1.5 GiB` | Buffer for OS, Kind & Docker |
| **Total Projected Footprint** | - | - | **~832 MiB max** | **Well within 2.2 GiB available** |

---

## 8. Audit Conclusions & Readiness Verdict

- [x] Host environment verified.
- [x] Toolchain verified and operational.
- [x] Kind cluster `deployx` online and ready.
- [x] Resource envelope documented and constraints factored into architectural design.
- [x] **VERDICT: PROCEED TO PHASE 1 PLANNING & ARCHITECTURE APPROVAL.**
