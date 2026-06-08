# Task #40 — Coalesce V-buffer (port plan)

**Status:** Study-phase output. No code changes yet.
**Baseline:** GPU-2026.0607.2 on RTX 4060 Laptop (8 GB), 129 KH/s GPU + 9 KH/s CPU, shares 90/91 accepted.
**Validation rule (from CLAUDE.md):** every increment must produce **real H/s + accepted shares** before merging. The host-side `<2 ms` "implausibly fast" guard in `dagtech_gpu_thread` (around `dagtech_miner.c:927`) is the trip wire — if a kernel batch completes in under 2 ms, hashes aren't counted (driver-reset / fast-fail symptom).

---

## 1. What the reference miner actually does

Three techniques the CLAUDE.md briefing names, mapped to where they live in `reference-cuda-miner/src/`:

### 1a. Split kernels (not one mega-kernel per nonce)

Our miner runs **one kernel** that does the full pipeline per nonce: `dagtech_search` in `source/dagtech_gpu.cl:365–427`. Steps 1–7 (midstate → HMAC init → PBKDF2 80→128 → ROMix → tweak → PBKDF2 128→32 → target check) all in one launch.

The reference splits the same pipeline into **6 kernels** launched in sequence per nonce batch (`src/hasher.cu`):

| Reference kernel | Lines | Our kernel's equivalent step |
|---|---|---|
| `scrypt_hash_start_kernel` | 395–442 | Steps 1–3 (midstate, HMAC init, PBKDF2 80→128) — output: per-hash `tstate`, `ostate`, `X` |
| `hasher_gen_kernel` | 279–308 | Step 4a — ROMix **Fill** phase (writes V) |
| `hasher_hash_kernel` | 314–339 | Step 4b — ROMix **Mix** phase (random V reads) |
| `hasher_combo_kernel` | 351–378 | Steps 4a+4b fused (smaller register pressure than 4a/4b standalone — used when the device's occupancy permits) |
| `bdag_post_romix_tweak_kernel` | 452–460 | Step 5 — the proprietary X[0] tweak |
| `scrypt_hash_finish_kernel` | 524–550 | Steps 6–7 (PBKDF2 128→32 + target check) |

**Why this matters for #40:** each individual kernel finishes in **well under the 2 s Windows TDR watchdog**, regardless of how many hashes are in flight. The previous coalesce attempt died on the 780M iGPU because a single huge dispatch exceeded the watchdog. Splitting fixes the failure mode at the structural level — we never enqueue work that *can* time out.

### 1b. Cooperative `THREADS_PER_SCRYPT_BLOCK = 4` (four threads per hash)

Where it lives: every reference kernel uses these two lines (e.g. `hasher.cu:60–61`):
```cuda
int scrypt_block = (blockIdx.x*blockDim.x + threadIdx.x) / THREADS_PER_SCRYPT_BLOCK;
start = scrypt_block * SCRYPT_SCRATCH_PER_BLOCK + (32*i) + 8*(threadIdx.x % 4);
```

Reading this: a "scrypt block" (one 128-byte state) is owned by **four threads**, not one. Each thread handles `8 of the 32` uints in `X[]`. The four threads share the work via:
- **Memory:** each thread writes its 8-uint slice (32 bytes = one `uint4` pair) to the *same* row of V. Adjacent thread = adjacent 32 bytes = **perfectly coalesced** memory access.
- **Computation:** they exchange data via warp shuffles (`__shfl_sync` at `hasher.cu:73, 107–109, 292–294`) to recombine the Salsa20/8 state between rounds.

**Why this matters for #40:** in our current kernel, work-item `i`'s V row sits 128 KB away from work-item `i+1`'s V row — **the exact uncoalesced pattern the briefing flags**. Switching to 4-threads-per-hash makes adjacent work-items (within a sub-group / warp) hit adjacent memory.

### 1c. `uint4` vector loads and stores

Where: `scrypt_cores.cu:82–98` defines `write_8_as_uint4` / `read_8_as_uint4`, and the kernels in `hasher.cu` use raw `uint4 t = *(uint4*)&scratch[loc]` and `*(uint4*)&scratch[loc] = t` (e.g. lines 42, 53, 55, 81, 83, 415).

Effect: each memory transaction moves **16 bytes** (4 uints) instead of 4 bytes. Combined with coalescing from (1b), 8 threads × 16 bytes = one 128-byte cache line per row — exactly what the memory controller wants.

In portable OpenCL this is `uint4` + `vstore4`/`vload4`, **or** the simpler `__global uint4 *vp = (__global uint4 *)&V[...]; *vp = ...;` which most OpenCL 1.2 compilers handle correctly.

---

## 2. Constraints we cannot violate

1. **The post-ROMix X[0] tweak must stay bit-identical.** Both copies:
   - Host (CPU path): `source/dagtech_miner.c:417` area
   - Kernel: `source/dagtech_gpu.cl:408–412`
   Pool acceptance depends on this. Any rewrite of step 5 ships exactly this five-line snippet.
2. **The `<2 ms` "implausibly fast" guard stays put.** It's the only thing distinguishing a kernel that did 8192 hashes from a kernel the driver reset. Removing it = silently shipping fake hashrate. Located in `dagtech_gpu_thread` near `dagtech_miner.c:927`.
3. **Portability stays portable.** OpenCL 1.2 baseline — no `cl_khr_subgroups` extension assumptions, no NVIDIA-specific intrinsics. Inter-thread communication uses `__local` memory + `barrier(CLK_LOCAL_MEM_FENCE)`, not `sub_group_shuffle`. (The reference uses CUDA `__shfl_sync`; we substitute local memory.)
4. **The CUDA fork decision is user-gated.** Per CLAUDE.md, going NVIDIA-only requires explicit owner approval. Until then, every change ships as portable OpenCL.

---

## 3. CUDA → OpenCL idiom map

| CUDA | Portable OpenCL 1.2 |
|---|---|
| `__global__ void foo(...)` | `__kernel void foo(...)` |
| `__device__ inline T helper(...)` | `static T helper(...)` (already used in our `.cl`) |
| `threadIdx.x` | `get_local_id(0)` |
| `blockIdx.x * blockDim.x + threadIdx.x` | `get_global_id(0)` |
| `__shared__ T arr[N]` | `__local T arr[N]` (kernel arg or declaration) |
| `__syncthreads()` | `barrier(CLK_LOCAL_MEM_FENCE)` |
| `__shfl_sync(0xffffffff, val, lane)` | **No portable equivalent.** Use `__local` scratch + barrier: write `val` to `local[get_local_id(0)]`, barrier, read `local[lane]`, barrier. |
| `uint4 t = *(uint4*)&p[i]` | `uint4 t = *((__global uint4*)&p[i])` — OR `vload4(0, &p[i])` |
| `*(uint4*)&p[i] = t` | `*((__global uint4*)&p[i]) = t` — OR `vstore4(t, 0, &p[i])` |

The `__shfl_sync` → `__local + barrier` substitution is the highest-risk part of the port: it adds barrier overhead the CUDA path doesn't pay. Some of the reference's speedup will leak. Expect a smaller speedup multiplier on OpenCL than the reference miner sees on CUDA.

---

## 4. Phased increments (each one is independently shippable)

Each increment ends with the same gate: **build → run → check `gpu_hashrate` AND share-accept ratio for ≥5 minutes, no kernel resets in log, no "implausibly fast" lines**. If anything fails, revert that increment before moving on.

### Increment 1 — `uint4` writes/reads on the existing kernel layout (low risk)

**What changes:** only the inner loop bodies of `scrypt_romix` in `dagtech_gpu.cl:335–350`. Replace the byte-by-byte 32-uint copy with 8 × `uint4` stores/loads.

**Files changed:** `source/dagtech_gpu.cl` only.

**Expected win:** modest. The pattern stays uncoalesced *between* work-items (still 128 KB stride), so this is just better per-work-item memory bandwidth. Reference miner's `write_8_as_uint4` is the exact template — but applied to our current 1-thread-per-hash layout.

**Risk:** very low. No layout change. No tweak change. The kernel is still the same single `dagtech_search`. If shares stop accepting, the BSWAP order in `uint4` packing is wrong — easy to bisect.

**Rollback:** revert the one file. No host-side change.

### Increment 2 — Split the kernel (medium risk)

**What changes:**
- `source/dagtech_gpu.cl`: keep `dagtech_search` for backward compat, **add** `dagtech_start`, `dagtech_romix`, `dagtech_tweak`, `dagtech_finish` kernels. Each does one stage and reads/writes intermediate state to/from `__global` buffers.
- `source/dagtech_miner.c`: in `dagtech_gpu_thread`, replace the single `clEnqueueNDRangeKernel` (line 888) with a sequence of four enqueues. Allocate the intermediate buffers (`tstate_buf`, `ostate_buf`, `X_buf`) once at context init.

**Expected win (predicted):** zero or slightly negative on its own — splitting adds per-launch overhead. The *purpose* of this increment is to unlock Increment 3 (cooperative threads in `dagtech_romix` only, without breaking the other stages) and to make each kernel small enough to never exceed Windows TDR even at high `global_size`.

**Actual measured win (RTX 4060 Laptop, diff 10.448):** **+90% over Inc1, +112% over baseline.** Steady-state went from 143 KH/s → ~272 KH/s. Best explanation: the single `dagtech_search` kernel had high register pressure that capped warp occupancy per SM. Three smaller kernels each fit in a smaller register footprint, so the GPU keeps many more warps live simultaneously. This matches the reference miner's `hasher_combo_kernel` comment: "the two individual kernels can use fewer registers alone." The prediction missed this entirely — splitting wasn't just a structural prerequisite for #3, it was an occupancy win in its own right.

**Risk:** medium. State has to flow between kernels via global buffers. Any byte-order or layout mismatch surfaces as zero accepted shares.

**Rollback:** revert both files; the old `dagtech_search` path stays intact in the .cl file as a fallback, so we can fall back at runtime via an env var if needed.

### Increment 3 — Cooperative 4 threads/hash + coalesced V layout (high risk, big win)

**What changes:**
- The new `dagtech_romix` kernel from Increment 2 gets rewritten: launch with `4 × scrypt_blocks` work-items, use `__local` memory + barriers for the four threads of each scrypt block to share state, and reshape the V buffer to **interleaved layout** so adjacent work-items touch adjacent memory.

  Specifically: `V[ row * (4 * scrypt_blocks) * 8 + (scrypt_block * 4 + thread_in_block) * 8 + lane_uint ]` — meaning the four threads of one scrypt block write four adjacent 8-uint chunks, and adjacent scrypt blocks sit right next to each other.

- `source/dagtech_miner.c`: `global_size` arg to the ROMix dispatch becomes `4 * global_size_hashes`. `gpu_fit_global_size` accounting stays the same (V buffer size per hash didn't change, just its internal layout).

**Expected win:** this is where the real speedup lives. The reference miner's playbook says memory-bandwidth-bound kernels respond strongly to coalescing on discrete GPUs.

**Risk:** high. New layout means every V read/write changes; the Salsa20/8 state must be reconstructed from four threads' partial views; barriers are non-trivial to place correctly. The post-ROMix X[0] tweak runs **after** ROMix output is recombined into a single 32-uint state — easy to get wrong.

**Rollback:** the previous increment's `dagtech_romix` kernel is preserved alongside, selectable via an env var or `GPU_COOP_THREADS=0|1`. If we ship Increment 3 broken, users can fall back without re-installing.

### Increment 4 — Tune work-group size

Once Increment 3 is producing correct shares, find the optimal work-group size for cooperative-thread layout. Currently we pass `NULL` for local_work_size in `clEnqueueNDRangeKernel` (line 889). The kernel will run with whatever the driver picks. For 4-threads-per-hash, work-group size should be a multiple of 4 and large enough for one sub-group/warp (32 on NVIDIA, 64 on AMD). Trying `64`, `128`, `256` and picking the best is one short experiment.

This is the bridge to **#42 (autotune)**: it shows there's a meaningful work-group-size search to do per device.

---

## 5. Order of operations and checkpoints

| Step | Touches | Validation |
|---|---|---|
| 1 | New file `task-40-port-plan.md` (this doc) | — |
| 2 | Increment 1 → build → mine for 5 min | `gpu_hashrate > 129 KH/s`, shares still accepting, no "implausibly fast" |
| 3 | Increment 1 commit + version bump to `GPU-2026.0607.3` | clean tree |
| 4 | Increment 2 → build → mine 5 min | hashrate ≈ same as baseline (split overhead), shares still accepting |
| 5 | Increment 2 commit + bump `0607.4` | clean tree |
| 6 | Increment 3 → build → mine 10 min | hashrate **substantially** > baseline, share ratio unchanged |
| 7 | Increment 3 commit + bump `0607.5` | clean tree |
| 8 | Increment 4 → quick local sweep | best WGS noted; not committed until #42 |
| 9 | Move on to #42 (autotune) on a clean tree |

If any step's validation fails, that step's commit doesn't land. Previous increments stay.

---

## 6. Open questions

1. **Sub-group size on the 4060.** Likely 32. Need to read `CL_DEVICE_SUB_GROUP_SIZES_INTEL` or `clGetKernelSubGroupInfo` if available, otherwise assume 32 for the cooperative-thread layout's barrier placement. Not blocking for Increment 1.
2. **Should `dagtech_search` (single-kernel path) stay shipped after Increment 2?** Yes for now — it's a runtime fallback (`GPU_KERNEL_MODE=legacy`) until #40 is proven stable across devices.
3. **The reference miner's `hasher_combo_kernel` (gen+hash fused).** Worth porting after Increment 3 is stable — fewer launches per nonce, less per-kernel overhead. Skip for now to keep increments small.

---

## 7. Concretely, what's next

Increment 1 only touches `dagtech_gpu.cl:335–350` (`scrypt_romix`'s Fill and Mix inner loops). Smallest possible change that exercises the build/run/validate loop end-to-end. If you want to proceed, I'd:

1. Make the `uint4` edit in `dagtech_gpu.cl`.
2. Build via `tools/build-gpu-miner.ps1`.
3. Stop the running miner, swap in the new `dagtech-gpu-miner.exe` at `C:\dagtech-gpu-miner\bin\`, restart.
4. Watch metrics for 5 minutes — confirm `gpu_hashrate > 129 KH/s` and share-accept ratio unchanged.
5. If green, commit as `GPU-2026.0607.3: uint4 V-buffer access in scrypt_romix`. If red, revert.

No version bump needed during dev — we only bump on the commit at the end of an increment.
