# Remote state in Terraform Cloud — same pattern as ../../sagemaker-studio.
# Execution is local (TFC remote runs have no AWS creds); TFC holds state only.
# SW-owned workspace after handover; Liem applies the first pass.

terraform {
  backend "remote" {
    hostname     = "app.terraform.io"
    organization = "MachIndustries"

    workspaces {
      name = "gc-as-gnc-sw-dev-polaris-sim"
    }
  }
}
