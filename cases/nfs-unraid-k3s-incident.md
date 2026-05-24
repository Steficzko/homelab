---
date: 2026-05-22
tags: [storage, nfs, initcontainer, securitycontext, debugging, cka]
---

# NFS Unraid ↔ K3s — Full Incident (3 sub-problems)

## Goal

Get Nextcloud running on K3s with its data volume served over NFS from an Unraid box. Three separate failures hit in sequence: wrong squash settings, rpcbind boot ordering, and stale mounts after a server restart.

---

## Problem 1: NFS squash settings broke initContainer chown

Unraid 7.3 changed its "Public" NFS security mode to force `all_squash`, mapping every UID — including root (uid=0) — to anonymous (uid=99). The Nextcloud Deployment has an initContainer that runs as root and does `chown -R 33:33 /data`. With all_squash in place, this fails silently. `kubectl exec` into the pod and `ls /var/www/html/data` hangs forever — any I/O to the NFS mount blocks indefinitely.

## Problem 2: rpcbind not starting before NFS on boot

After Unraid 7.3, rpcbind (RPC portmapper, port 111) no longer starts before nfsd at boot. Without rpcbind, nfsd starts and exits immediately — port 2049 never opens. The Unraid UI shows NFS as "enabled" but nothing is listening.

Symptom: `nc -zv 192.168.1.100 2049` → Connection refused. `ps aux | grep nfsd` → nothing. Clicking "restart NFS" in the UI says "Started" but port 2049 stays closed.

## Problem 3: Stale NFS mounts after Unraid goes down and comes back

When the Unraid NFS server goes down and comes back, K3s nodes retain stale hard NFS mounts from old pod UIDs. These block new pods from starting because the kubelet can't bind the volume path.

---

## Solution

### Problem 1 — Fix NFS export options

In the Unraid UI: set NFS security to **Private** with explicit per-IP rules for each K3s node:

```
192.168.1.201(rw,sec=sys,insecure,no_root_squash,no_all_squash)
192.168.1.202(rw,sec=sys,insecure,no_root_squash,no_all_squash)
192.168.1.203(rw,sec=sys,insecure,no_root_squash,no_all_squash)
```

Verify the exports are live on the Unraid host:

```bash
exportfs -v
```

Output must show `no_root_squash,no_all_squash` for each node IP. If it still shows `all_squash`, the change hasn't applied — check whether Unraid regenerated `/etc/exports` from its own config (it always does on boot; never hand-edit that file).

### Problem 2 — Fix rpcbind boot ordering

On the Unraid host, manually restart in the correct order:

```bash
rm -f /var/run/rpcbind.pid
/sbin/rpcbind -w
/etc/rc.d/rc.nfsd restart
```

Diagnosis checklist when pods can't mount NFS:

1. `nc -zv <nfs-server-ip> 2049` — Connection refused → rpcbind is down, run the fix above
2. Timeout instead of refused → Unraid IP may have changed; verify actual IP
3. Port 2049 open but pod still fails → check squash settings (`exportfs -v`)

### Problem 3 — Clear stale mounts and recover

Run on the affected K3s node:

```bash
# List all NFS mounts on the node
cat /proc/mounts | grep nfs

# Lazy-unmount each stale path (does not contact the NFS server)
sudo umount -l /var/lib/kubelet/pods/<pod-uid>/volumes/kubernetes.io~nfs/nextcloud-data-nfs
```

Then in kubectl, clean up any stuck pods and bring the workload back:

```bash
# Force-delete stuck pods (e.g. cron jobs that hold the volume claim)
kubectl delete pod -n nextcloud <stuck-cron-pod> --force --grace-period=0

# Bring the deployment back up
kubectl scale deployment nextcloud -n nextcloud --replicas=1
```

**DO NOT:**
- Edit `/etc/exports` by hand on Unraid — it regenerates from its own config on every boot
- Restart NFS without starting rpcbind first
- Run `sudo systemctl restart k3s` from the Unraid terminal — triggers an unexpected node reboot

---

## Why it works

**Problem 1:** NFS export options are enforced server-side. `all_squash` means the server maps every incoming UID to nobody (uid=99) regardless of what the client sends. The initContainer's `chown` succeeds from the container's perspective but the syscall the NFS server receives comes from uid=99, which has no write permission to the export. The I/O doesn't error — it just blocks waiting for a response that never comes because the kernel is retrying a stale RPC. `no_root_squash` restores normal UID passthrough for root; `no_all_squash` restores it for all other UIDs.

**Problem 2:** NFSv3 uses RPC for all communication. RPC requires rpcbind to be running first so clients can discover which port each RPC service is on. If rpcbind isn't up, nfsd has nowhere to register and exits. The RPC stack has to start in order: rpcbind → nfsd → mountd.

**Problem 3:** Hard NFS mounts (the K3s default for PVs) retry indefinitely on network failure rather than returning an error to the caller. When the NFS server comes back with a different epoch, those in-flight retries are now stale. `umount -l` (lazy unmount) detaches the mount point from the filesystem namespace immediately without needing to talk to the server, allowing the kernel to clean up the mount table entry.

---

## CKA angle

**Exam domain:** Storage (PersistentVolumes, PersistentVolumeClaims, access modes).

Key things the exam tests that this incident exercises:

- Creating and troubleshooting NFS-backed PersistentVolumes
- Understanding `accessModes` (`ReadWriteMany` for NFS shared across nodes)
- Debugging why a pod is stuck in `Init:0/1` — the examiner might give you a pod where an initContainer is hanging on a volume operation
- `kubectl describe pod` → look at Events for volume mount failures
- `kubectl exec` into a debug container to probe the mount
- Force-deleting terminating pods with `--force --grace-period=0`
- `kubectl scale deployment` to bring replicas to zero for maintenance and back up

**Imperative shortcuts for the exam:**

```bash
# Scale down quickly
kubectl scale deployment <name> -n <ns> --replicas=0

# Force delete a stuck pod
kubectl delete pod <name> -n <ns> --force --grace-period=0

# Check pod init container logs
kubectl logs <pod> -n <ns> -c <init-container-name>

# Describe to see volume mount events
kubectl describe pod <pod> -n <ns>
```

Security context in a manifest (initContainer running as root to chown):

```yaml
initContainers:
  - name: fix-permissions
    image: busybox
    command: ["chown", "-R", "33:33", "/data"]
    securityContext:
      runAsUser: 0
    volumeMounts:
      - name: data
        mountPath: /data
```

---

## Revision prompts

1. An initContainer that runs `chown` on an NFS-backed volume hangs indefinitely. What are three things you check, in order?
2. A pod is stuck in `Terminating` for 10 minutes and its NFS server just came back online. What single command clears it from the node, and what flag pair do you use?
3. Why does NFSv3 require rpcbind to be running before nfsd can accept connections?

---

## Anki

What NFS export option prevents the server from remapping root (uid=0) to anonymous? | no_root_squash
What NFS export option prevents the server from remapping ALL users to anonymous? | no_all_squash
What command shows which NFS exports are currently active and with which options on the server? | exportfs -v
What command lists all NFS mounts on a Linux node without contacting the NFS server? | cat /proc/mounts | grep nfs
What umount flag detaches a stale NFS mount immediately without contacting the server? | umount -l (lazy unmount)
What kubectl flag pair force-deletes a stuck terminating pod? | --force --grace-period=0
What K8s object field lets an initContainer run as root even when the pod spec sets a non-root user? | securityContext.runAsUser: 0 on the initContainer
Why does an initContainer chown hang on NFS with all_squash? | The server maps root to nobody (uid=99), the chown syscall is retried indefinitely by the NFS client, blocking all I/O on that mount
What is the correct startup order for the NFSv3 RPC stack? | rpcbind → nfsd → mountd
