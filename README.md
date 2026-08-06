# gnc-sw-infra

GNC SW team infrastructure-as-code. Scoped deploy lane: everything in this repo
applies within the boundary/deployer sandbox that platform engineering provisions
(`Mach-GNC-SW-Dev-Deploy` permission set; IAM guarded by the `mach-gnc-*` boundary).

What lives here: GNC SW workload stacks (sim rigs, batch compute, app infra) for the
GNC SW accounts. What does NOT live here: IAM roots, permission sets, boundaries,
OIDC roles, org/account scaffold — those are platform-engineering's repo. If an
apply fails with an IAM/boundary denial, that's the guardrail working: ask platform.

## Layout

```
aws-gov/
  dev/
    polaris-sim/     # Unreal/Polaris GPU sim stack (GC-GNC-SW-Dev 393769260826)
```

Growth: `aws-gov/prod/...`, `aws-commercial/dev/...` — same flat pattern, one dir
per root module, one TFC workspace per root, all in the TFC `GNC-SW` project.

## Workflow (see SW-TEAM-AWS-TERRAFORM-DEPLOYMENT-QRG.md for the quick-start)

1. `aws sso login --profile gnc-sw-dev` — SSO only, no static keys, no secrets in code
2. `terraform login` once (TFC token), then in a root dir: `terraform init && terraform plan`
3. Plan before every apply. Do not apply a plan that contains unexplained changes.
4. State is in Terraform Cloud (org MachIndustries, project GNC-SW) — never local, never committed.
5. The console is read-only (LZ view). Make all changes through Terraform in this repo, not the console.

## Execution model

State, locking, and RBAC live in Terraform Cloud (org MachIndustries, project
GNC-SW). Execution is LOCAL: TFC remote runners hold no AWS credentials, and the
org wires no VCS integration. TFC cannot start an apply on its own.

Deploy path:

1. Open a PR that touches `aws-gov/**`. CI posts `terraform plan` as the `plan` check.
2. Review the plan. Merge to `main` after one approval.
3. CI applies with the repo-scoped OIDC role `GitHubActionsGncSwInfraApplyRole`.
   No static AWS keys exist.

Local `terraform plan` stays available for iteration. Treat local applies as
break-glass only, and tell platform-eng first. CI is the normal path once enabled.

Credentials: SSO for humans, OIDC for CI, a per-user TFC token for local plans.
No PATs, no shared tokens.

## Hygiene (non-negotiable)

- No static AWS credentials anywhere. SSO for humans; OIDC for CI.
- No secrets in `.tf`, tfvars, or committed files.
- IAM names stay inside `mach-gnc-*`; resource names follow the house contract
  (`mi-<workload>-<env>-<region>` / `mach-gnc-<workload>-<function>`).
- `terraform fmt` + `terraform validate` before pushing.
- Stop every dispatched run when it completes: `DELETE /runs/<id>`. An idle half-rig still bills a GPU.
