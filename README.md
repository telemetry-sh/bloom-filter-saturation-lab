# Bloom Filter Saturation Lab

Probably present. Definitely wrong.

This deterministic GNU Guile simulator shows how a Bloom filter can keep the
same tiny memory footprint while the meaning of its `maybe present` answer
degrades. The same seeded candidate stream is replayed through four policies:

- **Fixed + definitive** treats every positive as proof and drops false-positive
  new keys.
- **Verify positives** checks every positive against an authoritative store,
  preserving correctness while moving the saturation cost to backend traffic.
- **Scalable layers** opens successively larger filters before the active layer
  reaches its configured cardinality threshold.
- **Rotating generations** keeps two half-window filters and forgets membership
  in lockstep with an explicit deduplication TTL.

With the default workload, the fixed filter’s modeled false-positive
probability climbs above 36% and drops roughly 99,000 valid candidates. Verifying
positives loses none, but performs roughly 289,000 authoritative reads. Scalable
layers hold the modeled peak near 1.2% while growing from 0.24 MiB to 1.67 MiB.

## Technology

- GNU Guile 3 / Scheme analytical model
- Guile’s built-in HTTP server
- Vanilla HTML, CSS, JavaScript, and Canvas interface
- SRFI-64 model tests plus live HTTP integration tests
- Non-root Debian container
- No application package dependencies

## Run it

Requires GNU Guile 3, Node.js, Python 3, `curl`, `jq`, Make, and a POSIX
environment.

```bash
make run
```

Open [http://localhost:8080](http://localhost:8080). The server binds to
loopback by default. Set `HOST=0.0.0.0` only when a non-loopback bind is
intentional.

The simulation is also available as JSON:

```bash
./bloom-filter-saturation-lab --json | jq

curl 'http://localhost:8080/api/simulate?candidates_per_second=12000&new_key_percent=85&expected_items=300000&bits_per_item=10&hash_functions=7&run_seconds=180&rotate_window_seconds=45&layer_threshold_percent=70&backend_p99_ms=18&seed=28411'
```

## Verify it

```bash
make check
make docker-check
```

`make check` compiles both Scheme modules, runs twelve deterministic model and
normalization assertions, checks the CLI JSON, validates the browser script,
starts the real server on an ephemeral loopback port, and exercises assets,
query clamping, health, API shape, invalid methods, missing paths, and host
validation.

`make docker-check` builds the image, verifies UID 10001 in the running
container, and probes its health and simulation endpoints through Docker’s
randomly published loopback port.

## The semantic trap

A Bloom filter has asymmetric answers:

| Answer | Meaning | Safe interpretation |
| --- | --- | --- |
| Definitely absent | At least one selected bit is zero | The key is not represented |
| Maybe present | Every selected bit is one | The key may be real or a collision |

The first answer is proof under the usual Bloom filter assumptions. The second
is a probability. Treating `maybe present` as authoritative is only safe when
the resulting false-positive behavior is an accepted product property.

## Telemetry model

| Field | Why it matters |
| --- | --- |
| `filter.bits` | The fixed memory budget, which can look deceptively healthy |
| `filter.set_bits` | The numerator needed to calculate fill |
| `filter.fill_ratio` | A direct signal of declining selectivity |
| `filter.hash_functions` | Connects the configured hash count to CPU and error |
| `filter.estimated_fpp` | The theoretical error budget implied by `m`, `n`, and `k` |
| `filter.observed_false_positives` | Sampled disagreements with authoritative truth |
| `filter.layer_count` | Growth and multi-filter lookup work |
| `filter.generation` | The time window that supplied a membership answer |
| `membership.decision` | `definitely-absent` versus `maybe-present` |
| `membership.authority` | Bloom filter versus source of truth |
| `backend.verification_ms` | Latency paid to recover correctness |
| `valid_events_dropped` | Business impact of trusting false positives |

Graph estimated and sampled false-positive rates beside filter fill, inserted
cardinality, layer or generation count, backend verification traffic, and the
business consequence. Alert before a capacity assumption becomes a correctness
incident.

## Model mechanics

For a filter with `m` bits, `k` hash functions, and `n` inserted keys, the
simulator uses the familiar approximation:

```text
fill ≈ 1 - exp(-k × n / m)
false-positive probability ≈ fill^k
```

The fixed strategies keep `m` constant. Verification uses the same saturated
filter but sends every positive—real duplicate or collision—to the modeled
authoritative backend. Scalable mode adds a layer with twice the preceding
capacity once the active layer reaches the configured threshold; membership
checks combine the error probability of every layer. Rotating mode divides the
fixed bit budget between two generations and resets the older generation every
half-window.

A seeded ±3% observation factor makes false-positive counts look like measured
traffic while preserving exact reproducibility.

## Model boundaries

This is an explanatory analytical simulator, not a Bloom filter implementation,
benchmark, or production capacity calculator. It does not hash real keys or set
real bits. The classic approximation assumes ideal independent uniform hashes;
finite filters and real hash construction can differ. The simulator also treats
candidate mix as stationary and assumes rotating generations match the product’s
actual duplicate-validity window.

Real behavior depends on hash quality, key distribution, concurrency, atomic
updates, cache locality, serialization, replication, rebuild strategy, deletion
semantics, and whether the authoritative store is complete and available.
Measure observed false positives against sampled ground truth before making a
probabilistic answer authoritative.

## References

- [NIST: A New Analysis of the False-Positive Rate of a Bloom Filter](https://www.nist.gov/publications/new-analysis-false-positive-rate-bloom-filter)
- [GNU Guile 3.0 reference manual](https://www.gnu.org/software/guile/manual/)
- [GNU Guile built-in web server](https://www.gnu.org/software/guile/manual/html_node/Web-Server.html)

Built with Scheme and [telemetry.sh](https://telemetry.sh) in mind. MIT licensed.
