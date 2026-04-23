# Project-Specific Function Call Graph

Generated from current codebase on 2026-04-23.
Main references:
- `run_demo.m`
- `run_offline_training.m`
- `src/default_params.m`
- `src/simulate.m`
- TX/RX core modules under `src/tx`, `src/sync`, `src/coding`, `src/channel`, `src/mitigation`, `src/source`

## 1) Main Entry (run_demo)

```mermaid
flowchart TD
    A[run_demo] --> B[default_params]
    B --> C[resolve_mitigation_methods]
    A --> D[local_required_ml_models]
    D --> E[load_pretrained_model x N]
    A --> F[simulate]
    F --> G[results.summary]
    A --> H[local_print_adaptive_action_distribution]
```

## 2) End-to-End Simulation (simulate)

```mermaid
flowchart TD
    A[simulate] --> B[resolve_waveform_cfg]
    A --> C[resolve_mitigation_methods]
    A --> D[local_build_receiver_method_plan_local]

    A --> E[load_source_image]
    E --> F[image_to_payload_bits]
    F --> G[build_tx_packets]
    G --> G1[build_outer_rs_packet_plan]
    G --> G2[build_session_frames]

    A --> H[measure_tx_burst]
    H --> I[resolve_link_budget]
    I --> J{for each Eb/N0 or Eb/N0-JSR point}

    J --> K[adapt_channel_for_sps]
    J --> L[signal_noise_kl]
    J --> M{warden enabled}
    M -->|yes| N[warden_energy_detector]
    M -->|no| O[skip]

    J --> P{for each frame}
    P --> Q[local_run_single_frame_local]
    Q --> R[local_decode_frame_methods_local]
    R --> S[local_decode_single_method_local]

    S --> T[outer_rs_recover_payload]
    T --> U[payload_bits_to_image]
    U --> V{packet conceal enabled}
    V -->|yes| W[conceal_image_from_packets]
    V -->|no| X[use communication image]
    W --> Y[image_quality]
    X --> Y

    J --> Z[accumulate BER/PER/PSNR/SSIM/KL]
    Z --> AA[select_example_point_nearest_mean_local]

    A --> AB[estimate_spectrum]
    A --> AC[make_summary]
    A --> AD{p.sim.saveFigures}
    AD -->|yes| AE[make_results_dir]
    AE --> AF[save results.mat]
    AE --> AG[save_figures]
    AE --> AH[export_thesis_tables]
```

## 3) RX Per-Method Decode Chain (Core)

```mermaid
flowchart TD
    A[local_decode_single_method_local] --> B[local_build_packet_nominal_local]
    B --> C[capture_synced_block_from_samples]
    C --> C1[adaptive_frontend_bootstrap_capture]
    C --> C2[frame_sync]
    C --> C3[extract_fractional_block]
    C --> C4[mitigate_impulses]

    B --> D[local_try_decode_header_candidates_local]
    D --> D1[decode_phy_header_symbols]
    D1 --> D2[parse_phy_header_bits]

    A --> E[demodulate_to_softbits]
    E --> F[deinterleave_bits]
    F --> G[fec_decode]
    G --> H[descramble_bits]
    H --> I[recover_payload_packet_local]

    I --> J[packet_data_crc_valid_local]
    I --> K[parse_session_header_bits]

    A --> L[outer_rs_recover_payload]
    L --> M[decrypt_payload_packets_rx_local or chaos_decrypt_bits]
    M --> N[payload_bits_to_image]
    N --> O[conceal_image_from_packets]
    O --> P[image_quality]
```

## 4) TX Packet Build Chain (Core)

```mermaid
flowchart TD
    A[build_tx_packets] --> B[resolve_outer_rs_cfg]
    A --> C[build_outer_rs_packet_plan]
    A --> D[build_session_header_bits]
    A --> E[build_session_frames]

    A --> F{for each packet}
    F --> G[derive_packet_state_offsets]
    F --> H[build_phy_header_bits]
    H --> I[encode_phy_header_symbols]

    F --> J[derive_packet_scramble_cfg]
    J --> K[scramble_bits]
    K --> L[fec_encode]
    L --> M[interleave_bits]
    M --> N[modulate_bits]
    N --> O[dsss_spread]
    O --> P[sc_fde_payload_pack]
    P --> Q[derive_packet_fh_cfg]
    Q --> R[fh_modulate or fh_modulate_samples]
    R --> S[pulse_tx_from_symbol_rate]
```

## 5) Offline Training Chain

```mermaid
flowchart TD
    A[run_offline_training] --> B[default_params]
    B --> C[resolve_mitigation_methods]
    C --> D[local_required_ml_models]

    D --> E{needed model kinds}
    E --> E1[ml_train_impulse_lr]
    E --> E2[ml_train_cnn_impulse]
    E --> E3[ml_train_gru_impulse]
    E --> E4[ml_train_interference_selector]
    E --> E5[ml_train_narrowband_action]
    E --> E6[ml_train_fh_erasure]
    E --> E7[ml_train_multipath_equalizer]

    E1 --> F[models/*.mat]
    E2 --> F
    E3 --> F
    E4 --> F
    E5 --> F
    E6 --> F
    E7 --> F
```

## 6) Quick Navigation Index (Most Important Files)

- Entrypoints:
  - `run_demo.m`
  - `run_offline_training.m`
- Global configuration:
  - `src/default_params.m`
- Main scheduler:
  - `src/simulate.m`
- TX build:
  - `src/tx/build_tx_packets.m`
  - `src/tx/build_session_frames.m`
- RX sync/equalization:
  - `src/sync/capture_synced_block_from_samples.m`
  - `src/sync/frame_sync.m`
  - `src/sync/multipath_equalizer_from_preamble.m`
- Coding/FEC/RS:
  - `src/coding/build_outer_rs_packet_plan.m`
  - `src/coding/outer_rs_recover_payload.m`
- Channel and mitigation:
  - `src/channel/adapt_channel_for_sps.m`
  - `src/channel/channel_bg_impulsive.m`
  - `src/mitigation/resolve_mitigation_methods.m`
  - `src/mitigation/mitigate_impulses.m`
- Image and recovery:
  - `src/source/image_to_payload_bits.m`
  - `src/source/payload_bits_to_image.m`
  - `src/recovery/conceal_image_from_packets.m`
- Output:
  - `src/analysis/make_summary.m`
  - `src/io/save_figures.m`
  - `src/io/export_thesis_tables.m`
