# ECG Processor — Rhythm-Level AF Detection (Hardware)

This repository implements a complete FPGA hardware pipeline for **rhythm-level Atrial Fibrillation (AF) detection**, corresponding to **Section 3** of the accompanying book chapter *"A Unified Framework for ECG-Based Arrhythmia Analysis on Wearable Devices."*

The pipeline denoises raw ECG signals with a lifting-based discrete wavelet transform (LDWT), extracts RR-interval features, and classifies each analysis window as AF / non-AF using a depth-stratified, fully pipelined Random Forest (RF) classifier, targeting the Xilinx Kria KV260 platform for real-time, low-power operation on wearable devices.

## Overview

The system consists of three stages:

1. **ECG denoising via LDWT** — raw ECG samples (MIT-BIH Arrhythmia Database, records 202/203/210) are converted to 16-bit fixed-point and passed through a 4-level lifting-based DWT using the Daubechies-4 wavelet, separating approximation and detail coefficients to isolate noise from clinically relevant morphology (QRS complex, P-wave, T-wave).
2. **RR-interval feature extraction** — R-peaks are detected directly from the LDWT detail coefficients, and three features are computed per 30-second analysis window (15-second overlap): `RRμ` (mean RR interval), `pRR20` (% of successive RR differences > 20 ms), and `pRR62.5` (% of successive RR differences > 62.5 ms).
3. **Random Forest classification** — a 50-tree, max-depth-5 Random Forest, trained offline in scikit-learn (91.8% software accuracy), converted via Conifer to synthesizable C++, and implemented in Vitis HLS 2023.1, classifies each window as AF / non-AF using a depth-stratified, fully pipelined architecture with per-tree early termination.

## Repository structure

```
ecg-processor-git/
├── README.md
├── figures/
│   ├── ldwt-final-drawio.png   # Figure 1 — LDWT hardware architecture
│   └── ldwt-arch-final.png     # Figure 3 — Random Forest classifier pipeline architecture
└── pre-processing/
    └── ldwt.v                  # LDWT (Daubechies-4) lifting engine, CSD-style shift-add arithmetic
```

> The Random Forest hardware source (HLS/C++, Conifer-generated files, testbenches) is finalized and will be pushed to this repository shortly.

## 1. LDWT Module — Denoising Front-End

The lifting scheme factors the DWT into four sequential in-place steps — Split, Predict, Update, Second Predict — plus a final scaling step, reducing memory use by 50% and halving the arithmetic operations compared to direct convolution. `pre-processing/ldwt.v` implements this for the Daubechies-4 wavelet:

| Step | Operation | Coefficient (exact) | Shift-add approximation |
|---|---|---|---|
| First Predict | `d⁽¹⁾[n] = y_odd[n] − α·(y_even[n] + y_even[n+1])` | α = (√3−1)/4 ≈ 0.1830 | `(x>>2) + (x>>3) + (x>>5)` |
| Update | `a⁽¹⁾[n] = y_even[n] + β·(d⁽¹⁾[n] + d⁽¹⁾[n−1])` | β = √3/4 ≈ 0.4330 | `(x>>2) + (x>>3)` |
| Second Predict | `d⁽²⁾[n] = d⁽¹⁾[n] + γ·a⁽¹⁾[n]` | γ = (√3+1)/4 ≈ 0.6830 | `(x>>1) + (x>>4)` |
| Scaling | `a_out = K·a⁽¹⁾[n]`, `d_out = (1/K)·d⁽²⁾[n]` | K = 1/√2 ≈ 0.7071 | `(x>>1) + (x>>4)` |

This multiplier-less (shift-and-add / CSD-style) approach avoids dedicated DSP/multiplier hardware for the irrational lifting coefficients, forming the basis of the low-resource architecture below.

**Module interface:**

```verilog
module ldwt_db4_csd (
    input  clk,
    input  rst,
    input  signed [15:0] y_even,       // y[2n]
    input  signed [15:0] y_odd,        // y[2n+1]
    input  signed [15:0] y_even_next,  // y[2n+2]
    output reg signed [15:0] a_out,    // approximation coefficient
    output reg signed [15:0] d_out     // detail coefficient
);
```

- **Inputs:** `y_even`, `y_odd`, `y_even_next` are 16-bit signed fixed-point samples split from the input signal (even/odd indexed, per the lifting scheme's Split step).
- **Outputs:** `a_out` (approximation coefficient) and `d_out` (detail coefficient), registered on the clock.
- Internal 32-bit temporaries (`temp1`–`temp3`) prevent overflow during shift-add accumulation before truncation back to 16 bits.

### LDWT system architecture (Figure 1)

The full folded LDWT system wraps the lifting engine above with two address generation units (AU1 for reads, AU2 for writes), dual-port working memory (BRAM A) for intermediate approximation coefficients, single-port output memory (BRAM B) for final sub-band coefficients, and a 7-state FSM that sequences the four decomposition levels.

<img width="1253" height="379" alt="ldwt-final drawio" src="https://github.com/user-attachments/assets/567eb662-e0f8-47a3-b393-5bf900ebc679" />


*Figure 1: LDWT hardware architecture — State Machine, Address Units (read/write), Lifting Engine, and BRAM working/output memory.*

### LDWT hardware results

Post-optimization resource utilization (folded, multiplier-less architecture):

| Resource | Used | Available | Utilization |
|---|---|---|---|
| LUTs | 323 | 20,800 | 1.55% |
| Flip-Flops | 261 | 41,600 | 0.63% |
| BRAM Tiles | 2 | 50 | 4.00% |
| DSP Slices | 0 | 90 | 0.00% |
| IO Pins | 52 | 106 | 49.06% |
| BUFG | 1 | 32 | 3.13% |

- **Timing:** full closure with WNS = 2.345 ns, WHS = 0.234 ns; maximum operating frequency 130.628 MHz (7.655 ns period), a 23.45% margin over the 100 MHz target. Critical path is dominated by adder logic (2.145 ns) and shifter logic (1.823 ns).
- **Throughput:** N = 512 samples processed in 1,150 clock cycles (11.5 µs at 100 MHz) — well within the 1.42 s real-time window.
- **Power:** 0.125 W total on-chip (dynamic 0.092 W / 73.6%, static 0.033 W / 26.4%); 2.81 pJ per sample (1.44 nJ per 512-sample transform).
- **Accuracy vs. MATLAB reference:** overall correlation coefficient 0.9991, SNR 42.25 dB, MSE 0.0014, RMSE 0.037. Per-level metrics improve progressively from d1 to a4:

  | Level | Correlation | RMSE | SNR (dB) |
  |---|---|---|---|
  | d1 | 0.9987 | 8.2341 | 38.45 |
  | d2 | 0.9990 | 6.7823 | 40.12 |
  | d3 | 0.9991 | 5.3412 | 42.34 |
  | d4 | 0.9993 | 4.1234 | 44.56 |
  | a4 | 0.9996 | 3.2145 | 46.78 |

- **Scalability:** logic resources (LUTs/FFs) stay constant across window sizes, while cycle count and BRAM usage scale linearly — N=256 (580 cycles, 12 Kb), N=512 (1,150 cycles, 24 Kb), N=1024 (2,300 cycles, 48 Kb), N=2048 (4,600 cycles, 96 Kb). Throughput of 44.52 Msamples/s supports up to 12 ECG channels at 90% utilization.

## 2. Random Forest Classifier — Rhythm Classification Back-End

### Model training

A 50-tree Random Forest with maximum depth 5 was trained offline in scikit-learn on features extracted from MIT-BIH records 202, 203, and 210 (selected for their AF episodes), achieving **91.8% software accuracy**. Training windows were built from 30-second segments with 15-second overlap; a window was labeled AF if more than 50% of its samples overlapped annotated AF regions.

The trained model is exported via pre-order tree traversal into a flat, sequential node representation (feature index, threshold, left/right child offsets for internal nodes; class label for leaves) suitable for ROM/BRAM initialization, then converted with **Conifer** into synthesizable C++ and implemented in **Vitis HLS 2023.1**.

### Depth-stratified pipelined hardware architecture

Rather than one hardware module per tree level (the conventional approach), the design recognizes that every tree shares the same maximum depth bound and pipelines by **depth**, not by tree count:

- **D = 5 pipeline stages** (the maximum tree depth), each evaluating one level across all **N = 50 trees in parallel** — turning an N-way combinational tree evaluation into a D-stage pipeline with N-way spatial parallelism per stage.
- **Per-tree early termination:** each tree keeps three state registers — current node position, an active/dormant flag, and its accumulated leaf value. When a tree reaches a leaf, it stores its prediction, deactivates, and consumes zero DSP/LUT resources in later stages (variable-depth trees in the ensemble range from 11–39 nodes, so trees "thin out" stage by stage).
- **Oblique and axis-aligned splits:** each internal node computes a weighted feature sum via 3 simultaneous multiply-accumulate operations (3 input features), compared against a threshold — 16-bit fixed-point with 6 integer bits, giving ±0.0001 precision versus floating point.
- **Macro-based explicit unrolling** ensures full spatial parallelism across all 50 trees despite HLS pointer-indirection limitations.
- **Memory hierarchy:** static tree structure (thresholds, feature indices, topology) is synthesized as distributed ROM in the LUT fabric so all 50 trees can be accessed simultaneously without port contention; dynamic traversal state (150 registers total = 3 state variables × 50 trees) lives in fully partitioned register arrays for zero-wait-state access, keeping BRAM free for other system components.
- **Reduction and normalization:** a logarithmic adder tree sums the 50 tree predictions, followed by `S = alpha · S_raw + beta` normalization to produce the final classification score.
- **Pipeline timing:** 7 total stages (5 traversal + 1 reduction + 1 normalization), unit initiation interval (a new inference can start every clock cycle), 200 MHz clock, 35 ns single-inference latency.

### Random Forest pipeline architecture (Figure 3)

<img width="2048" height="1117" alt="ldwt-arch-final" src="https://github.com/user-attachments/assets/0c93dffb-27ac-4200-8f21-cce5219dfdad" />


*Figure 3: Depth-stratified Random Forest classifier pipeline — 50 parallel Tree Evaluation Units (TEUs) per stage across 5 stages, with early termination, a logarithmic adder tree, and score normalization.*

### Random Forest hardware results

Post-implementation resource utilization on the Xilinx Kria KV260:

| Resource | Used | Available | Utilization |
|---|---|---|---|
| LUTs | 7,957 | 20,800 | 38.3% |
| LUT-RAM | 624 | 9,600 | 6.5% |
| Flip-Flops | 109 | 41,600 | 0.3% |
| DSP48E1 | 438 | 90 | 486.7%* |
| BRAM (36 Kb) | 0.5 | 50 | 1.0% |

\* *DSP48E1 usage exceeds the device's nominal count because Vivado synthesizes multiple multiply-accumulate operations per DSP block via resource sharing and time-multiplexing (using the DSP48E1's pre-adder/post-adder capability), fitting all 150 parallel multiplications (3 per tree × 50 trees) into 90 physical DSP blocks while preserving single-cycle performance.*

The low flip-flop count (109, 0.3%) reflects the fully partitioned traversal-state design, while the LUT count (7,957) validates complete spatial unrolling of the 50-tree ensemble — most of it tree-structure storage (thresholds, feature indices, node values) synthesized as distributed ROM rather than BRAM. Minimal BRAM usage (0.5 tiles) leaves headroom for integration with larger systems needing data buffering or external memory interfacing.

## Reference

This work corresponds to Section 3, "Rhythm-level AF detection using an efficient RF-based pipelined hardware," of the associated book chapter.
