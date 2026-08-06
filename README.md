# gnc-sw-infra

GNC SW team infrastructure-as-code. Scoped deploy lane: everything in this repo
applies within the boundary/deployer sandbox that platform engineering provisions
(`Mach-GNC-SW-Dev-Deploy` permission set; IAM guarded by the `mach-gnc-*` boundary).

What lives here: your workload stacks (sim rigs, batch compute, app infra) for the
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

## Workflow (see TED-GUIDE.md for the operator quick-start)

1. `aws sso login --profile gnc-sw-dev` — SSO only, no static keys, no secrets in code
2. `terraform login` once (TFC token), then in a root dir: `terraform init && terraform plan`
3. Plan before every apply. Never apply a plan with changes you can't explain.
4. State is in Terraform Cloud (org MachIndustries, project GNC-SW) — never local, never committed.
5. Console is read-only eyes (you have LZ view); changes go through Terraform here, not ClickOps.

## Hygiene (non-negotiable)

- No static AWS credentials anywhere. SSO for humans; OIDC for CI when added.
- No secrets in `.tf`, tfvars, or committed files.
- IAM names stay inside `mach-gnc-*`; resource names follow the house contract
  (`mi-<workload>-<env>-<region>` / `mach-gnc-<workload>-<function>`).
- `terraform fmt` + `terraform validate` before pushing.
- Stop what you start: `DELETE /runs/<id>` — an idle half-rig still bills a GPU.
