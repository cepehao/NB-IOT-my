# UCI ambiguity and receive-event context validity

The static-v1 NPUSCH Control adapter carries one UCI bit without a transport-block CRC. `hasCrc=false` and `crcError=NaN` are intentional. Pilot and codeword coherence establish presence in the expected resource, not a globally unique transmitter identity.

## Measured waveform alias on MATLAB R2025b

At start tick 40 with the default two-repetition ACK profile, ACK=1 with RNTI 100 and NACK=0 with RNTI 2103 produce exactly identical 7680-sample waveforms. Maximum absolute sample difference is zero. Decoding either waveform with the RNTI-100 ACK grant yields bit 1 and `uciDetected=true`; pilot and codeword coherence are both 1.

This is covered by `TestUciAlias.knownNoiselessAliasHasIdenticalWaveform` and recorded in `work/optimization-evidence/o5-radio-characterization/uci-alias/uci-alias.mat` relative to the original project root. The existing foreign-RNTI presence tests exercise selected RNTIs only and do not prove rejection of every foreign control transmission.

No threshold can distinguish identical receiver inputs. The receiver must not invent a CRC, use the true transmitting UE, or consult channel transmission metadata to make the decision. The current static-v1 model therefore retains a physical ambiguity when an alias occupies an otherwise valid expected ACK resource. Statistics involving that situation must state this limitation.

## Logical protection of BS state

Queued receive events are accepted only when both the public BS context state and the complete current grant match the event:

| Event | Required state | Current schedule field |
|---|---|---|
| Msg3 | MSG3_RX | msg3Grant |
| Data | DATA_RX | payloadGrant |
| Msg4Ack | MSG4_ACK | ackGrant |
| ReceiptAck | RECEIPT_ACK | ackGrant |

Terminal contexts reject events. Context IDs and RNTIs increase monotonically within a simulation and are not recycled. The guard rejects stale, superseded and repeated completed events before RF decoding or state mutation. It uses BS state and public scheduling information only; it does not resolve the waveform alias inside a valid current ACK resource.

Two tests reproduced unwanted state/grant mutation before the guard. After the patch the complete suite passed 75/75. Separate baseline equivalence evidence is kept in `work/optimization-evidence/r2-equivalence.json` relative to the original root.

## Independent finite holdout with physical fading

Fresh external realization3800 and disjoint keyed substreams were evaluated after the state fix. Noise-only, random foreign ACK and random foreign NACK each had0falseACK/6000trials and0false-presence. Exact two-sided95% upper false-ACK probability is0.000614624 per condition. OwnACK and OwnNACK each had1000/1000correct-present decisions; the finite upper failure bound is0.003682084, not a false-ACK bound.

Signal conditions use independent three-tap Rayleigh fading, CFO uniform±200Hz, fixed conditional receive sampleSNR20dB, and post-TA residual delay±4.34samples (sync±3.84 plus quantization±0.5). Foreign RNTI is sampled uniformly from1..65535 excluding expected100. This conditional experiment does not include every possible NPRACH timing-estimator error or the full distribution of cell receive SNR. The finite sample does not disprove the exact alias above. Raw CFO/timing errors, keyed realization identities and false-case arrays are preserved in uci-fading-holdout/report.mat and per-condition MAT files.

## Model scope

An alias-free identity claim requires a separately justified protocol/resource design and new physical validation. It is not supplied by this patch. Changing UCI bits, adding a nonstandard ID or CRC, or filtering decoded ACKs with ground truth would change the protocol model and is not part of this optimization.
