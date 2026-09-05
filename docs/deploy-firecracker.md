# Deploy: Firecracker microVM fleet (brick #3)

Deployment **recipe** for `agent-cloud.md` §9 brick 3 — the per-tenant microVM substrate
and hibernation. This is **ops, not code**: it cannot be built or tested in this repo
session (no KVM/hardware here), so treat every command below as the documented plan, and
**validate on real metal** (§ "Unverified" at the end). Where an exact flag/field varies by
Firecracker version, it's marked `⚠`.

Assumes bare metal with hardware virtualization (Hetzner AX/EX line, or any KVM host).

---

## 1. Host prep

```sh
# KVM must be present and the user able to open /dev/kvm
lsmod | grep kvm                    # kvm_intel / kvm_amd
ls -l /dev/kvm
# release binaries (pin a version; don't build from HEAD for prod)
ARCH=x86_64 VER=v1.13.1            # ⚠ set to the version you actually pin
curl -fsSL https://github.com/firecracker-microvm/firecracker/releases/download/$VER/firecracker-$VER-$ARCH.tgz | tar xz
install release-*/firecracker-$VER-$ARCH  /usr/local/bin/firecracker
install release-*/jailer-$VER-$ARCH        /usr/local/bin/jailer
```

**Always launch through `jailer`, never `firecracker` directly.** The jailer is the
security boundary around the VMM process: it `chroot`s the VMM into
`<chroot-base>/firecracker/<id>/root`, enters fresh PID/mount/net namespaces, sets up a
**cgroup v2** slice for the VM, and drops to an unprivileged `uid:gid` before exec'ing
firecracker. So even a VMM-escape lands in an empty chroot as nobody, in its own namespaces.

**Overcommit reality (Hetzner-style metal):** microVMs let you overcommit — memory is
demand-paged (a VM with `mem_size_mib=2048` touches far less RSS), and with snapshot
hibernation (§4) idle tenants hold *zero* host RAM. CPU is time-sliced by cgroup weights.
Plan capacity on *active* working set, not sum-of-configured. Keep swap modest; the real
backstop against a noisy tenant is `memory.max` + `cpu.max` per slice, not host swap.

---

## 2. Guest image (kernel + rootfs)

**Kernel:** an uncompressed `vmlinux` built minimal for fast boot. What matters:

- virtio built **in** (`VIRTIO`, `VIRTIO_BLK`, `VIRTIO_NET`, `VIRTIO_MMIO`, `VIRTIO_RNG`) —
  not modules; Firecracker has no PCI, devices are MMIO.
- Strip the unused: no PCI (`pci=off` at boot too), no sound/graphics/USB, `CONFIG_MODULES=n`
  where you can, small or no initramfs.
- Boot args that shave time / silence probing:
  `console=ttyS0 reboot=k panic=1 pci=off i8042.noaux i8042.nomux i8042.nopnp i8042.dumbkbd quiet`
- Result is the well-known ~125 ms cold boot (cold; snapshot restore is far faster, §4).

**Rootfs — two images, per `agent-cloud.md` §2:**

- **Lean agent base** — the payoff of zish being **static musl**: the same `zish` + feats
  binary drops into *any* rootfs with no libc/runtime deps. So the base is a distroless/
  Alpine-static squashfs carrying static `zish`, the feats, and `curl`. Mount it
  **read-only** (`is_read_only: true`); give the guest a **tmpfs** workdir; **no runtime
  package manager** in the image (bake tools at build time). An agent cannot mutate its own
  rootfs.
- **Arch workload image** — for the AUR/`makepkg` build workload only (Alpine can't
  `makepkg`). `base` + `base-devel` + `git` + a **non-root build user** (makepkg refuses
  root and builds untrusted code — it wants to be the innermost sandbox). Heavier boot; use
  it only for that job, not as the general base.

Build the rootfs as an ext4 or squashfs file the drive points at:

```sh
# sketch: assemble a dir, then pack. squashfs = read-only + compressed (good for base).
mksquashfs rootfs/ agent-base.sqfs -noappend -comp zstd
# or ext4 if you need a writable overlay lower layer:
# dd if=/dev/zero of=rootfs.ext4 bs=1M count=512 && mkfs.ext4 -F rootfs.ext4 && (mount, copy, umount)
```

---

## 3. Per-tenant microVM

One microVM **per user session**. Each gets its own jailer id, chroot, API socket, cgroup.

```sh
ID=sess-$(uuidgen)
jailer --id "$ID" \
  --exec-file /usr/local/bin/firecracker \
  --uid 30000 --gid 30000 \
  --chroot-base-dir /srv/fc \
  --cgroup-version 2 \
  --cgroup cpu.max="20000 100000" \    # ⚠ 20% of one core; conservation "compute slice"
  --cgroup memory.max=2147483648 \     # 2 GiB hard cap
  --cgroup pids.max=512 \
  -- --api-sock /run/api.socket         # path is INSIDE the chroot
# API socket on host: /srv/fc/firecracker/$ID/root/run/api.socket
```

Configure via the API socket (or a `--config-file` JSON with the same fields). Minimal set:

```sh
SOCK=/srv/fc/firecracker/$ID/root/run/api.socket
curl --unix-socket $SOCK -X PUT http://localhost/boot-source \
  -d '{"kernel_image_path":"vmlinux","boot_args":"console=ttyS0 reboot=k panic=1 pci=off quiet init=/sbin/zish-init"}'
curl --unix-socket $SOCK -X PUT http://localhost/drives/rootfs \
  -d '{"drive_id":"rootfs","path_on_host":"agent-base.sqfs","is_root_device":true,"is_read_only":true}'
curl --unix-socket $SOCK -X PUT http://localhost/machine-config \
  -d '{"vcpu_count":1,"mem_size_mib":2048,"smt":false}'
curl --unix-socket $SOCK -X PUT http://localhost/network-interfaces/eth0 \
  -d '{"iface_id":"eth0","host_dev_name":"fc-tap-'$ID'","guest_mac":"AA:FC:00:00:00:01"}'
curl --unix-socket $SOCK -X PUT http://localhost/actions \
  -d '{"action_type":"InstanceStart"}'
```

Note: paths are **relative to the chroot** — the kernel/rootfs files must be hard-linked or
bind-mounted into `<chroot>/root/` before start (jailer copies/links `--exec-file`; you
stage the rest). Firecracker's per-device **rate limiters** (`rate_limiter` on drives/net,
token-bucket bandwidth + ops) are the IO-fairness knob alongside cgroups.

**Defense-in-depth inside the guest:** `zish --profile` applies Landlock + seccomp *within*
the VM (agent-cloud.md §1: confinement). The microVM is tenant **separation**; the profile
is the per-agent **leash**; both hold. The conservation model's capability slice is a
narrower profile handed to each spawned child (zish enforces narrow-only inheritance).

---

## 4. Hibernation — snapshot / restore (the §4 idea)

"Idle agent = a **paused snapshot on disk**, not a running VM." Zero host RAM/CPU while
idle; wake in ~ms. Flow:

```sh
# pause, then snapshot
curl --unix-socket $SOCK -X PATCH http://localhost/vm -d '{"state":"Paused"}'
curl --unix-socket $SOCK -X PUT  http://localhost/snapshot/create \
  -d '{"snapshot_type":"Full","snapshot_path":"snap/vmstate","mem_file_path":"snap/memfile"}'
# (VM can now be killed; state lives in the two files)
```

```sh
# restore into a FRESH jailer+firecracker (new socket), then resume
curl --unix-socket $NEWSOCK -X PUT http://localhost/snapshot/load \
  -d '{"snapshot_path":"snap/vmstate","mem_backend":{"backend_type":"File","backend_path":"snap/memfile"},"enable_diff_snapshots":false,"resume_vm":true}'
```

- **Full vs Diff:** Full = whole guest RAM to `mem_file`. **Diff** snapshots write only pages
  dirtied since the base (set `track_dirty_pages` / `enable_diff_snapshots`), so a warm "base
  agent" snapshot + tiny per-session diffs = cheap fan-out of many near-identical agents.
- **Restore latency:** loading + resume is milliseconds; pair with a **UFFD** memory backend
  (`backend_type:"Uffd"`) to page guest RAM in lazily instead of reading the whole memfile up
  front — this is what makes restore feel instant and lets you oversubscribe.
- **⚠ Snapshot security caveat (do not skip):** resuming the *same* snapshot more than once
  **clones cryptographic state** — RNG/entropy pool, TCP sequence numbers, any in-memory
  secret or session key are duplicated across every restore. Firecracker's own docs warn on
  this. Mitigations: **reseed entropy on resume** (virtio-rng present + a guest resume hook
  that reseeds `/dev/urandom` and regenerates keys), treat a snapshot as **single-tenant**
  (never restore one user's snapshot for another), and re-derive any secret post-resume. For
  fan-out of *identical fresh* agents this is fine; for anything holding secrets, reseed.

---

## 5. Networking + egress control

```sh
# one tap per VM, attached to a NAT bridge
ip tuntap add fc-tap-$ID mode tap
ip link set fc-tap-$ID master fcbr0 up      # fcbr0 = bridge with a private /24, host does NAT
# host NAT (nftables/iptables masquerade on the uplink) + forward only via the proxy
```

**Egress goes through an allowlist proxy, not open NAT** — mirrors Anthropic's Claude-Code
approach (sandbox denies network by default; allowed traffic flows through a filtering
proxy). Point the guest's `http(s)_proxy` / API base at the host proxy; the proxy permits
only the model endpoint(s) and declared hosts, denies the rest. This is what stops a
prompt-injected agent from exfiltrating even though it has "a network." Combine with
Firecracker net **rate limiters** for bandwidth caps.

---

## 6. Threat-model map (back to agent-cloud.md)

| Concern | Mechanism | Layer |
|---|---|---|
| tenant ⊥ tenant | **Firecracker microVM** + jailer chroot/namespaces | separation |
| agent can't exfiltrate / escalate | zish Landlock+seccomp `--profile` **inside** guest; egress allowlist proxy | confinement |
| noisy neighbor | cgroup v2 `cpu.max`/`memory.max`/`pids.max` + device rate limiters | fairness |
| cheap idle / fast wake | snapshot (Full/Diff) + UFFD restore | hibernation (§4) |
| tree can't exceed grant | conservation budget subdivides on spawn (brick #1), narrowed profile per child | conservation (§3) |

Separation is the VM, confinement is the profile, fairness is cgroups, hibernation is
snapshots — and the conservation budget (brick #1) rides on top, unchanged by any of this.

---

## Unverified here / next validation on real hardware

Nothing above was executed in this session — no KVM in the repo sandbox. Before trusting it:

1. **Pin + verify the Firecracker version** and re-check the exact `jailer` flag names and
   `snapshot/load` JSON schema against that release's docs (`⚠` marks fields that have moved
   between versions).
2. **Measure real boot + restore latency** on the target metal (cold boot, Full restore,
   Diff+UFFD restore) — the ~125 ms / ~ms figures are the documented ballpark, not measured
   here.
3. **Prove the entropy-reseed on resume** actually reseeds (generate randomness before
   snapshot, restore twice, confirm divergence) — this is the load-bearing snapshot-security
   check.
4. **Confirm the egress proxy denies by default** with a live exfil attempt from inside a
   guest (curl an unlisted host → blocked).
5. **Wire cgroup values to the conservation model** (brick #1): a spawned child's sub-slice
   must be carved from the parent's `cpu.max`/`memory.max`, not allocated fresh.
