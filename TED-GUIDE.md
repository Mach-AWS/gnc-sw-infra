# GNC-SW cloud sim — operator quick-start

Account GC-GNC-SW-Dev `393769260826`, region `us-gov-west-1`.
Your access: `Mach-GNC-SW-Dev-Deploy` SSO role (build + deploy + run). Console UI is
read-only view; all changes go through this repo + the dispatch API.

## One-time

1. `aws configure sso` →
   start URL `https://start.us-gov-west-1.us-gov-home.awsapps.com/directory/d-98677abeac`,
   account `393769260826`, role `Mach-GNC-SW-Dev-Deploy`, region `us-gov-west-1`.
   Profile name used below: `gnc-sw-dev`.
2. `aws sso login --profile gnc-sw-dev` (browser auth; rerun when the session expires).
   **No access keys, ever.**
3. Terraform: `terraform login` (one-time TFC token; org `MachIndustries`).

## Ship images (per code change)

4. `aws ecr get-login-password --profile gnc-sw-dev | docker login --username AWS --password-stdin 393769260826.dkr.ecr.us-gov-west-1.amazonaws.com`
5. Push all three:
   - `393769260826.dkr.ecr.us-gov-west-1.amazonaws.com/mach-industries/mach-unreal`
   - `393769260826.dkr.ecr.us-gov-west-1.amazonaws.com/mach-industries/polaris-cloud`
   - `393769260826.dkr.ecr.us-gov-west-1.amazonaws.com/mach-industries/polaris-unreal-receiver`
   Entrypoints must read `RUN_CONFIG` / `PX4_BUILD` / `RUN_ID` / `OUTPUT_PREFIX`.

## Fly a run

6. Stage inputs to `s3://mach-polaris-sim-artifacts/` (`runs/inputs/*`, `builds/*`, `gis/*`).
7. `POST /runs` (SigV4-signed) to `https://syqe5a1c2e.execute-api.us-gov-west-1.amazonaws.com`
   body: `{"run_config":"s3://…","px4_build":"s3://…","run_id":"<unique, ≤36 chars>"}`
   - First dispatch after idle: ~5–10 min (EC2 GPU cold start + image pull) — expected.
   - `GET /runs/<run_id>` to watch; both nodes place together or the pair is torn down.
8. Results land in `s3://mach-polaris-sim-artifacts/runs/<run_id>/`.
9. **`DELETE /runs/<run_id>` when done** — cluster scales back to zero; a forgotten
   run bills two GPUs.

## Change the infra

10. Edit under `aws-gov/dev/polaris-sim/`, then `terraform plan` → review → `apply`.
    Workspace: TFC `gc-as-gnc-sw-dev-polaris-sim` (project GNC-SW). Plan before every
    apply; if the plan shows an IAM denial or something you can't explain, stop and
    ping platform-eng (Liem) — the boundary blocking you is intentional.

## Egress reality check (default-deny; these are the ONLY holes)

| destination | purpose |
|---|---|
| `172.23.5.51:443` | Google 3D tiles (in-VPC) |
| S3 gateway endpoint | artifacts, staged imagery, image layers |
| ECR + CloudWatch Logs endpoints | pull + logs |
| `10.73.106.0/24` | HQ Jetsons (bidi, all protocols for now) |

Anything expecting internet at runtime will hang. Stage what the run needs.
