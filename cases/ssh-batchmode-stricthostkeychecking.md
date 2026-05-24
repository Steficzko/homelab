---
date: 2026-05-22
tags: [ssh, networking, nodes, linux, cka]
---

# SSH config: BatchMode vs StrictHostKeyChecking for cluster nodes

## Goal

Add all three k3s nodes to `~/.ssh/config` so I can `ssh k3s-prg-b3` etc. without flags, and do it in a way that doesn't block on interactive prompts.

## Problem

`BatchMode=yes` is meant to suppress interactive auth prompts, but it also kills the connection if the host key is not already in `~/.ssh/known_hosts`. First connection to a new node fails silently with a host-key error rather than just adding the key.

## Solution

`~/.ssh/config` block for the three nodes:

```
Host k3s-prg-r1
  HostName 192.168.1.201
  User root
  IdentityFile ~/.ssh/id_ed25519_github
  AddKeysToAgent yes

Host k3s-prg-g2
  HostName 192.168.1.202
  User root
  IdentityFile ~/.ssh/id_ed25519_github
  AddKeysToAgent yes

Host k3s-prg-b3
  HostName 192.168.1.203
  User root
  IdentityFile ~/.ssh/id_ed25519_github
  AddKeysToAgent yes
```

Key decision: use `StrictHostKeyChecking=accept-new` for first-contact, then drop it from config once keys are in `known_hosts`. `accept-new` accepts and saves any host key not yet in `known_hosts`, but rejects keys that contradict an existing entry (MITM protection preserved).

## Why it works

SSH's host-key check has three modes:

| Option | Unknown key | Changed key |
|---|---|---|
| `yes` (default strict) | Interactive prompt | Fail |
| `accept-new` | Accept + save silently | Fail |
| `no` | Accept silently | Accept silently |
| `BatchMode=yes` | Fail (no prompt allowed) | Fail |

`accept-new` gives the "first-connect is safe, reconnect is verified" guarantee without needing a human at the keyboard. `no` is dangerous — ignores MITM. `BatchMode` is for scripted automation where known_hosts is pre-populated in advance.

## CKA angle

The exam gives you a terminal where nodes may or may not be in known_hosts. When SSH-ing to control-plane nodes for etcd snapshots, log inspection, or cert rotation, `StrictHostKeyChecking=accept-new` (or pre-populating with `ssh-keyscan`) is the safe non-interactive pattern.

CKA tasks that require SSH to a node:
- `kubectl drain` then SSH to inspect kubelet logs: `journalctl -u kubelet -n 50`
- Check/rotate certs: `kubeadm certs check-expiration` on the control-plane node
- Snapshot etcd: `ETCDCTL_API=3 etcdctl snapshot save ...` directly on the etcd host

Imperative shortcut — pre-populate known_hosts before scripting:
```bash
ssh-keyscan 192.168.1.201 192.168.1.202 192.168.1.203 >> ~/.ssh/known_hosts
```

## Revision prompts

1. What happens when you SSH to an unknown host with `BatchMode=yes` set?
2. What is the difference between `StrictHostKeyChecking=accept-new` and `StrictHostKeyChecking=no`?
3. What command pre-populates `known_hosts` for a list of IPs without connecting interactively?

## Anki

Q: What SSH option accepts a new host key silently but still rejects changed keys?
A: StrictHostKeyChecking=accept-new

Q: What does BatchMode=yes do when the host key is not in known_hosts?
A: Fails immediately — no interactive prompt, no key acceptance

Q: What command pre-populates known_hosts for multiple nodes without interactive SSH?
A: ssh-keyscan <ip1> <ip2> ... >> ~/.ssh/known_hosts
