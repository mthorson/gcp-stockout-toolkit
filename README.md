# GCP STOCKOUT Toolkit

Tools and notes for getting past Compute Engine **`STOCKOUT`**
(`ZONE_RESOURCE_POOL_EXHAUSTED`) errors on GCP, current as of 2026. A STOCKOUT is
what you hit when a zone has run out of the machine type you asked for:

```
Error: ... The zone 'projects/PROJECT/zones/us-central1-c' does not have enough
resources available to fulfill the request. (state: STOCKOUT, resource type: compute)
```

The repository includes a short capacity playbook and tools for polling on-demand
capacity, accumulating reservations, running read-only preflight checks, and safely
releasing everything afterward.

---

## What a STOCKOUT actually is

Here's the thing about a STOCKOUT: it is often transient and applies to the zonal
resource configuration you requested, not every resource in the zone. Google can't
fit that request in that zone at the moment. It's easy to confuse with a quota
error, but they aren't the same. Quota is the ceiling on your own account, while a
STOCKOUT is a physical capacity shortage. Capacity changes frequently, so a few
things follow from that:

- The same VM will often come up fine in a different zone in the same region.
- A different machine family with the same architecture may have room when the
  popular one (N2, C3) is tapped out.
- Retrying the exact same request can work as capacity changes. Your odds improve
  when you retry at a sensible interval and spread attempts across more targets.

---

## The 2026 capacity playbook

| Situation | Best tactic |
|-----------|-------------|
| "I need a VM **right now**" | Poll on-demand across zones and machine families with [`grab_capacity.sh`](#1-grab_capacitysh-poll-for-on-demand-capacity) |
| "I need **N reserved** slots in my project's shared capacity pool" | Create **on-demand reservations** with [`grab_reservations.sh`](#2-grab_reservationssh-accumulate-reservations) |
| "I'll need capacity on a **future date**" | **Future reservations** let you reserve zonal capacity up to a year ahead (`gcloud compute future-reservations create`) |
| "I want to **see** forecasted availability and usage" | The **Capacity Planner API** (currently `v1beta`) gives you usage history, forecasts, and reservation data programmatically |
| "GPU/TPU capacity for batch or training" | **Dynamic Workload Scheduler** (Flex Start / Calendar mode) is usually a better fit than raw on-demand |

A few other things that take the sting out of STOCKOUTs:

- **Spread across zones and regions.** Capacity is counted per zone, so the more
  places you try, the better your odds.
- **Open up the machine families you'll accept**, within whatever architecture you
  need. On x86, if N2 is out, give C3, C4, or N4 a try (all Intel), or the AMD
  families if your workload is fine with them. Just note that N4 and C4 need
  Hyperdisk Balanced boot disks.
- **Right-size or split the work.** One 128-vCPU VM is much harder to place than a
  handful of smaller ones. If the job can shard, smaller VMs are far easier to get.
- **Reservations are the only real guarantee.** Even with retries, on-demand is
  best effort. A reservation actually holds the capacity for you, and bills you for
  it, until you release it.

---

## Scripts

The grab scripts take named flags or dependency-free `key=value` config files. They
classify each attempt and write a JSON Lines audit log.

### 1. `grab_capacity.sh`: poll for on-demand capacity

It keeps trying to launch **one** instance across the machine types and zones you
give it until one comes up, then **leaves it running** so the capacity is yours.
It's driven by Terraform (see `main.tf`).

```bash
cp terraform.tfvars.example terraform.tfvars   # set project_id + subnetworks

./grab_capacity.sh --machine-types <csv> --zones <csv> --delay <seconds> \
  [--max-delay <seconds>] [--max-attempts <n>] [--run-id <id>] [--check-only]
```

| Flag | Description |
|------|-------------|
| `--machine-types` | Comma-separated, e.g. `n2-highmem-64,c3-highmem-88` |
| `--zones` | Comma-separated full zones, e.g. `us-central1-a,us-central1-b` |
| `--delay` | Initial retry delay in seconds |
| `--max-delay` | Maximum exponential backoff delay; default `900` |
| `--max-attempts` | Optional; `0` (default) means retry forever |
| `--run-id` | Isolated run name; defaults to a timestamped ID |
| `--config` | Load defaults from a `key=value` config file |
| `--json-log` | Override the default `.runs/<run-id>/attempts.jsonl` path |
| `--check-only` | Validate Terraform, project access, subnet mappings, zones, and machine types without creating resources |

```bash
# Validate targets, then start an isolated capacity hunt:
./grab_capacity.sh --config capacity.conf --check-only
./grab_capacity.sh --machine-types n2-highmem-64 \
  --zones us-central1-a,us-central1-b,us-central1-c,us-central1-f \
  --delay 30 --max-delay 300 --run-id nightly-batch
```

Each run stores its Terraform backend, winner variables, and attempt log under
`.runs/<run-id>/`. Different run IDs can operate independently. When you're done,
review and release the instance with:

```bash
./release_capacity.sh --run-id nightly-batch
```

### 2. `grab_reservations.sh`: accumulate reservations

![GCE reservations meme](assets/gcp_reserve.jpg)

This one creates single-VM **capacity reservations** across the zones in a region,
retrying on STOCKOUT until it has as many as you asked for. Reservations
hold the capacity, and they **cost money**, until you delete them. By default, any
matching VM in the project can consume them, so account for other matching workloads
when planning a specific job. It uses `gcloud`.

```bash
./grab_reservations.sh --machine-type <type> --region <region> --delay <seconds> \
  --count <n> [--max-delay <seconds>] [--max-attempts <n>] [--project <id>] [--zones <csv>] \
  [--specific] [--check-only]
```

```bash
./grab_reservations.sh --machine-type n2-highmem-64 --region us-central1 \
  --delay 30 --max-delay 300 --count 4 --specific
```

The project, reservation mode, machine type, names, and zones go into
`reservations-<timestamp>.txt`, so the release script does not depend on the current
gcloud project. The matching `.jsonl` file records every attempt. Without
`--specific`, any matching VM in the project can consume the reservations. With
`--specific`, each VM must use
`--reservation-affinity=specific --reservation=RESERVATION_NAME`.

Review and release the recorded reservations with:

```bash
./release_reservations.sh --file reservations-<timestamp>.txt
```

If a run is interrupted while `gcloud` is creating a reservation, reconcile the
record with `gcloud compute reservations list --project PROJECT_ID` before cleanup.

### Configuration files

Copy `capacity.conf.example` or `reservations.conf.example` and edit the values.
Command-line flags override config-file values:

```bash
cp capacity.conf.example capacity.conf
./grab_capacity.sh --config capacity.conf --delay 60
```

Config files are parsed as data, not executed as shell code. Blank lines and lines
beginning with `#` are ignored.

### Live sandbox smoke test

The live test is deliberately excluded from CI and refuses to run without an explicit
cost acknowledgement. Use small machine types in a sandbox project:

```bash
RUN_LIVE_GCP_TESTS=1 tests/live_smoke.sh capacity.conf reservations.conf
```

It performs preflight, one VM attempt, one shared reservation, one specific
reservation, and confirmed cleanup. Audit files remain under `.live-tests/`.

---

## Prerequisites

- **Terraform** 1.5 or newer (for `grab_capacity.sh`) and **gcloud** (for
  `grab_reservations.sh`), both on your `PATH`.
- Signed in with permission to create instances and reservations. Terraform uses
  Application Default Credentials; `gcloud` commands use the active gcloud
  account:
  ```bash
  gcloud auth application-default login
  gcloud auth login
  gcloud config set project PROJECT_ID
  ```
- **Subnets that already exist**, one per region you want to try. These tools don't
  create networking for you. Use full self-links for Shared VPC.

---

## Notes and safety

- N4 and C4 machine families automatically get a Hyperdisk Balanced boot disk;
  everything else uses `pd-balanced`.
- Instances come up with **no external IP** by default. Internet egress requires an
  existing Cloud NAT or another egress path on the chosen subnet. Set
  `assign_external_ip` if you need an external IP.
- Instances inherit project metadata and organization policies. Review the project's
  OS Login and SSH settings, and set `service_account_email` when the default compute
  identity is not appropriate for the workload.
- Both grab scripts use exponential backoff with jitter between failures and classify
  STOCKOUT, quota, rate-limit, and other errors separately.
- `grab_capacity.sh` stops if every target returns a permanent non-STOCKOUT error for
  a whole cycle. It refuses to reuse a run ID whose state already manages an instance.
- `--check-only` is read-only, but it cannot prove Terraform credential validity,
  create permissions, quota headroom, Cloud NAT availability, or live hardware
  capacity. Validate those in the target environment before relying on the toolkit
  for a critical job.
- These tools create real resources that cost money. Reservations in particular keep
  billing until you delete them. Read through `main.tf` and the flags before you run
  anything.

## Official references

- [Troubleshoot resource availability errors](https://cloud.google.com/compute/docs/troubleshooting/troubleshooting-resource-availability)
- [Choose a reservation type](https://cloud.google.com/compute/docs/instances/choose-reservation-type)
- [Future reservations overview](https://cloud.google.com/compute/docs/instances/future-reservations-overview)
- [Capacity Planner API](https://cloud.google.com/capacity-planner/docs/apis)
- [Compute Engine provisioning models](https://cloud.google.com/compute/docs/instances/provisioning-models)

## Validation

Run `tests/test_scripts.sh` for mocked isolation, preflight, retry, specific
reservation, logging, and cleanup checks. CI also runs ShellCheck, Terraform
formatting, and `terraform validate`; it never contacts a GCP project or creates
resources.

## License

MIT. See [LICENSE](LICENSE).
