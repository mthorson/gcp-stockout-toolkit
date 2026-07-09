# GCP STOCKOUT Toolkit

Tools and notes for getting past Compute Engine **`STOCKOUT`**
(`ZONE_RESOURCE_POOL_EXHAUSTED`) errors on GCP, current as of 2026. A STOCKOUT is
what you hit when a zone has run out of the machine type you asked for:

```
Error: ... The zone 'projects/PROJECT/zones/us-central1-c' does not have enough
resources available to fulfill the request. (state: STOCKOUT, resource type: compute)
```

There are two things in here: a short playbook for how capacity actually works on
GCP today, and scripts that automate the two tactics that genuinely help, which are
polling for on-demand capacity and building up reservations.

---

## What a STOCKOUT actually is

Here's the thing about a STOCKOUT: it doesn't last, it only affects one zone, and
it only affects the exact machine size you asked for. Google just doesn't have that
type in that zone at the moment. It's easy to confuse with a quota error, but they
aren't the same. Quota is the ceiling on your own account, while a STOCKOUT is
Google running out of physical hardware, and it normally clears on its own as other
people shut their VMs down. A few things follow from that:

- The same VM will often come up fine in a different zone in the same region.
- A different machine family with the same architecture may have room when the
  popular one (N2, C3) is tapped out.
- Retrying the exact same request eventually works. The only real questions are how
  often you retry and how many targets you spread across.

---

## The 2026 capacity playbook

| Situation | Best tactic |
|-----------|-------------|
| "I need a VM **right now**" | Poll on-demand across zones and machine families with [`grab_capacity.sh`](#1-grab_capacitysh-poll-for-on-demand-capacity) |
| "I need **N guaranteed** slots for a job starting soon" | Create **on-demand reservations** with [`grab_reservations.sh`](#2-grab_reservationssh-accumulate-reservations) |
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

Both scripts take named flags and print `STOCKOUT`, `QUOTA`, or `ERROR` for each
attempt.

### 1. `grab_capacity.sh`: poll for on-demand capacity

It keeps trying to launch **one** instance across the machine types and zones you
give it until one comes up, then **leaves it running** so the capacity is yours.
It's driven by Terraform (see `main.tf`).

```bash
cp terraform.tfvars.example terraform.tfvars   # set project_id + subnetworks
terraform init

./grab_capacity.sh --machine-types <csv> --zones <csv> --delay <seconds> [--max-attempts <n>]
```

| Flag | Description |
|------|-------------|
| `--machine-types` | Comma-separated, e.g. `n2-highmem-64,c3-highmem-88` |
| `--zones` | Comma-separated full zones, e.g. `us-central1-a,us-central1-b` |
| `--delay` | Integer seconds slept between attempts |
| `--max-attempts` | Optional; `0` (default) means retry forever |

```bash
# Chase one machine type across every us-central1 zone, every 2 minutes:
./grab_capacity.sh --machine-types n2-highmem-64 \
  --zones us-central1-a,us-central1-b,us-central1-c,us-central1-f --delay 120
```

When you're done, tear it down with `terraform destroy -auto-approve` (then
`rm -f winner.auto.tfvars`).

### 2. `grab_reservations.sh`: accumulate reservations

This one creates single-VM **capacity reservations** across the zones in a region,
retrying on STOCKOUT until it has as many as you asked for. Reservations
**guarantee** the capacity, and they **cost money**, until you delete them. It uses
`gcloud`.

```bash
./grab_reservations.sh --machine-type <type> --region <region> --delay <seconds> \
    --count <n> [--project <id>] [--zones <csv>]
```

```bash
./grab_reservations.sh --machine-type n2-highmem-64 --region us-central1 --delay 120 --count 4
```

The names and zones of everything it reserved go into `reservations-<timestamp>.txt`,
along with a one-line command to delete them all. **Clean them up when you're
finished**, since an idle reservation keeps billing.

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
- Instances come up with **no external IP** by default and reach the internet
  through Cloud NAT. Set `assign_external_ip` if you need one.
- `grab_capacity.sh` stops on its own if **every** target fails for a whole cycle,
  since that points to a config or permissions problem rather than a real STOCKOUT.
  It won't spin forever.
- These tools create real resources that cost money. Reservations in particular keep
  billing until you delete them. Read through `main.tf` and the flags before you run
  anything.

## License

MIT. See [LICENSE](LICENSE).
