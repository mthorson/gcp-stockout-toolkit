# GCP STOCKOUT Toolkit

Small Bash and Terraform tools for handling Compute Engine `STOCKOUT`
(`ZONE_RESOURCE_POOL_EXHAUSTED`) errors.

A STOCKOUT means Google Cloud can't fit your requested VM configuration in that
zone right now. It isn't a quota error. Trying another zone, machine type, or time
often works. If you need capacity held for later, use a reservation.

## Requirements

- Terraform 1.5 or newer
- Google Cloud CLI
- Application Default Credentials for Terraform
- Permission to create instances or reservations
- An existing subnet for each region you plan to use

Copy the Terraform variables and add your project and subnet details:

```bash
cp terraform.tfvars.example terraform.tfvars
gcloud auth application-default login
gcloud auth login
```

## Grab a VM

Check your project, subnet mappings, zones, and machine types without creating
anything:

```bash
./grab_capacity.sh --config capacity.conf.example --check-only
```

Start a capacity hunt:

```bash
./grab_capacity.sh \
  --machine-types n2-highmem-64,c3-highmem-88 \
  --zones us-central1-a,us-central1-b \
  --delay 30 --max-delay 300 \
  --run-id nightly-batch
```

Each run has isolated Terraform state under `.runs/<run-id>/`. The script leaves
the first successful VM running. Release it when you're done:

```bash
./release_capacity.sh --run-id nightly-batch
```

## Grab reservations

![GCE reservations meme](assets/gcp_reserve.jpg)

Create four single-VM reservations across a region:

```bash
./grab_reservations.sh \
  --machine-type n2-highmem-64 \
  --region us-central1 \
  --delay 30 --max-delay 300 \
  --count 4
```

By default, any matching VM in the project can consume the reservations. Add
`--specific` when each VM must target a reservation by name.

The script writes a reservation record and a JSONL attempt log. The record includes
the project, machine type, reservation mode, names, and zones. Use it for cleanup:

```bash
./release_reservations.sh --file reservations-<timestamp>.txt
```

## Config files and logs

Both grab scripts accept `key=value` config files. Command-line flags override file
values.

```bash
cp capacity.conf.example capacity.conf
./grab_capacity.sh --config capacity.conf --delay 60
```

Run either script with `--help` for every option. Retries use bounded exponential
backoff with jitter. Results are classified as STOCKOUT, quota, rate limit, or error
and written to JSONL.

## Safety

- These tools create billable resources. Reservations keep billing until deleted.
- Capacity runs refuse to replace a VM already managed by the same run ID.
- Cleanup commands show what they will delete and ask for confirmation.
- VMs have no external IP by default. Private internet access requires an existing
  Cloud NAT or another egress path.
- `--check-only` doesn't prove create permission, quota headroom, network egress, or
  live hardware capacity.
- After interrupting reservation creation, compare the record with
  `gcloud compute reservations list` before cleanup.

## Tests

Run the local checks:

```bash
tests/test_scripts.sh
terraform fmt -check
terraform validate
```

The live sandbox test creates billable resources and requires explicit opt-in:

```bash
RUN_LIVE_GCP_TESTS=1 tests/live_smoke.sh capacity.conf reservations.conf
```

## References

- [Troubleshoot resource availability errors](https://cloud.google.com/compute/docs/troubleshooting/troubleshooting-resource-availability)
- [Choose a reservation type](https://cloud.google.com/compute/docs/instances/choose-reservation-type)
- [Future reservations](https://cloud.google.com/compute/docs/instances/future-reservations-overview)
- [Capacity Planner](https://cloud.google.com/capacity-planner/docs/apis)

MIT licensed. See [LICENSE](LICENSE).
