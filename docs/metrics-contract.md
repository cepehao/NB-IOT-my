# Stage 1 metrics and runtime contract

This contract describes the existing Static WAVEFORM metrics and the
service/group fields selected for the completion plan. It covers specification
§§20, 27, 42, 46.8, 46.10, 46.13 and 47. Local known-answer checks do not replace
physical acceptance or the independent repetitions requested by §29 when
resources allow.

## KPI definitions

The horizon is `H = actualTick`, in ticks of `config.simulation.tickSeconds`.
Arrivals and starts occupy `[0,H)`; receiver completions at `H` are included.
Empty denominators produce NaN. Unfinished work is censored, never a loss.
Partial, stopped and failed run status remains part of every result.

| KPI | Numerator / denominator | Units / horizon |
| --- | --- | --- |
| Primary access success | RA attempts successfully completed / attempts started | probability; unfinished attempts remain in denominator |
| Primary user packet delivery | packets with all fragments received with CRC and valid decoded headers / created packets | probability; includes censored denominator |
| Primary useful throughput | unique delivered user payload bits / actual elapsed simulation seconds | bit/s; retransmissions and protocol overhead excluded |
| Collision probability | same-occasion same-preamble colliding RA attempts / RA attempts | analyzer collision label only, never a receiver decision |
| Mean RA attempts | total RA starts / created packets | attempts/packet, including zero-attempt and censored packets |
| Mean and p95 delay | delivered-packet completion minus arrival | ticks and seconds; delivered sample count retained; p95 interpolates sorted samples at rank 1+(n-1)*0.95 |
| Packet loss | dropped packets / created packets | probability; unfinished reported separately |
| Delivered fraction | delivered / created | same primary delivery numerator |
| Existing `dataBler` | failed Data CRC decodes / all Data CRC decodes | probability across ALL attempts, preserved |
| Existing `msg3Bler` | failed Msg3 CRC decodes / all Msg3 CRC decodes | probability across ALL attempts, preserved |
| First Data HARQ BLER | failed CRC on first actual UE emission / first emitted attempts decoded by H | probability per transport block; emitted receptions pending at H counted separately |
| First receiver HARQ BLER | failed CRC on first scheduled reception / first scheduled attempts decoded by H | probability; includes lost N0/noise reception, explicitly distinct from first emission |
| Post-HARQ outcome | accepted blocks / started blocks; exhausted/terminated blocks / started blocks | probability; censored blocks separate; retries are attempt ordinal > 1 |
| UL occupancy | union of actual allocation units / 48 frequency bins times two slots times H | fraction; overlapping UE counted once |
| DL occupancy | union of actual DL ticks excluding mandatory signals / available nonmandatory ticks | fraction |
| NPRACH occupancy | union of transmitted NPRACH allocation envelopes / 12 bins times two slots times H | full 45 kHz occasion envelope fraction; includes reserved hopping band rather than instantaneous active tone |
| Mean and maximum UE queue length | integral of actual UE queue length / UE-ticks; maximum queue at any sampled tick | packets/UE; includes head packet until local finish, including receipt waiting after BS delivery; excludes rejected arrivals |
| Mean and maximum BS pending requests | sum of observed pending request counts / sampled ticks; maximum | requests; observes BS state |
| Controller decisions / configuration switches | unavailable | explicit `applicable=false`, counts NaN, reason `controller-not-implemented` |

Existing CSV columns, order, values and window semantics are retained. New
window fields are appended. Arrival cohorts are classified at the export
horizon; completion intervals remain `(start,end]`.

## Saved report overview

The report card is a presentation summary of an existing result. It does not
run the simulator or alter scientific KPI definitions. New manifested saves
write `<stem>_report.json` before publishing `case-complete.json`; the marker
records its size and SHA-256 together with the KPI-window and final-summary CSV
files. The sidecar carries the case key, canonical configuration digest, and
only small fields used by the UI. The table export contract advances to version
6; the MAT `resultSchemaVersion` remains unchanged.

`numUE` is the configured total. `activeUE` is the count selected by the saved
traffic activity mode. `durationTicks` is the configured horizon;
`actualTick` and `durationSeconds` describe the observed run. `created`,
`delivered`, `dropped`, and `unfinished` are copied from the final KPI summary
and must satisfy `created = delivered + dropped + unfinished`. Unfinished
means not delivered by the observation horizon; it is not a claim about later
delivery.

For burst traffic, `planned` is the number of scheduled arrivals in the saved
arrival plan. For periodic traffic, it counts arrivals using the same random
phase, ceiling-to-tick rule, and half-open horizon as `generateArrivals`; an
arrival rounded to `durationTicks` is excluded. For Poisson traffic the exact
planned count is intentionally unknown in advance and remains NaN. Period is
not applicable to burst or Poisson traffic. Missing values remain NaN/blank,
never zero. The UI reader validates the sidecar, selected KPI CSV and linked
summary against the completion marker without loading MAT. Table export
versions 2–5 remain readable as partial summaries, and a standalone KPI CSV
remains readable with unavailable report metadata.

Window labels use the actual `startTick` and `endTick` intervals in the selected
KPI table. A shorter final interval is described as incomplete. This does not
change the KPI row values or their scientific interpretation.

## `harqSummary(journal, actualTick)`

Input is a separate append-only analyzer journal (schema 2), never receiver
truth. Records have `tick`, `kind`, `fields`. Fields identify `contextId`,
`packetSequence`, zero-based `blockIndex`, one-based `attempt`, plus start,
end and receiver-ready ticks for scheduled records. `decoded` records contain
real CRC and header acceptance; `emitted` records are appended immediately
after waveform insertion into the channel with event time at waveform start;
`terminal` records contain the resulting BS
state. No waveform/grant or RNG input is changed.

For `scheduled` records, `tick` is the reservation time and `fields.startTick`
is the grant's actual receiver start. `startTick` must be a finite real numeric
scalar, a nonnegative integer. A reservation counts as a started receiver
attempt only when both its journal tick and actual start are strictly before H.
Reservations for starts at or after H contribute no started/pending attempt or
started/censored block, even when reserved before H.

The HARQ block identity is `(contextId, packetSequence, blockIndex)`.
RaContextStore allocates monotone IDs without reuse, Msg3 fixes sequence/token
once, and a context handles a single packet. Fragment changes follow decoded
valid headers; HARQ ordinal changes only on failure. Sequence alone can wrap,
so is not a global key. Actual emissions map to the unique current public
context and grant; unmatched emissions are explicitly counted. Schema 2 also
stores the originating packet ID on Data emission records for the separate
live UI packet count; this ID does not replace the HARQ block identity or
change receiver KPI accounting. No global truth packet ID is used as HARQ KPI
identity. Scheduled receiver attempts are counted even when the UE misses
N0: the receiver still performs a real CRC decode, but that attempt is excluded
from the first actual transmission denominator. A successful CRC with an
invalid protocol header is a CRC success but an unaccepted block.

Schema 2 adds the originating `packetId` to matched and unmatched actual Data
emissions. The live UI uses these IDs to count unique packets whose data
transmission has started; repeated blocks count once, and Msg3/ACK emissions
do not count. Old schema-1 emission records without this ID have an unknown
packet count rather than an invented zero.

Algorithm: select events through H; group by explicit identity; count scheduled
attempts and real decoded CRCs; evaluate first actual emitted ordinal and first
receiver ordinal separately; derive
accepted/failed/censored blocks from explicit BS transitions. A first decode
at H counts; a receiver starting before H with a receiver-ready tick after H
remains pending and its unfinished block is censored. Legacy results
without this journal have `available=false`; no RNTI/time inference is used.
Tests: first success, recovered retry, exhausted retries, multiple blocks and
packets, CRC success but invalid header, pending retry, exact-H completion,
post-H exclusion, early reservation for starts at/after H (including retries),
legacy unavailable and malformed identity/start-tick rejection.

## `runtimeManifest(cfg, options)`

Options register project root, calibration file, model files, policy files,
external input files, supplied scenario and optional runner with its source
files. An external runner requires `runnerDependenciesDeclared=true` and its
defining file in `runnerFiles`. Captured workspace values require complete
`runnerInputs` registration matching the handle workspace and are hashed;
self-references to the same handle are ignored, other dynamic handles rejected.
This declaration is a caller assertion that
all result-affecting files/inputs are listed; undeclared dependencies fail
closed. Missing files, anonymous/dynamic runners, or unregistered runner source
are errors. Unknown external hooks and unsnapshotable object/function inputs
are rejected. Static production runner is registered by default; a supplied
scenario is passed to it, as well as hashed.

Algorithm: recursively canonicalize struct field order and encode numeric
class, shape, sparse/full and real/complex storage, and exact real/imaginary bytes (including complex channel taps);
hash UTF-8 canonical JSON and file bytes with SHA-256. Code hash covers production `src`, selected
experiment entry points and setup, excluding tests/docs/results. Runtime,
result schema, calibration, model, policy, runner and input identities are
separate. Code changes invalidate resume; README changes do not. Policy hash
includes configuration policy and registered policy files. Model/input hashes
include contents of registered external files. Case key hashes method,
canonical configuration including P and RA/DT share, traffic/scenario,
external realization, calibration and registered model/policy/runner/input
identities; output folder is excluded. Configuration snapshots keep the
original legacy hash for reading schema-1 bundles.

New results use result schema 2 and marker schema 2, runtime identity schema 1.
Marker/MAT identity must agree; unsupported versions and malformed/damaged
metadata/files return rejected reports. Schema-1 manifested bundles remain
verifiable and legacy save/load exports remain readable. They cannot satisfy
a schema-2 runtime resume expectation. The MATLAB/LTE environment is retained.

Tests: canonical order/output relocation, P/RA-share/method/traffic/realization
separation, README stability, source changes, calibration replacement, external
model/policy/input mutations, registered runner source mutation, unregistered
runner rejection, new calculate/verify/resume lifecycle, incompatible and
damaged marker rejection, legacy readability and no reuse as a new identity.

## Radio diagnostics for the completion roadmap

The following measurements are separate from controller features. Simulator
truth may be joined to receiver outcomes only after reception, for offline
diagnostics. Every ratio keeps its numerator and denominator counts. If the
denominator is zero, the ratio is `NaN`; counts remain zero. Only complete
NPRACH occasions whose receiver decision is available by horizon `H` enter the
denominators; a decision ready exactly at `H` is included.

| Measurement | Definition and denominator | Source / units | Local proof and remaining acceptance |
| --- | --- | --- | --- |
| NPRACH miss | A transmitted `(occasionId,nInit)` key with no receiver candidate for that same key is one missed preamble key. Multiple UE attempts on the same key still form one preamble key; per-attempt access outcomes remain separate. `missProbability = missed keys / transmitted keys`. | Truth `msg1` plus the post-reception `nprach_detection` candidates; count and probability (0–1). | Synthetic empty/hit/miss/boundary cases in Task 2; a short physical example in Task 6; physical curves remain Task 7. |
| NPRACH false alarm | A detected `(occasionId,nInit)` key with no matching transmitted key is one false alarm. `falseAlarmProbability = false detected keys / untransmitted configured keys` across complete occasions. The configured `nInit` set, not a guessed count, defines available indices. | Receiver candidates joined to truth after detection; count and probability (0–1). | Synthetic false-alarm and zero-denominator cases in Task 2; external physical acceptance in Task 7. |
| Logical collision | Two or more distinct UE attempts with the same `(occasionId,nInit)`. Report groups and participating attempts separately. `logicalCollisionAttemptProbability = attempts in such groups / all started NPRACH attempts`. | Truth `msg1`; groups/attempts and probability (0–1). | Existing result already has same-index collision labels; tests must keep that label distinct from physical overlap. External matrix remains Task 7. |
| Physical overlap | Two distinct transmitted NPRACH signal components whose received, channel-propagated sample supports at the BS share at least one sample, before receiver noise is added. Count unique unordered pairs. `physicalCollisionAttemptProbability = attempts with at least one overlapping partner / all started NPRACH attempts`. Different indices can overlap; equal indices without temporal overlap do not. | Per-transmission channel components and their sample intervals; pair/attempt counts and probability (0–1). | Synthetic same-index/non-overlap and different-index/overlap cases in Task 2; short physical check in Task 6; full physical matrix in Task 7. |
| Capture | Evaluate only physically overlapping pairs. Compare their integrated received component powers over the shared interval. For an unequal-power pair, it is a capture event only if the stronger attempt completes RA and the weaker attempt does not. The denominator `eligiblePairs` contains only pairs with unequal measured powers on the shared interval and known outcomes for **both** attempts. `captureProbability = capturedPairs / eligiblePairs`; equal-power pairs (`equalPowerPairs`) and unequal-power pairs with an unknown outcome (`censoredPairs`) are counted separately and excluded. A zero denominator gives `NaN`, never 0. | Per-transmission received power after channel/fading, joined after reception to truth `ra_success`; power in W or dBm, pair count and probability (0–1). | Known strong-success/weak-failure and equal-power fixtures in Task 2; short physical check in Task 5; near-far probability curves in Task 7. |
| Reference SNR | Existing link-budget SNR: received power minus thermal-noise power over the configured 180 kHz reference bandwidth, before small-scale fading and interference. This is not an instantaneous SINR or a receiver estimate. | `scenario.linkBudget.referenceSnrUlDb` / `referenceSnrDlDb`; dB, per UE. | Existing link-budget checks are retained; no need to rerun them unless the calculation changes. |
| Instantaneous SINR | Desired received component power divided by the sum of other received components on the same time-frequency interval plus receiver noise, after channel/fading. Compute powers over the same occupied resource and interval; label it `diagnosticTruth`, never a BS-observed feature. | Reception-time component powers; dB, per reception/UE. | Known component-power fixture in Task 2 and short physical comparison in Task 6; full SNR/SINR acceptance in Task 7. |
| Timing/CFO estimate | Keep configured truth and receiver estimates in separate fields. NPRACH estimate comes from the detected candidate; NPUSCH estimate comes from the receiver measurements. Errors are estimate minus configured truth. | Configured received-path delay is derived from propagation distance, `syncOffsetSeconds`, and applied timing advance; configured CFO is `cfoHz`. Estimates come from NPRACH candidate and NPUSCH receiver output; seconds and Hz. | Synthetic sign/identity cases and a short physical run in Task 2; readback/export in Task 3; physical parameter sweeps in Task 7. |

### Service outage and group contract

The specification names outage in §46.13 but defines no threshold or formula.
This project therefore reports a service-level outage and does not label it a
radio outage or an irreversible UE failure.

For a completed run, let H be actualTick, measured in model ticks using
config.simulation.tickSeconds (1 ms per tick in the current profile). A demand UE
has created > 0. An outage UE has created > 0 and delivered == 0 by H.
Service-outage probability is outage UE count / demand UE count. It is a UE-level
fraction, not dropped packets / created packets. Include completions at H, as in
the rest of this contract.

Expose available, actualTick, demandUeCount, outageUeCount and
unfinishedUeCount with the probability. available is true only when the supplied
run is complete. For a partial/stopped/failed run, retain H and diagnostic
counts, set available=false, and set the full-horizon probability to NaN. For a
completed run with no demand UEs, keep zero counts and NaN probability because
the denominator is zero.

Read group membership and counters from the existing ueSummary columns indoor,
coverageClass, created, delivered, dropped, unfinished, raAttempts, raSuccesses,
raFailures and raUnfinished. Group independently by indoor/outdoor and by
coverageClass. These are two separate dimensions, not a cross-tab; current
scenario construction produces CE0 for every UE.
Missing or unknown attributes map to unknown, never to outdoor or a guessed
coverage class. Keep known empty categories with zero counts and NaN ratios.
For each group preserve UE count, demand UE count, outage UE count, created,
delivered, dropped and unfinished packet counts, packet delivery probability
(sum delivered / sum created), and RA started/success/failure/unfinished counts.
The group service-outage probability is outage UE count / demand UE count.
Compute every ratio from summed counts, never as a mean of per-UE percentages.
Packet counts use packets; RA counts use attempts; probabilities are fractions
from 0 to 1.

The service struct is identified as service-outage-horizon-v1 and contains
available, actualTick, demandUeCount, outageUeCount, unfinishedUeCount and
probability. The group table contains groupDimension, groupValue, UE/demand/
outage counts, packet and RA counters, packet delivery probability and
service-outage probability. Persist the service summary in
result.kpiSummary.service and the group table in result.groupKpi. Export the
table to _groups.csv and show the definition, H, availability and counts in
the final summary/UI. Missing service/group fields in legacy results mean no
data; they do not make the older result invalid and must not be displayed as
zero. These true aggregate group labels and outcomes are not ML features.

The group dimensions follow §§46.8/46.10 and the existing UE summary. The
definitions and known-answer checks are local implementation evidence only;
the Stage 2 physical matrix and independent repetitions remain separate.

Implementation status: `serviceKpi` runs on the finalized UE summary, after
packet and RA counters are complete. `result.kpiSummary.service` and
`result.groupKpi` are saved in MAT; manifested and legacy exports add
`_groups.csv` when the field is present. Table export version 4 identifies the
new group table, while older version 2/3 packages remain verifiable. The final
summary reads only saved fields and labels missing legacy fields as no data.
Task 2 known-answer, no-demand, partial, grouped export/readback and formatting
checks passed; current-PC physical validation is still pending.

## Window outcome diagnostics (`window-diagnostics-v1`)

`result.dataset.diagnostics` contains one row for every closed observation and
target window, in observation order. The four key fields are `realizationId`,
`windowId`, `startTick` and `endTick`; they must form a unique one-to-one key
match with both observations and targets. Dataset assembly joins these rows by
key, so the source tables may arrive in different row orders. All time fields
and mean delay are in model ticks. Count fields are non-negative integer
counts. Availability fields are boolean: logical values or numeric 0/1; any
other numeric value is invalid.

Windows retain the dataset boundary convention: arrivals and attempt starts are
assigned in `[startTick,endTick)`, while completed outcomes are assigned in
`(startTick,endTick]`. Thus a receiver outcome ready exactly at `endTick` belongs
to the window ending at that tick. `outcomeHorizonTick` records the run's
`actualTick` for each row.

`logicalAvailable` governs `logicalCollisionGroups` and
`logicalCollidingAttempts`; `physicalAvailable` governs `physicalOverlapPairs`
and `physicalCollidingAttempts`; `accessAvailable` governs `successfulAccesses`
and `unfinishedAccessCohort`; `retryAvailable` governs
`raRetryTransmissions`. When one of these sources is unavailable, its governed
counts are `NaN`, never zero. `delayAvailable` is true only when delivered
packets provide at least one delay sample. With no delivered sample,
`delaySampleCount` is zero and `meanDelayTicks` is `NaN`; if packet data itself
is unavailable, both delay values are `NaN`. `unfinishedPacketCohort` is `NaN`
when packet data is unavailable. Known zero counts remain zero when their
source is available.

These are outcome-only measurements calculated after the simulation from its
journals. They are not observation features and must never be supplied to the
controller. The manifested diagnostics CSV is identified by table export
version 5 and `diagnosticsSchemaVersion="window-diagnostics-v1"`; historical
versions 2, 3 and 4 keep their original file sets.
Availability columns in the diagnostics CSV use `true`/`false` tokens so a
default MATLAB `readtable` import may return them as text or cells; MATLAB
R2025b returns cell text such as `{'true'}`. Consumers should explicitly
interpret only the exact `true` and `false` tokens and must not assume that the
imported column has logical type. The MAT snapshot retains the original
availability values and types (logical or numeric 0/1); it does not normalize
every column to logical.
