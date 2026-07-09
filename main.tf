terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = var.project_id
}

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------

variable "project_id" {
  description = "GCP project ID to create the instance in."
  type        = string
}

variable "subnetworks" {
  description = <<-EOT
    Map of region => subnetwork to attach the instance to. Provide one entry for
    every region whose zones you intend to try. For a Shared VPC use the full
    self-link, e.g.
      "projects/HOST_PROJECT/regions/us-central1/subnetworks/SUBNET_NAME"
    A bare subnet name works only if the subnet lives in this same project.
  EOT
  type        = map(string)
}

# machine_type and zone are normally supplied per attempt by grab_capacity.sh.
variable "machine_type" {
  description = "Machine type to attempt (e.g. n2-highmem-128)."
  type        = string
  default     = ""
}

variable "zone" {
  description = "Zone to attempt (e.g. us-central1-a)."
  type        = string
  default     = ""
}

variable "boot_image" {
  description = "Boot disk image."
  type        = string
  default     = "debian-cloud/debian-12"
}

variable "disk_size_gb" {
  description = "Boot disk size in GB."
  type        = number
  default     = 50
}

variable "disk_type" {
  description = "Boot disk type. Empty = auto: Hyperdisk Balanced for N4/C4 (which require it), pd-balanced otherwise."
  type        = string
  default     = ""
}

variable "name_prefix" {
  description = "Prefix for the instance name."
  type        = string
  default     = "capacity-grab"
}

variable "assign_external_ip" {
  description = "Attach an ephemeral external IP. Default false (egress via Cloud NAT)."
  type        = bool
  default     = false
}

variable "service_account_email" {
  description = "Service account to attach. Empty = provider/compute default."
  type        = string
  default     = ""
}

variable "service_account_scopes" {
  description = "OAuth scopes when service_account_email is set."
  type        = list(string)
  default     = ["cloud-platform"]
}

variable "network_tags" {
  description = "Network tags for firewall targeting."
  type        = list(string)
  default     = []
}

variable "labels" {
  description = "Labels applied to the instance."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# Instance
# ---------------------------------------------------------------------------

locals {
  # "us-central1-a" -> "us-central1". Guarded so `terraform destroy` (run without
  # -var, so var.zone == "") doesn't blow up on the slice.
  zone_parts = split("-", var.zone)
  region     = length(local.zone_parts) >= 2 ? "${local.zone_parts[0]}-${local.zone_parts[1]}" : ""

  # N4 and C4 only support Hyperdisk Balanced boot disks; everything else uses
  # pd-balanced. An explicit var.disk_type overrides this.
  disk_type = var.disk_type != "" ? var.disk_type : (
    (startswith(var.machine_type, "n4") || startswith(var.machine_type, "c4"))
    ? "hyperdisk-balanced"
    : "pd-balanced"
  )

  # Fall back to a placeholder when region can't be resolved (empty zone during
  # destroy); a real apply always has a valid region via the precondition below.
  subnetwork = lookup(var.subnetworks, local.region, "unset")

  # Descriptive name when we have a target; a bare (valid) prefix otherwise so a
  # var-less `terraform destroy` before any success doesn't fail name validation.
  instance_name = (var.machine_type != "" && var.zone != "") ? "${var.name_prefix}-${replace(var.machine_type, ".", "-")}-${var.zone}" : var.name_prefix
}

resource "google_compute_instance" "grab" {
  name         = local.instance_name
  project      = var.project_id
  zone         = var.zone
  machine_type = var.machine_type

  boot_disk {
    initialize_params {
      image = var.boot_image
      size  = var.disk_size_gb
      type  = local.disk_type
    }
  }

  network_interface {
    subnetwork = local.subnetwork

    dynamic "access_config" {
      for_each = var.assign_external_ip ? [1] : []
      content {}
    }
  }

  dynamic "service_account" {
    for_each = var.service_account_email != "" ? [1] : []
    content {
      email  = var.service_account_email
      scopes = var.service_account_scopes
    }
  }

  tags                = var.network_tags
  labels              = var.labels
  deletion_protection = false

  lifecycle {
    # Permissive when zone is empty so `terraform destroy` (no -var) isn't blocked;
    # a real apply always sets zone and must have a matching subnetwork.
    precondition {
      condition     = var.zone == "" || contains(keys(var.subnetworks), local.region)
      error_message = "No subnetwork configured for region '${local.region}'. Add it to var.subnetworks in terraform.tfvars."
    }
  }
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

output "instance_name" {
  description = "Name of the grabbed instance."
  value       = google_compute_instance.grab.name
}

output "zone" {
  description = "Zone the capacity was secured in."
  value       = google_compute_instance.grab.zone
}

output "machine_type" {
  description = "Machine type that provisioned."
  value       = google_compute_instance.grab.machine_type
}

output "internal_ip" {
  description = "Primary internal IP."
  value       = google_compute_instance.grab.network_interface[0].network_ip
}

output "self_link" {
  description = "Full resource self-link."
  value       = google_compute_instance.grab.self_link
}
